//
//  AudioRecorderManager.swift
//  极简录音 - 录音管理器 (Fragmented MP4 方案，支持多音频源)
//

import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation
import IOKit.pwr_mgt
import ScreenCaptureKit

// MARK: - AVAudioPCMBuffer 扩展 (深拷贝支持)
extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }
        copy.frameLength = frameLength
        if let src = floatChannelData, let dst = copy.mutableAudioBufferList.pointee.mBuffers.mData
        {
            // 注意：这里假设是单声道或交织/非交织的通用处理
            // 对于单声道 48k Float，直接拷贝整个内存块是安全的
            for i in 0..<Int(format.channelCount) {
                if let s = floatChannelData?[i], let d = copy.floatChannelData?[i] {
                    memcpy(d, s, Int(frameLength) * MemoryLayout<Float>.size)
                }
            }
        }
        return copy
    }
}

class AudioRecorderManager: NSObject, ObservableObject {
    static let shared = AudioRecorderManager()

    @Published var isRecording = false
    @Published var currentRecordingURL: URL?
    @Published var recordingDuration: TimeInterval = 0

    // Core Audio & Asset Writer
    private let audioEngine = AVAudioEngine()
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var writingQueue = DispatchQueue(
        label: "com.simplerecorder.writingQueue", qos: .userInitiated)
    private var recordingTimer: Timer?
    private var sleepAssertionID: IOPMAssertionID = 0
    private var recordingStartDate: Date?

    // 状态管理
    private var isWriterStarted = false
    private var isTransitioning = false  // 用于防止启停过程中的并发冲突
    private var totalFramesWritten: Int64 = 0
    private var isAutoStoppedByLimit = false  // 标记是否因为达到时长上限而停止

    // 当前录音使用的音频源（录音开始时锁定）
    private var currentAudioSource: AudioSource = .microphone

    // 系统音频采集相关（macOS 13.0+）
    private var systemAudioStream: SCStream?
    private var systemAudioOutput: SystemAudioStreamOutput?

    // 用于混音的 Mixer Node
    private var mixerNode: AVAudioMixerNode?
    private var recordingMixer: AVAudioMixerNode!
    private var systemAudioSourceNode: AVAudioSourceNode?

    // 系统音频缓冲队列（用于从 ScreenCaptureKit 回调传递到 AVAudioEngine）
    private var systemAudioBufferQueue = [AVAudioPCMBuffer]()
    private let systemAudioQueueLimit = 200
    private let systemAudioQueueLock = NSLock()

    // 音频转换器缓存，用于修复系统音转换时的相位不连续/失真问题
    private var cachedAudioConverter: AVAudioConverter?
    private var lastSrcFormat: AVAudioFormat?
    private var lastDstFormat: AVAudioFormat?

    // 调试辅助标记
    private var hasPrintedFirstSample = false
    private var hasPrintedSystemAudioFormat = false
    private var lastLevelLogTime: TimeInterval = 0

    // 动态时长限制设置
    private var maxDuration: TimeInterval {
        AppSettings.shared.maxRecordingDuration
    }
    private let warningInterval: TimeInterval = 10 * 60  // 每 10 分钟提醒
    private var lastWarningTime: TimeInterval = 0

    // 最小磁盘空间要求（500MB）
    private let minimumDiskSpace: Int64 = 500 * 1024 * 1024

    // 崩溃恢复相关的 UserDefaults 键
    private let recordingInProgressKey = "recording_in_progress"
    private let recordingFilePathKey = "recording_file_path"
    private let recordingStartTimeKey = "recording_start_time"

    private override init() {
        super.init()
    }

    // MARK: - 中断状态重置
    /// 应用启动时调用，检查上次是否因意外中断（如崩溃），并清理状态标记
    func resetStatusAfterInterruption() {
        let wasInterrupted = UserDefaults.standard.bool(forKey: recordingInProgressKey)
        let filePath = UserDefaults.standard.string(forKey: recordingFilePathKey)

        if wasInterrupted {
            if let path = filePath, FileManager.default.fileExists(atPath: path) {
                print("⚠️ 检测到上次录音非正常结束。")
                print("💡 备注：得益于 fMP4 格式，文件已自动固化保存。路径: \(path)")
            } else {
                print("ℹ️ 检测到上次录音曾被标记开始，但未找到对应的物理文件。")
            }
            // 发送通知，允许 UI 刷新录音列表
            NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
        }

        // 核心动作：无论是否发现中断，都重置标记
        clearRecordingState()

        // 清理旧版本（分段方案）遗留的临时目录
        cleanupLegacyTempDirectories()
    }

    private func cleanupLegacyTempDirectories() {
        let recordingsPath = AppSettings.shared.recordingsPath
        let tempDirURL = recordingsPath.appendingPathComponent(".recording_temp")
        if FileManager.default.fileExists(atPath: tempDirURL.path) {
            try? FileManager.default.removeItem(at: tempDirURL)
        }
    }

