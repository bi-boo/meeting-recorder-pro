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

class AudioRecorderManager: NSObject, ObservableObject {
    static let shared = AudioRecorderManager()

    @Published var isRecording = false
    @Published var isPaused = false
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
    private var accumulatedDuration: TimeInterval = 0
    private var currentSegmentStartTime: Date?
    private var actualStartTime: Date?

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

    // 系统音频缓冲队列
    private var systemAudioBufferQueue = [AVAudioPCMBuffer]()
    private var systemAudioBufferReadOffset: AVAudioFrameCount = 0  // 追踪第一帧缓冲区的读取进度
    private var isSystemAudioBuffering = true  // 缓冲状态机
    private let systemAudioPreRollHighWaterMark = 3  // 降低到 3 个包（约 60ms），减少断续感
    private let systemAudioQueueLimit = 600  // 容错缓冲区上限
    private let systemAudioQueueLock = NSLock()

    // 音频转换器缓存，用于修复系统音转换时的相位不连续/失真问题
    private var cachedAudioConverter: AVAudioConverter?
    private var lastSrcFormat: AVAudioFormat?
    private var lastDstFormat: AVAudioFormat?

    // 调试辅助标记
    private var hasPrintedFirstSample = false
    private var hasPrintedSystemAudioFormat = false
    private var lastLevelLogTime: TimeInterval = 0

    // 【性能优化】音频 Buffer 池相关
    // 预分配 Buffer 避免在音频回调线程中频繁进行内存分配
    private let bufferPoolLimit = 32
    private var audioBufferPool = [AVAudioPCMBuffer]()
    private let bufferPoolLock = NSLock()

    // 动态时长限制设置
    private var maxDuration: TimeInterval {
        AppSettings.shared.maxRecordingDuration
    }

    // 统一的内部录音格式（48kHz, 单声道）
    private let recordingFormat = AVAudioFormat(standardFormatWithSampleRate: 48000.0, channels: 1)!
    private let warningInterval: TimeInterval = 10 * 60  // 每 10 分钟提醒
    private var lastWarningTime: TimeInterval = 0

    // 最小磁盘空间要求（100MB，足以保证 1 小时录制）
    private let minimumDiskSpace: Int64 = 100 * 1024 * 1024

    // 崩溃恢复相关的 UserDefaults 键
    private let recordingInProgressKey = "recording_in_progress"
    private let recordingFilePathKey = "recording_file_path"
    private let recordingStartTimeKey = "recording_start_time"

    private override init() {
        super.init()
        LogManager.shared.info("AudioRecorderManager 初始化")
    }