    // MARK: - 录音状态持久化
    private func saveRecordingState(file: String) {
        UserDefaults.standard.set(true, forKey: recordingInProgressKey)
        UserDefaults.standard.set(file, forKey: recordingFilePathKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: recordingStartTimeKey)
        UserDefaults.standard.synchronize()
    }

    private func clearRecordingState() {
        UserDefaults.standard.set(false, forKey: recordingInProgressKey)
        UserDefaults.standard.removeObject(forKey: recordingFilePathKey)
        UserDefaults.standard.removeObject(forKey: recordingStartTimeKey)
        UserDefaults.standard.synchronize()
    }

    // MARK: - Recording Control
    func startRecording() {
        // 防止在转换状态中或已在录音时重复启动
        guard !isTransitioning, !isRecording else {
            print("⚠️ 忽略启动请求：正在转换状态 (\(isTransitioning)) 或已在录音 (\(isRecording))")
            return
        }

        // 检查权限
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async { self?.beginRecording() }
                } else {
                    DispatchQueue.main.async { self?.isTransitioning = false }
                }
            }
        case .denied, .restricted:
            isTransitioning = false
            showMicrophonePermissionAlert()
        @unknown default:
            break
        }
    }

    private func beginRecording() {
        isTransitioning = true
        let recordingsPath = AppSettings.shared.recordingsPath

        // 环境预检
        guard checkDiskSpace(at: recordingsPath) else {
            isTransitioning = false
            showDiskSpaceAlert()
            return
        }
        guard checkDirectoryWritable(at: recordingsPath) else {
            isTransitioning = false
            showDirectoryPermissionAlert()
            return
        }

        // 锁定当前录音使用的音频源
        currentAudioSource = AppSettings.shared.audioSource

        // 如果需要系统音频但系统版本不支持，降级为麦克风
        if !AppSettings.isSystemAudioSupported && currentAudioSource != .microphone {
            currentAudioSource = .microphone
            print("⚠️ 系统版本不支持系统音频采集，已降级为麦克风模式")
        }

        // 根据音频源类型选择不同的启动方式
        switch currentAudioSource {
        case .microphone:
            // 麦克风模式：同步启动
            startMicrophoneRecording(at: recordingsPath)
        case .systemAudio, .both:
            // 系统音频模式：需要 async，使用 Task 启动
            if #available(macOS 13.0, *) {
                Task { @MainActor in
                    await self.startSystemAudioRecording(at: recordingsPath)
                }
            } else {
                // 降级到麦克风
                startMicrophoneRecording(at: recordingsPath)
            }
        }
    }

    // MARK: - 麦克风录音启动（同步）
    private func startMicrophoneRecording(at recordingsPath: URL) {
        do {
            try FileManager.default.createDirectory(
                at: recordingsPath, withIntermediateDirectories: true)

            let fileName = self.generateInitialFileName()
            let finalFileURL = recordingsPath.appendingPathComponent(fileName)
            currentRecordingURL = finalFileURL

            assetWriter = try AVAssetWriter(outputURL: finalFileURL, fileType: .m4a)
            assetWriter?.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 48000.0,
                AVEncoderBitRateKey: 128000,
            ]

            assetWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            assetWriterInput?.expectsMediaDataInRealTime = true

            if let input = assetWriterInput, assetWriter?.canAdd(input) == true {
                assetWriter?.add(input)
            }

            isWriterStarted = false
            totalFramesWritten = 0

            try setupMicrophoneOnlyRecording()

            guard assetWriter?.startWriting() == true else {
                throw assetWriter?.error ?? NSError(domain: "AudioRecorder", code: -1)
            }

            try audioEngine.start()
            finalizeRecordingStart(fileURL: finalFileURL)

        } catch {
            print("❌ 启动录音失败: \(error.localizedDescription)")
            // showRecordingErrorAlert(message: error.localizedDescription)
        }
    }

    // MARK: - 系统音频录音启动（异步）
    @available(macOS 13.0, *)
    private func startSystemAudioRecording(at recordingsPath: URL) async {
        do {
            try FileManager.default.createDirectory(
                at: recordingsPath, withIntermediateDirectories: true)

            let fileName = self.generateInitialFileName()
            let finalFileURL = recordingsPath.appendingPathComponent(fileName)
            currentRecordingURL = finalFileURL

            assetWriter = try AVAssetWriter(outputURL: finalFileURL, fileType: .m4a)
            assetWriter?.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 48000.0,
                AVEncoderBitRateKey: 128000,
            ]

            assetWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            assetWriterInput?.expectsMediaDataInRealTime = true

            if let input = assetWriterInput, assetWriter?.canAdd(input) == true {
                assetWriter?.add(input)
            }

            isWriterStarted = false
            totalFramesWritten = 0

            if currentAudioSource == .systemAudio {
                try await setupSystemAudioOnlyRecording()
            } else {
                try await setupMixedRecording()
            }

            guard assetWriter?.startWriting() == true else {
                throw assetWriter?.error ?? NSError(domain: "AudioRecorder", code: -1)
            }

            // 启动音频引擎以开始处理
            try audioEngine.start()
            finalizeRecordingStart(fileURL: finalFileURL)

        } catch {
            print("❌ 启动录音失败: \(error.localizedDescription)")
            // showRecordingErrorAlert(message: error.localizedDescription)
        }
    }

    // MARK: - 录音启动完成处理
    private func finalizeRecordingStart(fileURL: URL) {
        isTransitioning = false
        recordingStartDate = Date()
        saveRecordingState(file: fileURL.path)

        isRecording = true
        recordingDuration = 0
        lastWarningTime = 0
        hasPrintedFirstSample = false
        hasPrintedSystemAudioFormat = false

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let startDate = self.recordingStartDate else { return }

            // 使用当前时间减去开始时间，确保计时的绝对准确，解决主线程阻塞导致的累计误差
            self.recordingDuration = Date().timeIntervalSince(startDate)

            if self.recordingDuration >= self.maxDuration {
                print("⏰ 达到录音时长上限 (\(Int(self.maxDuration))s)，正在自动停止...")
                self.isAutoStoppedByLimit = true
                self.stopRecording()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer

        setupSleepPrevention()
        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)

        let deviceName =
            AppSettings.shared.availableInputDevices.first(where: {
                $0.id == AppSettings.shared.selectedDeviceID
            })?.name ?? "默认设备"
        print(
            "🎙️ 录音已启动 [\(currentAudioSource.displayName)] (输入: \(deviceName)) (fMP4): \(fileURL.lastPathComponent)"
        )
    }

    // MARK: - 仅麦克风录音配置
    private func setupMicrophoneOnlyRecording() throws {
        // 1. 设置硬件输入设备
        try updateInputDevice()

        setupRecordingMixer()

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // 连接麦克风到录音混音器
        audioEngine.connect(inputNode, to: recordingMixer, format: inputFormat)

        installRecordingTap()
    }

    private func setupRecordingMixer() {
        recordingMixer = AVAudioMixerNode()
        audioEngine.attach(recordingMixer)

        // 显式指定 44.1kHz 格式
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!

        // 连接到主混音器：必须保持连接引擎才能运转
        audioEngine.connect(recordingMixer, to: audioEngine.mainMixerNode, format: format)

        // 【关键修复】recordingMixer 的音量必须为 1.0，否则 tap 捕获到的是静音
        recordingMixer.outputVolume = 1.0

        // 【静音监听】只把引擎的主输出音量关掉。这样内部数据流正常，但耳机没声音
        audioEngine.mainMixerNode.outputVolume = 0

        print("🎛️ 混音链路已就位：录制音量 1.0, 监听音量 0.0")
    }

    private func installRecordingTap() {
        let format = recordingMixer.outputFormat(forBus: 0)
        recordingMixer.installTap(onBus: 0, bufferSize: 2048, format: format) {
            [weak self] buffer, time in
            guard let self = self else { return }
            // 检查是否有实际音频数据流入
            if buffer.frameLength > 0 {
                self.processAudioBuffer(buffer, time: time)
            }
        }
    }

    // MARK: - 仅系统音频录音配置
    @available(macOS 13.0, *)
    private func setupSystemAudioOnlyRecording() async throws {
        setupRecordingMixer()

        // 启动系统音频采集
        try await startSystemAudioCapture()

        // 创建 SourceNode 接收来自 ScreenCaptureKit 的音频
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        systemAudioSourceNode = AVAudioSourceNode(format: format) {
            [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            return self.fillSystemAudioBuffer(audioBufferList, frameCount: frameCount)
        }

        if let sourceNode = systemAudioSourceNode {
            audioEngine.attach(sourceNode)
            audioEngine.connect(sourceNode, to: recordingMixer, format: format)
        }

        installRecordingTap()
    }

    private func fillSystemAudioBuffer(
        _ audioBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: AVAudioFrameCount
    ) -> OSStatus {
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)

        // 先全部填充静音，确保未覆盖区域无杂音
        for i in 0..<ablPointer.count {
            if let data = ablPointer[i].mData {
                memset(data, 0, Int(ablPointer[i].mDataByteSize))
            }
        }

        systemAudioQueueLock.lock()
        defer { systemAudioQueueLock.unlock() }

        var framesCopied: AVAudioFrameCount = 0
        let sampleSize = MemoryLayout<Float>.size

        // 循环从队列中取出数据直到填满当前请求的 frameCount
        while framesCopied < frameCount && !systemAudioBufferQueue.isEmpty {
            let buffer = systemAudioBufferQueue[0]
            let framesLeft = frameCount - framesCopied
            let framesInSource = buffer.frameLength
            let framesToCopy = min(framesLeft, framesInSource)

            let srcPointer = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)

            for i in 0..<min(ablPointer.count, srcPointer.count) {
                let byteOffset = Int(framesCopied) * sampleSize
                let bytesToCopy = Int(framesToCopy) * sampleSize

                if let srcData = srcPointer[i].mData, let dstData = ablPointer[i].mData {
                    // 【关键修复】确保将 srcNode 完整拷贝到 dst 的正确偏移位置
                    memcpy(dstData.advanced(by: byteOffset), srcData, bytesToCopy)
                }
            }

            framesCopied += framesToCopy

            if framesToCopy >= framesInSource {
                // 这个 buffer 用完了
                systemAudioBufferQueue.removeFirst()
            } else {
                // 这个 buffer 没用完，需要处理剩下部分（极为关键，否则音频会产生微小截断失真）
                // 方案：通过创建一个偏移后的子 buffer 替换掉当前的
                let remainingFrames = framesInSource - framesToCopy
                if let nextBuffer = AVAudioPCMBuffer(
                    pcmFormat: buffer.format, frameCapacity: remainingFrames)
                {
                    nextBuffer.frameLength = remainingFrames
                    let nextSrcPointer = UnsafeMutableAudioBufferListPointer(
                        buffer.mutableAudioBufferList)
                    let nextDstPointer = UnsafeMutableAudioBufferListPointer(
                        nextBuffer.mutableAudioBufferList)

                    for i in 0..<min(nextSrcPointer.count, nextDstPointer.count) {
                        let srcOffset = Int(framesToCopy) * sampleSize
                        if let sData = nextSrcPointer[i].mData, let dData = nextDstPointer[i].mData
                        {
                            memcpy(
                                dData, sData.advanced(by: srcOffset),
                                Int(remainingFrames) * sampleSize)
                        }
                    }
                    systemAudioBufferQueue[0] = nextBuffer
                } else {
                    // 回退方案：如果无法创建子 buffer，则丢弃
                    systemAudioBufferQueue.removeFirst()
                }
            }
        }

        return noErr
    }

    // MARK: - 混合录音配置（麦克风 + 系统音频）
    @available(macOS 13.0, *)
    private func setupMixedRecording() async throws {
        // 1. 设置硬件输入设备
        try updateInputDevice()

        setupRecordingMixer()

        // 1. 连接麦克风到 Bus 0
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        audioEngine.connect(
            inputNode, to: recordingMixer, fromBus: 0, toBus: 0, format: inputFormat)

        // 2. 启动系统音频采集
        try await startSystemAudioCapture()

        // 系统音频统一使用 44.1kHz 单声道进行混音
        let systemFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        systemAudioSourceNode = AVAudioSourceNode(format: systemFormat) {
            [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            return self.fillSystemAudioBuffer(audioBufferList, frameCount: frameCount)
        }

        if let sourceNode = systemAudioSourceNode {
            audioEngine.attach(sourceNode)
            // 连接系统音频到 Bus 1，避免覆盖麦克风
            audioEngine.connect(
                sourceNode, to: recordingMixer, fromBus: 0, toBus: 1, format: systemFormat)
            print("🎸 混合连接成功：Bus 0 (麦克风), Bus 1 (系统音)")
        }

        installRecordingTap()
    }

    /// 根据 AppSettings 切换硬件输入设备
    private func updateInputDevice() throws {
        let selectedID = AppSettings.shared.selectedDeviceID
        guard selectedID != "default" else { return }

        let inputNode = audioEngine.inputNode
        guard let audioUnit = inputNode.audioUnit else {
            print("⚠️ 无法获取 inputNode 的 AUAudioUnit")
            return
        }

        // 获取 CoreAudio 的 AudioDeviceID
        // 注意：在 macOS 上，AVCaptureDevice.uniqueID 与 CoreAudio Device UID 是一致的
        // 需要使用 AudioHardware API 来查找对应的渲染设备 ID

        var deviceID: AudioDeviceID = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propsize: UInt32 = 0
        AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propsize)

        let nDevices = Int(propsize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: nDevices)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propsize, &deviceIDs)

        for id in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString? = nil
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &uid)

            if let uidString = uid as String?, uidString == selectedID {
                deviceID = id
                break
            }
        }

        if deviceID != 0 {
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )

            if status != noErr {
                print("❌ 切换输入设备失败 (Status: \(status))")
            } else {
                print("✅ 已切换输入设备至 ID: \(deviceID)")
            }
        } else {
            print("⚠️ 未找到匹配的 AudioDeviceID: \(selectedID)")
        }
    }

    // MARK: - 系统音频采集启动
    @available(macOS 13.0, *)
    private func startSystemAudioCapture() async throws {
        let configuration = SCStreamConfiguration()

        // 最小化视频配置（我们只需要音频）
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        // 启用音频采集
        configuration.capturesAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = true  // 排除自己的音频，避免回声

        // 使用 macOS 14.2+ 的仅音频采集方式
        if #available(macOS 14.2, *) {
            // macOS 14.2+ 支持 audio-only 权限
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: false)

            guard let display = content.displays.first else {
                throw NSError(
                    domain: "AudioRecorder", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "无法获取显示器信息"])
            }

            // 排除当前应用程序（SimpleRecorder）的音频，避免回声
            let filter = SCContentFilter(
                display: display,
                excludingApplications: content.applications.filter {
                    $0.bundleIdentifier == Bundle.main.bundleIdentifier
                }, exceptingWindows: [])

            systemAudioOutput = SystemAudioStreamOutput { [weak self] sampleBuffer in
                self?.handleSystemAudioSampleBuffer(sampleBuffer)
            }

            systemAudioStream = SCStream(
                filter: filter, configuration: configuration, delegate: nil)
        } else {
            // macOS 13.0-14.1 回退方案：需要使用 display filter
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)

            guard let display = content.displays.first else {
                throw NSError(
                    domain: "AudioRecorder", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "无法获取显示器信息"])
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])

            systemAudioOutput = SystemAudioStreamOutput { [weak self] sampleBuffer in
                self?.handleSystemAudioSampleBuffer(sampleBuffer)
            }

            systemAudioStream = SCStream(
                filter: filter, configuration: configuration, delegate: nil)
        }

        if let output = systemAudioOutput {
            try systemAudioStream?.addStreamOutput(
                output, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        }

        try await systemAudioStream?.startCapture()
        print("🔊 系统音频采集已启动")
    }

    // MARK: - 处理系统音频样本
    private func handleSystemAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sampleBuffer),
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        let srcFormat = AVAudioFormat(streamDescription: asbd)!
        let dstFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!

        if !hasPrintedSystemAudioFormat {
            print(
                "🔊 系统音频源格式: \(srcFormat.sampleRate)Hz, \(srcFormat.channelCount)声道, \(asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? "非交织" : "交织")"
            )
            hasPrintedSystemAudioFormat = true
        }

        // 步骤 1：创建一个格式完全匹配源的中转 Buffer
        guard let tempBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount)
        else { return }
        tempBuffer.frameLength = frameCount

        // 步骤 2：采用官方推荐的拷贝方式将数据存入 tempBuffer
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: tempBuffer.mutableAudioBufferList
        )

        if status != noErr {
            print("❌ 拷贝 PCM 数据失败: \(status)")
            return
        }

        // 步骤 3：转换到混音引擎的标准格式 (48k/1ch)
        guard let finalBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: frameCount)
        else { return }
        finalBuffer.frameLength = frameCount

        if srcFormat.isEqual(dstFormat) {
            self.enqueueSystemAudioBuffer(tempBuffer)
        } else {
            // 获取（或初始化）缓存的转换器
            let converter: AVAudioConverter?
            if let cached = cachedAudioConverter,
                let lastSrc = lastSrcFormat,
                let lastDst = lastDstFormat,
                lastSrc.isEqual(srcFormat) && lastDst.isEqual(dstFormat)
            {
                converter = cached
            } else {
                print("🔄 为新的系统音格式初始化转换器: \(srcFormat.sampleRate) -> \(dstFormat.sampleRate)")
                converter = AVAudioConverter(from: srcFormat, to: dstFormat)
                cachedAudioConverter = converter
                lastSrcFormat = srcFormat
                lastDstFormat = dstFormat
            }

            guard let activeConverter = converter else { return }

            var error: NSError?
            activeConverter.convert(to: finalBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return tempBuffer
            }

            if let err = error {
                print("❌ 系统音频转换失败: \(err.localizedDescription)")
            } else {
                self.enqueueSystemAudioBuffer(finalBuffer)
            }
        }
    }

    private func enqueueSystemAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // 简易信号强度检测，仅用于调试
        let now = Date().timeIntervalSince1970
        if now - lastLevelLogTime > 5.0 {
            if let channelData = buffer.floatChannelData?[0] {
                var maxAmp: Float = 0
                for i in 0..<Int(buffer.frameLength) {
                    maxAmp = max(maxAmp, abs(channelData[i]))
                }
                if maxAmp > 0.0001 {
                    print("✅ 系统音频信号正常 [有效峰值: \(String(format: "%.4f", maxAmp))]")
                } else {
                    print("⚠️ 系统音频采集正常但信号为静音/极微弱")
                }
            }
            lastLevelLogTime = now
        }

        systemAudioQueueLock.lock()
        systemAudioBufferQueue.append(buffer)
        if systemAudioBufferQueue.count > systemAudioQueueLimit {
            systemAudioBufferQueue.removeFirst()
            // 减少日志频率，避免 IO 繁忙
            if Int.random(in: 1...20) == 1 {
                print("⚠️ 系统音频缓冲队列溢出 (\(systemAudioBufferQueue.count))，由于系统负载过高，部分音频采样已丢弃")
            }
        }
        systemAudioQueueLock.unlock()
    }

    // MARK: - 直接处理系统音频并写入 AssetWriter
    private func processSystemAudioDirectly(_ sampleBuffer: CMSampleBuffer) {
        guard let writer = assetWriter, let input = assetWriterInput else { return }
        guard writer.status == .writing || !isWriterStarted else { return }

        // 初始化时间戳
        if !isWriterStarted {
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: presentationTime)
            isWriterStarted = true
            print("📝 系统音频 AssetWriter 会话已启动")
        }

        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        // 【核心修复】必须执行深拷贝。原先的 buffer.copy() 会导致崩溃，且 tap 会复用内存导致数据损坏。
        guard let bufferCopy = buffer.deepCopy() else { return }

        // 捕获当前的 writer 和 input，防止在录音切换时操作到错误的对象
        let writer = self.assetWriter
        let input = self.assetWriterInput

        writingQueue.async { [weak self] in
            guard let self = self, let currentWriter = writer, let currentInput = input else {
                return
            }

            // 检查 writer 状态，如果已失败则不再尝试
            guard currentWriter.status == .writing else { return }

            if !self.isWriterStarted {
                currentWriter.startSession(atSourceTime: .zero)
                self.isWriterStarted = true
                print("📝 AssetWriter 写入会话已建立 (Queue-based)")
            }

            // 计算并写入
            if let sampleBuffer = self.createSampleBuffer(from: bufferCopy, time: time) {
                // 不再手动 Thread.sleep 丢帧。让 Serial Queue 自动排队。
                // 只有在 Input 真的无法接受数据（通常是磁盘故障或 Writer 错误）时才报错。
                if currentInput.isReadyForMoreMediaData {
                    if !currentInput.append(sampleBuffer) {
                        print("❌ 写入采样数据失败: \(currentWriter.error?.localizedDescription ?? "未知错误")")
                    } else if !self.hasPrintedFirstSample {
                        print("✅ 成功写入首个采样数据 [Channels: \(bufferCopy.format.channelCount)]")
                        self.hasPrintedFirstSample = true
                    }
                } else {
                    // 如果长时间不 Ready，说明底层缓冲区满了，但为了保证时长完整，我们绝不在这里丢帧
                    // 而是等待一小会重试，直到成功或 Writer 报错
                    var retry = 0
                    while !currentInput.isReadyForMoreMediaData && retry < 200 {
                        Thread.sleep(forTimeInterval: 0.01)  // 10ms
                        retry += 1
                    }
                    if !currentInput.append(sampleBuffer) {
                        print("❌ 强制写入失败: \(currentWriter.error?.localizedDescription ?? "数据溢出")")
                    }
                }
            }
        }
    }

    private func createSampleBuffer(from buffer: AVAudioPCMBuffer, time: AVAudioTime)
        -> CMSampleBuffer?
    {
        let timescale = Int32(buffer.format.sampleRate)

        // 【核心修复】改为基于累积帧数的物理时间戳，不再依赖硬件 mSampleTime
        // 硬件时钟会因为负载或休眠产生微小抖动，而物理帧数永远是准的
        let presentationTime = CMTime(value: totalFramesWritten, timescale: timescale)

        var formatDescription: CMFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: buffer.format.streamDescription, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &formatDescription)

        guard status == noErr, let format = formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: timescale),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard createStatus == noErr, let sb = sampleBuffer else { return nil }

        CMSampleBufferSetDataBufferFromAudioBufferList(
            sb,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList
        )

        // 写入成功后递增全局帧计数器
        totalFramesWritten += Int64(buffer.frameLength)

        return sb
    }

    func stopRecording() {
        guard isRecording, !isTransitioning else { return }
        isTransitioning = true

        print("⏹️ 正在停止录音...")
        recordingTimer?.invalidate()
        recordingTimer = nil

        // 1. 停止采集（确保不再有新数据进入队列）
        cleanupAudioCapture()

        let outputURL = currentRecordingURL
        let currentWriter = assetWriter
        let currentInput = assetWriterInput

        // 2. 在写入队列中执行收尾操作，确保所有 pending 的 append 都已完成
        writingQueue.async { [weak self] in
            guard let self = self else { return }

            currentInput?.markAsFinished()
            print("🏁 写入队列已接收停止指令，正在固化文件...")

            currentWriter?.finishWriting { [weak self] in
                guard let self = self else { return }

                DispatchQueue.main.async {
                    self.isRecording = false
                    self.clearRecordingState()
                    self.isTransitioning = false

                    if let writer = currentWriter, writer.status == .completed, let url = outputURL
                    {
                        print("📊 写入完成，最终状态: .completed")
                        let finalURL = self.renameToFinalFormat(url: url)
                        print("✅ 录音已保存: \(finalURL.path)")

                        // 如果是因为达到上限停止的，给予弹窗提示
                        if self.isAutoStoppedByLimit {
                            self.showRecordingLimitReachedAlert(duration: self.recordingDuration)
                            self.isAutoStoppedByLimit = false
                        }

                        NSWorkspace.shared.activateFileViewerSelecting([finalURL])
                    } else if let err = currentWriter?.error {
                        print("❌ 写入结束时出错: \(err.localizedDescription)")
                    } else {
                        print("⚠️ 写入可能未正常完成，状态: \(currentWriter?.status.rawValue ?? -1)")
                    }

                    // 3. 后续清理
                    if self.assetWriter === currentWriter { self.assetWriter = nil }
                    if self.assetWriterInput === currentInput { self.assetWriterInput = nil }
                    self.currentRecordingURL = nil

                    self.releaseSleepPrevention()
                    self.isTransitioning = false  // 确保在所有资源完全释放后重置
                    NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
                }
            }
        }
    }

    func saveRecordingImmediately() {
        // 立即停止并等待写入完成
        guard isRecording else { return }

        recordingTimer?.invalidate()
        recordingTimer = nil

        // 根据音频源类型清理不同的采集
        cleanupAudioCapture()

        // 3. 在写入队列中同步执行收尾
        let semaphore = DispatchSemaphore(value: 0)
        writingQueue.sync { [weak self] in
            guard let self = self else {
                semaphore.signal()
                return
            }
            self.assetWriterInput?.markAsFinished()
            self.assetWriter?.finishWriting {
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + 2.0)

        isRecording = false
        clearRecordingState()

        // 紧急保存时不进行重命名，保持原样以确保安全

        releaseSleepPrevention()
        print("🚨 录音已紧急保存完毕")
    }

    // MARK: - 命名格式化与重命名
    private func generateInitialFileName() -> String {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        // 1. 日期: YYYY.MM.DD
        dateFormatter.dateFormat = "yyyy.MM.dd"
        let datePart = dateFormatter.string(from: now)

        // 2. 星期: 三字母缩写 (Mon/Tue...)
        dateFormatter.dateFormat = "E"
        let weekPart = dateFormatter.string(from: now)

        // 3. 时间: 24小时制 HH.mm
        dateFormatter.dateFormat = "HH.mm"
        let timePart = dateFormatter.string(from: now)

        // 双空格分隔，格式：2026.01.14  Mon  18.59 - ing.m4a
        return "\(datePart)  \(weekPart)  \(timePart) - ing.m4a"
    }

    private func renameToFinalFormat(url: URL) -> URL {
        guard let startDate = recordingStartDate else { return url }
        let endDate = Date()

        // 1. 准备格式化器
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        // 1. 日期: YYYY.MM.DD
        dateFormatter.dateFormat = "yyyy.MM.dd"
        let datePart = dateFormatter.string(from: startDate)

        // 2. 星期: 三字母缩写
        dateFormatter.dateFormat = "E"
        let weekPart = dateFormatter.string(from: startDate)

        // 3. 时间: 24小时制 HH.mm
        dateFormatter.dateFormat = "HH.mm"
        let startPart = dateFormatter.string(from: startDate)

        // 4. 时长: Xmin (移除空格)
        let totalSeconds = Int(endDate.timeIntervalSince(startDate))
        let minutes = max(1, totalSeconds / 60)
        let durationPart = "\(minutes)min"

        // 基础文件名：2026.01.14  Mon  18.59 - 13min.m4a
        let baseFileName = "\(datePart)  \(weekPart)  \(startPart) - \(durationPart)"
        let newURL = url.deletingLastPathComponent().appendingPathComponent("\(baseFileName).m4a")

        do {
            var finalURL = newURL
            var counter = 1

            // 循环检测直到找到不存在的文件名
            while FileManager.default.fileExists(atPath: finalURL.path) {
                let uniqueFileName = "\(baseFileName) (\(counter)).m4a"
                finalURL = url.deletingLastPathComponent().appendingPathComponent(uniqueFileName)
                counter += 1
            }

            try FileManager.default.moveItem(at: url, to: finalURL)
            return finalURL
        } catch {
            print("❌ 重命名失败: \(error.localizedDescription)")
            return url
        }
    }

    // MARK: - 音频采集资源清理
    private func cleanupAudioCapture() {
        // 1. 停止并移除 tap (必须首先执行)
        audioEngine.inputNode.removeTap(onBus: 0)
        recordingMixer?.removeTap(onBus: 0)

        // 2. 停止并重置引擎 (reset 会自动 detach 所有节点并清除连接)
        audioEngine.stop()
        audioEngine.reset()

        // 3. 处理系统音频流的异步释放
        if #available(macOS 13.0, *) {
            let stream = systemAudioStream
            systemAudioStream = nil
            systemAudioOutput = nil
            Task {
                try? await stream?.stopCapture()
            }
        }

        // 4. 置空各节点引用
        systemAudioSourceNode = nil
        self.recordingMixer = nil
        mixerNode = nil
        cachedAudioConverter = nil
        lastSrcFormat = nil
        lastDstFormat = nil

        // 5. 清空缓冲队列
        systemAudioQueueLock.lock()
        systemAudioBufferQueue.removeAll()
        systemAudioQueueLock.unlock()

        print("🧹 音频采集资源已清理并重置引擎")
    }

    // MARK: - Power Management (Sleep Prevention)

    /// 开启防止休眠断言
    private func setupSleepPrevention() {
        let reason = "正在录音中，确保进程不被系统休眠中断。" as CFString
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            "SimpleRecorderAudioRecording" as CFString,
            reason,
            nil,
            nil,
            0,
            nil,
            &sleepAssertionID
        )

        if result == kIOReturnSuccess {
            print("⚓️ 已成功开启防休眠断言 (NoIdleSleep)")
        } else {
            print("⚠️ 开启防休眠断言失败，错误码: \(result)")
        }
    }

    /// 释放防止休眠断言
    private func releaseSleepPrevention() {
        guard sleepAssertionID != 0 else { return }
        let result = IOPMAssertionRelease(sleepAssertionID)
        if result == kIOReturnSuccess {
            print("🔓 已释放防休眠断言")
            sleepAssertionID = 0
        } else {
            print("⚠️ 释放防休眠断言失败，错误码: \(result)")
        }
    }

    // MARK: - Disk & Permission Helpers

    private func checkDiskSpace(at url: URL) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey
            ])
            if let space = values.volumeAvailableCapacityForImportantUsage {
                return space >= minimumDiskSpace
            }
        } catch { return true }
        return true
    }

    private func checkDirectoryWritable(at url: URL) -> Bool {
        let path = url.path
        if FileManager.default.fileExists(atPath: path) {
            return FileManager.default.isWritableFile(atPath: path)
        }
        return FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }

    private func checkTimeWarning() {
        // 已根据用户需求移除提前预警逻辑
    }

    // MARK: - UI Alerts

    private func showRecordingLimitReachedAlert(duration: TimeInterval) {
        let minutes = Int(duration / 60)
        let seconds = Int(duration) % 60
        let timeString = minutes > 0 ? "\(minutes) 分钟 \(seconds) 秒" : "\(seconds) 秒"

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "录音已结束"
            alert.informativeText = "录音已达到您设置的上限时间，文件已自动保存。\n\n录音时长：\(timeString)"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "知道了")
            alert.runModal()
        }
    }

    private func showTimeWarningNotification() {
        // 已根据用户需求移除提前预警弹窗
    }

    private func showMicrophonePermissionAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "需要麦克风权限"
            alert.informativeText = "请在系统设置中允许本应用访问麦克风以正常录音。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打开设置")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                ) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func showDiskSpaceAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "磁盘空间不足"
            alert.informativeText = "请至少保留 500MB 可用空间。"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "确定")
            alert.runModal()
        }
    }

    private func showDirectoryPermissionAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "目录权限不足"
            alert.informativeText = "当前录音目录不可写，请在设置中更换或修改权限。"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "打开设置")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
            }
        }
    }

    private func showRecordingErrorAlert(message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "录音启动失败"
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.addButton(withTitle: "确定")
            alert.runModal()
        }
    }

    func formatDuration(_ duration: TimeInterval) -> String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

// MARK: - SCStreamOutput 实现（系统音频采集回调）

@available(macOS 13.0, *)
private class SystemAudioStreamOutput: NSObject, SCStreamOutput {
    private let onSampleBuffer: (CMSampleBuffer) -> Void

    init(onSampleBuffer: @escaping (CMSampleBuffer) -> Void) {
        self.onSampleBuffer = onSampleBuffer
        super.init()
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        // 只处理音频类型
        guard type == .audio else { return }

        // 检查 buffer 是否有效
        guard CMSampleBufferIsValid(sampleBuffer) else { return }

        onSampleBuffer(sampleBuffer)
    }
}