    // MARK: - 中断状态重置
    /// 应用启动时调用，检查上次是否因意外中断（如崩溃），并清理状态标记
    func resetStatusAfterInterruption() {
        let wasInterrupted = UserDefaults.standard.bool(forKey: recordingInProgressKey)
        let filePath = UserDefaults.standard.string(forKey: recordingFilePathKey)

        if wasInterrupted {
            if let path = filePath, FileManager.default.fileExists(atPath: path) {
                LogManager.shared.warning("检测到上次录音非正常结束，文件已自动固化保存 | 路径: \(path)")
            } else {
                LogManager.shared.info("检测到上次录音曾被标记开始，但未找到对应的物理文件")
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
            LogManager.shared.warning("忽略启动请求 | 正在转换状态: \(isTransitioning), 已在录音: \(isRecording)")
            return
        }
        LogManager.shared.info("收到录音启动请求")

        // 检查权限
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        LogManager.shared.info("权限检测 | 当前麦克风授权状态: \(status.rawValue) (0:n/d, 1:res, 2:den, 3:auth)")

        switch status {
        case .authorized:
            beginRecording()
        case .notDetermined:
            LogManager.shared.info("权限状态未确定，正在请求访问...")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                LogManager.shared.info("权限请求结果: \(granted ? "用户已授权" : "用户已拒绝")")
                if granted {
                    DispatchQueue.main.async { self?.beginRecording() }
                } else {
                    DispatchQueue.main.async { self?.isTransitioning = false }
                }
            }
        case .denied, .restricted:
            LogManager.shared.warning("权限被拒绝或受限，无法开始录音 | 状态: \(status.rawValue)")
            isTransitioning = false
            showMicrophonePermissionAlert()
        @unknown default:
            LogManager.shared.error("未知的权限状态: \(status.rawValue)")
            isTransitioning = false
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

            // 【关键修复】在配置新录音前，先确保引擎处于干净状态
            // 这可以解决之前录音失败后引擎状态不一致的问题
            prepareAudioEngineForNewRecording()

            try setupMicrophoneOnlyRecording()

            guard assetWriter?.startWriting() == true else {
                throw assetWriter?.error ?? NSError(domain: "AudioRecorder", code: -1)
            }

            try audioEngine.start()
            finalizeRecordingStart(fileURL: finalFileURL)

        } catch {
            LogManager.shared.error("麦克风录音启动失败 | 错误: \(error.localizedDescription)")

            // 轻量级清理：只清理本次录音创建的资源，不调用 reset() 避免破坏引擎状态
            // 移除可能已安装的 tap
            audioEngine.inputNode.removeTap(onBus: 0)
            recordingMixer?.removeTap(onBus: 0)
            audioEngine.stop()

            // 清理 mixer 节点
            if let mixer = recordingMixer {
                audioEngine.detach(mixer)
                recordingMixer = nil
            }

            // 清理已创建但未完成的 AssetWriter
            if let writer = assetWriter {
                writer.cancelWriting()
                assetWriter = nil
                assetWriterInput = nil
            }

            // 删除已创建但无效的临时文件
            if let url = currentRecordingURL {
                try? FileManager.default.removeItem(at: url)
                currentRecordingURL = nil
            }

            isTransitioning = false
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

            // 【关键修复】在配置新录音前，先确保引擎处于干净状态
            prepareAudioEngineForNewRecording()

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
            LogManager.shared.error("系统音频录音启动失败 | 错误: \(error.localizedDescription)")

            // 轻量级清理：只清理本次录音创建的资源
            // 移除可能已安装的 tap
            audioEngine.inputNode.removeTap(onBus: 0)
            recordingMixer?.removeTap(onBus: 0)
            audioEngine.stop()

            // 清理 mixer 节点
            if let mixer = recordingMixer {
                audioEngine.detach(mixer)
                recordingMixer = nil
            }

            // 清理 systemAudioSourceNode
            if let sourceNode = systemAudioSourceNode {
                audioEngine.detach(sourceNode)
                systemAudioSourceNode = nil
            }

            // 【关键】必须停止 SCStream 以释放屏幕录制权限
            if #available(macOS 13.0, *) {
                let stream = systemAudioStream
                systemAudioStream = nil
                systemAudioOutput = nil
                Task {
                    try? await stream?.stopCapture()
                }
            }

            // 清空缓冲队列
            systemAudioQueueLock.lock()
            systemAudioBufferQueue.removeAll()
            systemAudioQueueLock.unlock()

            // 清理已创建但未完成的 AssetWriter
            if let writer = assetWriter {
                writer.cancelWriting()
                assetWriter = nil
                assetWriterInput = nil
            }

            // 删除已创建但无效的临时文件
            if let url = currentRecordingURL {
                try? FileManager.default.removeItem(at: url)
                currentRecordingURL = nil
            }

            isTransitioning = false
        }
    }

    // MARK: - 录音启动完成处理
    private func finalizeRecordingStart(fileURL: URL) {
        isTransitioning = false
        accumulatedDuration = 0
        actualStartTime = Date()
        currentSegmentStartTime = actualStartTime
        saveRecordingState(file: fileURL.path)

        isRecording = true
        recordingDuration = 0
        totalFramesWritten = 0
        systemAudioBufferReadOffset = 0
        // 初始缓冲状态：仅在混合模式下默认开启以平滑时钟，仅系统音频模式下将由 setup 逻辑显式关闭
        isSystemAudioBuffering = (currentAudioSource == .both)
        lastWarningTime = 0

        hasPrintedFirstSample = false
        hasPrintedSystemAudioFormat = false

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let startDate = self.currentSegmentStartTime else { return }
            self.recordingDuration = self.accumulatedDuration + Date().timeIntervalSince(startDate)
            if self.recordingDuration >= self.maxDuration {
                self.isAutoStoppedByLimit = true
                self.stopRecording()
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer

        // 录音时始终禁止系统睡眠
        setupSleepPrevention()
        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)

        let deviceName =
            AppSettings.shared.availableInputDevices.first(where: {
                $0.id == AppSettings.shared.selectedDeviceID
            })?.name ?? "默认设备"
        LogManager.shared.info(
            "录音已启动 | 音源: \(currentAudioSource.displayName), 输入设备: \(deviceName), 文件: \(fileURL.lastPathComponent)"
        )
    }

    // MARK: - 音频引擎预备（确保干净状态）
    /// 在每次新录音开始前调用，确保音频引擎处于干净状态
    /// 这对于从之前失败的录音恢复非常重要
    private func prepareAudioEngineForNewRecording() {
        // 1. 停止引擎（如果正在运行）
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        // 2. 移除所有可能存在的 tap
        audioEngine.inputNode.removeTap(onBus: 0)
        recordingMixer?.removeTap(onBus: 0)

        // 3. 清理之前可能残留的节点
        if let mixer = recordingMixer {
            audioEngine.detach(mixer)
            recordingMixer = nil
        }
        if let sourceNode = systemAudioSourceNode {
            audioEngine.detach(sourceNode)
            systemAudioSourceNode = nil
        }
        if let mixer = mixerNode {
            audioEngine.detach(mixer)
            mixerNode = nil
        }

        // 4. 重置引擎到初始状态
        audioEngine.reset()

        // 5. 清空系统音频缓冲队列
        systemAudioQueueLock.lock()
        systemAudioBufferQueue.removeAll()
        systemAudioQueueLock.unlock()

        // 6. 清理音频转换器缓存
        cachedAudioConverter = nil
        lastSrcFormat = nil
        lastDstFormat = nil

        print("🔄 音频引擎已重置，准备开始新录音")
    }

    // MARK: - 仅麦克风录音配置
    private func setupMicrophoneOnlyRecording() throws {
        // 1. 设置硬件输入设备
        try updateInputDevice()

        // 2. 【关键】获取输入节点的硬件格式
        // 必须在连接之前获取，且需要通过 inputNode 来触发格式初始化
        let inputNode = audioEngine.inputNode

        // 触发 inputNode 初始化以获取正确的硬件格式
        // 在某些情况下，reset() 后需要重新访问 inputNode 来刷新格式
        let hwFormat = inputNode.inputFormat(forBus: 0)
        print("🎤 硬件输入格式: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount)ch")

        // 使用硬件的采样率，确保格式匹配
        let inputFormat: AVAudioFormat
        if hwFormat.sampleRate > 0 && hwFormat.channelCount > 0 {
            // 使用硬件的实际格式
            inputFormat = hwFormat
        } else {
            // 回退到默认格式
            inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        }

        // 3. 设置录音混音器
        setupRecordingMixer()

        // 4. 连接麦克风到录音混音器 (AVAudioEngine 自动处理麦克风到 48k 的重采样)
        audioEngine.connect(inputNode, to: recordingMixer, format: recordingFormat)

        installRecordingTap()
    }

    private func setupRecordingMixer() {
        recordingMixer = AVAudioMixerNode()
        audioEngine.attach(recordingMixer)

        // 统一输出为 48kHz 单声道
        audioEngine.connect(recordingMixer, to: audioEngine.mainMixerNode, format: recordingFormat)

        // 【音质优化】预留 3dB 以上的 Headroom，防止混合时的数字削波导致沙哑
        recordingMixer.outputVolume = 1.0
        audioEngine.mainMixerNode.outputVolume = 0

        print("🎛️ 混音链路已就位：录制格式 48kHz 单声道")
    }

    private func installRecordingTap() {
        let format = recordingMixer.outputFormat(forBus: 0)
        recordingMixer.installTap(onBus: 0, bufferSize: 2048, format: format) {
            [weak self] buffer, time in
            guard let self = self, self.isRecording, !self.isPaused else { return }

            // 【核心加固】：在此刻，即采集发生的瞬间读取当前的 totalFramesWritten
            // 这确保了哪怕之后异步写入队列发生延迟，该 buffer 对应的 PTS 也是绝对准确的。
            let pts = CMTime(value: self.totalFramesWritten, timescale: Int32(format.sampleRate))

            // 立即累加帧数，防止下一个回调进来时 PTS 重叠
            self.totalFramesWritten += Int64(buffer.frameLength)

            if buffer.frameLength > 0 {
                self.processAudioBufferWithPTS(buffer, pts: pts)
            }
        }
    }

    // MARK: - 仅系统音频录音配置
    @available(macOS 13.0, *)
    private func setupSystemAudioOnlyRecording() async throws {
        setupRecordingMixer()
        try await startSystemAudioCapture()

        // 仅系统录音：设置增益为 1.0，并开启弹性缓冲以对抗时钟抖动
        isSystemAudioBuffering = true

        systemAudioSourceNode = AVAudioSourceNode(format: recordingFormat) {
            [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            return self.fillSystemAudioBuffer(audioBufferList, frameCount: frameCount)
        }

        if let sourceNode = systemAudioSourceNode {
            audioEngine.attach(sourceNode)
            audioEngine.connect(sourceNode, to: recordingMixer, format: recordingFormat)
            sourceNode.volume = 1.0
        }

        installRecordingTap()
    }

    private func fillSystemAudioBuffer(
        _ audioBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: AVAudioFrameCount
    ) -> OSStatus {
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)

        // 默认填充静音
        for i in 0..<ablPointer.count {
            if let data = ablPointer[i].mData {
                memset(data, 0, Int(ablPointer[i].mDataByteSize))
            }
        }

        systemAudioQueueLock.lock()
        defer { systemAudioQueueLock.unlock() }

        // 【弹性滞后缓冲逻辑】

        // 【弹性滞后缓冲逻辑】
        if isSystemAudioBuffering {
            // 水位只要达到轻量级指标（3个包）就恢复输出，减少等待感
            if systemAudioBufferQueue.count < systemAudioPreRollHighWaterMark {
                return noErr
            } else {
                isSystemAudioBuffering = false
            }
        }

        // 如果输出态队列耗尽，立即进入缓冲态重积攒 3 个包，消除所有模式下的断续感
        if systemAudioBufferQueue.isEmpty {
            isSystemAudioBuffering = true
            return noErr
        }

        var framesCopied: AVAudioFrameCount = 0
        let sampleSize = MemoryLayout<Float>.size

        while framesCopied < frameCount && !systemAudioBufferQueue.isEmpty {
            let buffer = systemAudioBufferQueue[0]
            let framesAvailable = buffer.frameLength - systemAudioBufferReadOffset
            let framesLeft = frameCount - framesCopied
            let framesToCopy = min(framesLeft, framesAvailable)

            let srcPointer = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)

            for i in 0..<min(ablPointer.count, srcPointer.count) {
                let dstByteOffset = Int(framesCopied) * sampleSize
                let srcByteOffset = Int(systemAudioBufferReadOffset) * sampleSize
                let bytesToCopy = Int(framesToCopy) * sampleSize

                if let srcData = srcPointer[i].mData, let dstData = ablPointer[i].mData {
                    memcpy(
                        dstData.advanced(by: dstByteOffset), srcData.advanced(by: srcByteOffset),
                        bytesToCopy)
                }
            }

            framesCopied += framesToCopy
            systemAudioBufferReadOffset += framesToCopy

            if systemAudioBufferReadOffset >= buffer.frameLength {
                systemAudioBufferQueue.removeFirst()
                systemAudioBufferReadOffset = 0
            }
        }

        return noErr
    }

    // MARK: - 混合录音配置（麦克风 + 系统音频）
    @available(macOS 13.0, *)
    private func setupMixedRecording() async throws {
        // 1. 设置硬件输入设备 (麦克风)
        try updateInputDevice()
        setupRecordingMixer()

        // 2. 混合录制：开启弹性缓冲以对齐异构时钟
        isSystemAudioBuffering = true

        // 3. 麦克风 -> Bus 0 (使用 0.7 增益)
        let inputNode = audioEngine.inputNode
        audioEngine.connect(
            inputNode, to: recordingMixer, fromBus: 0, toBus: 0, format: recordingFormat)
        inputNode.volume = 0.7

        // 4. 启动系统音频采集
        try await startSystemAudioCapture()

        // 5. 将系统音频包装为 SourceNode 接入混音器 Bus 1
        systemAudioSourceNode = AVAudioSourceNode(format: recordingFormat) {
            [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            return self.fillSystemAudioBuffer(audioBufferList, frameCount: frameCount)
        }

        if let sourceNode = systemAudioSourceNode {
            audioEngine.attach(sourceNode)
            audioEngine.connect(
                sourceNode, to: recordingMixer, fromBus: 0, toBus: 1, format: recordingFormat)
            // 6. 系统音也设为 0.7 增益，在轻量缓冲策略下 0.7 已足够安全
            sourceNode.volume = 0.7
            print("🎸 混合链路定向加固：Mic(v0.7), Sys(v0.7), 轻量弹性缓冲已开启")
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

        // 【性能至上】配置精简，彻底解决外接鼠标卡顿问题
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 5)  // 极低帧率
        configuration.showsCursor = false  // ！！！关键修复：禁止光标捕获，解决鼠标移动卡顿

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
        // 如果已暂停，直接丢弃数据
        guard !isPaused else { return }

        guard CMSampleBufferIsValid(sampleBuffer),
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        let srcFormat = AVAudioFormat(streamDescription: asbd)!
        let dstFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!

        // 步骤 1：创建一个临时的中转 Buffer（局部变量分配足矣，无需在此处 deepCopy）
        guard let tempBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount)
        else { return }
        tempBuffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: tempBuffer.mutableAudioBufferList
        )

        if status != noErr { return }

        if srcFormat.isEqual(dstFormat) {
            self.enqueueSystemAudioBuffer(tempBuffer)
        } else {
            // 获取转换器（使用锁保护成员变量访问）
            var converter: AVAudioConverter?
            systemAudioQueueLock.lock()
            if let cached = cachedAudioConverter,
                let lastSrc = lastSrcFormat,
                let lastDst = lastDstFormat,
                lastSrc.isEqual(srcFormat) && lastDst.isEqual(dstFormat)
            {
                converter = cached
            } else {
                converter = AVAudioConverter(from: srcFormat, to: dstFormat)
                cachedAudioConverter = converter
                lastSrcFormat = srcFormat
                lastDstFormat = dstFormat
            }
            systemAudioQueueLock.unlock()

            guard let activeConverter = converter,
                let finalBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: frameCount)
            else { return }
            finalBuffer.frameLength = frameCount

            // 【性能重构】：AVAudioConverter 的 convert 运行在主采集线程，不再持有 systemAudioQueueLock。
            // 这样能够彻底消除由于采样率转换耗时导致的渲染线程（fillSystemAudioBuffer）阻塞，
            // 进而消除了由于锁竞争产生的“断续感”。
            var error: NSError?
            activeConverter.convert(to: finalBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return tempBuffer
            }

            if error == nil {
                self.enqueueSystemAudioBuffer(finalBuffer)
            }

        }
    }

    private func enqueueSystemAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        systemAudioQueueLock.lock()
        defer { systemAudioQueueLock.unlock() }

        systemAudioBufferQueue.append(buffer)
        if systemAudioBufferQueue.count > systemAudioQueueLimit {
            systemAudioBufferQueue.removeFirst()
            // 如果删掉的是当前正在读的帧（理论不应发生），重置偏移
            if systemAudioBufferReadOffset > 0 {
                systemAudioBufferReadOffset = 0
            }
        }
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

    private func processAudioBufferWithPTS(_ buffer: AVAudioPCMBuffer, pts: CMTime) {
        // 1. 实现 Buffer 池化复用
        let bufferCopy: AVAudioPCMBuffer
        bufferPoolLock.lock()
        var pooledBuffer = audioBufferPool.popLast()

        // 如果格式不匹配或容量不足，直接丢弃池中过期的 buffer
        if let pb = pooledBuffer,
            !pb.format.isEqual(buffer.format) || pb.frameCapacity < buffer.frameLength
        {
            pooledBuffer = nil
        }

        if let pb = pooledBuffer {
            // 池中有合法的 Buffer，复用之
            let channels = min(Int(buffer.format.channelCount), Int(pb.format.channelCount))
            if let src = buffer.floatChannelData, let dstChannels = pb.floatChannelData {
                for i in 0..<channels {
                    let framesToCopy = min(buffer.frameLength, pb.frameCapacity)
                    memcpy(dstChannels[i], src[i], Int(framesToCopy) * MemoryLayout<Float>.size)
                }
            }
            pb.frameLength = buffer.frameLength
            bufferCopy = pb
        } else {
            // 池空或不匹配，深拷贝
            bufferCopy = buffer.deepCopy() ?? buffer
        }
        bufferPoolLock.unlock()

        writingQueue.async { [weak self] in
            guard let self = self, let currentWriter = self.assetWriter,
                let currentInput = self.assetWriterInput, self.isRecording
            else {
                self?.returnBufferToPool(bufferCopy)
                return
            }

            defer {
                self.returnBufferToPool(bufferCopy)
            }

            // 【重磅加固】：确保在首次写入前启动 Session
            if !self.isWriterStarted {
                currentWriter.startSession(atSourceTime: .zero)
                self.isWriterStarted = true
            }

            if currentInput.isReadyForMoreMediaData {
                if let sampleBuffer = self.createSampleBuffer(from: bufferCopy, pts: pts) {
                    if !currentInput.append(sampleBuffer) {
                        LogManager.shared.error("追加采样数据失败")
                    }
                }
            } else {
                // 如果写入繁忙，跳过本帧，由于 pts 已锁定，不会缩短时长
                if Date().timeIntervalSince1970 - self.lastWarningTime > 2.0 {
                    LogManager.shared.warning("写入队列繁忙，临时丢弃采样")
                    self.lastWarningTime = Date().timeIntervalSince1970
                }
            }
        }
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        // 已废弃，由 processAudioBufferWithPTS 替代
    }

    // 将使用完的 Buffer 归还给池以便重用
    private func returnBufferToPool(_ buffer: AVAudioPCMBuffer) {
        bufferPoolLock.lock()
        if audioBufferPool.count < bufferPoolLimit {
            audioBufferPool.append(buffer)
        }
        bufferPoolLock.unlock()
    }

    private func createSampleBuffer(from buffer: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer? {
        let timescale = pts.timescale

        var formatDescription: CMFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: buffer.format.streamDescription, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &formatDescription)
        guard status == noErr, let format = formatDescription else { return nil }

        var timing = CMSampleTimingInfo(

            duration: CMTime(value: 1, timescale: timescale),
            presentationTimeStamp: pts,
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

        return sb
    }

    func stopRecording() {
        guard isRecording, !isTransitioning else {
            LogManager.shared.warning(
                "忽略停止请求 | isRecording: \(isRecording), isTransitioning: \(isTransitioning)")
            return
        }
        isTransitioning = true

        LogManager.shared.info("正在结束录音 | 已录制时长: \(String(format: "%.1f", recordingDuration))s")
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
                        let finalURL = self.renameToFinalFormat(url: url)
                        let fileSize =
                            (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size]
                                as? Int64) ?? 0
                        let fileSizeMB = Double(fileSize) / (1024 * 1024)
                        LogManager.shared.info(
                            "录音已保存 | 时长: \(String(format: "%.1f", self.recordingDuration))s, 文件大小: \(String(format: "%.2f", fileSizeMB))MB, 路径: \(finalURL.path)"
                        )

                        // 如果是因为达到上限停止的，给予弹窗提示
                        if self.isAutoStoppedByLimit {
                            self.showRecordingLimitReachedAlert(duration: self.recordingDuration)
                            self.isAutoStoppedByLimit = false
                        }

                        // 检查是否需要转换为 MP3
                        if AppSettings.shared.outputFormat == .mp3 {
                            self.convertToMP3(from: finalURL) { mp3URL in
                                if AppSettings.shared.openFolderAfterRecording {
                                    if let mp3URL = mp3URL {
                                        NSWorkspace.shared.activateFileViewerSelecting([mp3URL])
                                    } else {
                                        NSWorkspace.shared.activateFileViewerSelecting([finalURL])
                                    }
                                }
                            }
                        } else {
                            if AppSettings.shared.openFolderAfterRecording {
                                NSWorkspace.shared.activateFileViewerSelecting([finalURL])
                            }
                        }
                    } else if let err = currentWriter?.error {
                        LogManager.shared.error("写入结束时出错 | 错误: \(err.localizedDescription)")
                    } else {
                        LogManager.shared.warning(
                            "写入可能未正常完成 | 状态: \(currentWriter?.status.rawValue ?? -1)")
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

    // MARK: - 暂停/继续录音
    func togglePause() {
        if isPaused {
            resumeRecording()
        } else {
            pauseRecording()
        }
    }

    func pauseRecording() {
        guard isRecording, !isPaused, !isTransitioning else {
            LogManager.shared.warning("忽略暂停请求 | isRecording: \(isRecording), isPaused: \(isPaused)")
            return
        }

        LogManager.shared.info("暂停录音 | 已录制时长: \(String(format: "%.1f", recordingDuration))s")

        // 1. 暂停计时器
        recordingTimer?.invalidate()
        recordingTimer = nil

        // 2. 统计当前已录制时间段并更新累计时长
        if let startDate = currentSegmentStartTime {
            accumulatedDuration += Date().timeIntervalSince(startDate)
            recordingDuration = accumulatedDuration
        }
        currentSegmentStartTime = nil

        // 3. 停止音频引擎，暂停麦克风采集
        audioEngine.pause()

        // 4. 【核心修复】暂停时清空滞后队列，防止恢复时播放陈旧数据
        systemAudioQueueLock.lock()
        for buffer in systemAudioBufferQueue {
            returnBufferToPool(buffer)
        }
        systemAudioBufferQueue.removeAll()
        systemAudioBufferReadOffset = 0
        systemAudioQueueLock.unlock()

        // 5. 【关键优化】系统音频采集 (SCStream) 在暂停时不关闭。
        isPaused = true

        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
    }

    func resumeRecording() {
        guard isRecording, isPaused, !isTransitioning else {
            LogManager.shared.warning("忽略继续请求 | isRecording: \(isRecording), isPaused: \(isPaused)")
            return
        }

        LogManager.shared.info("继续录音 | 已录制时长: \(String(format: "%.1f", recordingDuration))s")

        // 1. 继续音频引擎（从 pause 状态恢复）
        do {
            try audioEngine.start()
        } catch {
            LogManager.shared.error("继续录音失败 | 错误: \(error.localizedDescription)")
            showAudioEngineResumeFailedAlert()
            return
        }

        // 2. 【核心修复】恢复录音前清空可能在间隙中残留的数据，并重置缓冲状态
        systemAudioQueueLock.lock()
        for buffer in systemAudioBufferQueue {
            returnBufferToPool(buffer)
        }
        systemAudioBufferQueue.removeAll()
        systemAudioBufferReadOffset = 0
        // 混合模式恢复时重新开启预缓冲建立储备，单系统音频模式保持实时
        isSystemAudioBuffering = (currentAudioSource == .both)
        systemAudioQueueLock.unlock()

        // 3. 重置转换器内部状态，防止相位残音
        cachedAudioConverter?.reset()

        // 3. 恢复计时器

        currentSegmentStartTime = Date()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let startDate = self.currentSegmentStartTime else { return }
            self.recordingDuration = self.accumulatedDuration + Date().timeIntervalSince(startDate)
            if self.recordingDuration >= self.maxDuration {
                self.isAutoStoppedByLimit = true
                self.stopRecording()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer

        isPaused = false
        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
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
        guard let startDate = actualStartTime else { return url }
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

    // MARK: - M4A 转 MP3
    private func convertToMP3(from sourceURL: URL, completion: @escaping (URL?) -> Void) {
        let mp3URL = sourceURL.deletingPathExtension().appendingPathExtension("mp3")

        LogManager.shared.info("开始转换 MP3 | 源文件: \(sourceURL.lastPathComponent)")

        DispatchQueue.global(qos: .userInitiated).async {
            // 使用嵌入的 LameEncoder 进行转换
            let success = LameEncoder.convertToMP3(from: sourceURL, to: mp3URL)

            if success {
                // 转换成功，删除原 M4A 文件
                try? FileManager.default.removeItem(at: sourceURL)

                let fileSize =
                    (try? FileManager.default.attributesOfItem(atPath: mp3URL.path)[.size] as? Int64)
                    ?? 0
                let fileSizeMB = Double(fileSize) / (1024 * 1024)
                LogManager.shared.info(
                    "MP3 转换完成 | 文件: \(mp3URL.lastPathComponent), 大小: \(String(format: "%.2f", fileSizeMB))MB"
                )

                DispatchQueue.main.async { completion(mp3URL) }
            } else {
                LogManager.shared.warning("MP3 转换失败，保留原 M4A 文件")
                DispatchQueue.main.async { completion(nil) }
            }
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
            alert.messageText = "麦克风访问受限"
            alert.informativeText =
                "检测到由于重新构建或签名变更，系统可能未能正确识别本应用的权限。\n\n解决办法：\n1. 请在“系统设置 - 隐私与安全性 - 麦克风”中，手动将“极简录音”的任务开关先关闭再重新开启。\n2. 若列表中没有本应用，请在终端执行 'tccutil reset Microphone com.simplerecorder.app' 后重新运行。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打开设置")
            alert.addButton(withTitle: "我知道了")
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
            alert.informativeText = "请至少保留 100MB 可用空间。"
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

    private func showAudioEngineResumeFailedAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "继续录音失败"
            alert.informativeText = "音频引擎无法恢复。请停止当前录音并重新开始。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "知道了")
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

// MARK: - AVAudioPCMBuffer 扩展
extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: self.frameCapacity)
        else { return nil }
        copy.frameLength = self.frameLength
        for i in 0..<Int(self.format.channelCount) {
            if let src = self.floatChannelData?[i], let dst = copy.floatChannelData?[i] {
                memcpy(dst, src, Int(self.frameLength) * MemoryLayout<Float>.size)
            }
        }
        return copy
    }
}
