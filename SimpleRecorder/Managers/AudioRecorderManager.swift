//
//  AudioRecorderManager.swift
//  极简录音 - 录音管理器 (Fragmented MP4 方案)
//

import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation

class AudioRecorderManager: NSObject, ObservableObject {
    static let shared = AudioRecorderManager()

    @Published var isRecording = false
    @Published var currentRecordingURL: URL?
    @Published var recordingDuration: TimeInterval = 0

    // Core Audio & Asset Writer
    private let audioEngine = AVAudioEngine()
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var recordingTimer: Timer?

    // 状态管理
    private var isWriterStarted = false
    private var initialTimestamp: Double = 0

    // 时间提醒相关
    private let maxDuration: TimeInterval = 5 * 60 * 60  // 5 小时
    private let warningStartTime: TimeInterval = 4 * 60 * 60  // 4 小时开始提醒
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

    // MARK: - 崩溃恢复检测
    /// 应用启动时调用，检查是否有上次崩溃遗留的录音
    func checkForCrashedRecording() {
        print("🔍 检查崩溃恢复状态...")

        let inProgress = UserDefaults.standard.bool(forKey: recordingInProgressKey)
        let filePath = UserDefaults.standard.string(forKey: recordingFilePathKey)

        if inProgress, let path = filePath {
            if FileManager.default.fileExists(atPath: path) {
                print("✅ 发现崩溃遗留录音: \(URL(fileURLWithPath: path).lastPathComponent)")
                print("💡 说明：由于采用 fMP4 流式格式，该文件通常已包含崩溃前绝大部分内容，无需手动合并。")
                // 发送通知刷新列表
                NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
            }
        }

        // 清除崩溃标记
        clearRecordingState()

        // 清理旧版本遗留的临时目录
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
        // 检查权限
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                if granted { DispatchQueue.main.async { self?.beginRecording() } }
            }
        case .denied, .restricted:
            showMicrophonePermissionAlert()
        @unknown default:
            break
        }
    }

    private func beginRecording() {
        let recordingsPath = AppSettings.shared.recordingsPath

        // 环境预检
        guard checkDiskSpace(at: recordingsPath) else {
            showDiskSpaceAlert()
            return
        }
        guard checkDirectoryWritable(at: recordingsPath) else {
            showDirectoryPermissionAlert()
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: recordingsPath, withIntermediateDirectories: true)

            // 生成文件名
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH:mm"
            let fileName = "录音_\(dateFormatter.string(from: Date())).m4a"
            let finalFileURL = recordingsPath.appendingPathComponent(fileName)
            currentRecordingURL = finalFileURL

            // 初始化 Asset Writer
            assetWriter = try AVAssetWriter(outputURL: finalFileURL, fileType: .m4a)

            // 核心配置：开启 Fragmented MP4 模式
            // 每 10 秒强制向磁盘刷新一个片段（moof），确保崩溃时数据不损坏
            assetWriter?.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

            // AAC 编码设置 (44.1kHz, Mono, 128kbps)
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44100.0,
                AVEncoderBitRateKey: 128000,
            ]

            assetWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            assetWriterInput?.expectsMediaDataInRealTime = true

            if let input = assetWriterInput, assetWriter?.canAdd(input) == true {
                assetWriter?.add(input)
            }

            // 配置 Audio Engine
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            isWriterStarted = false
            initialTimestamp = 0

            inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) {
                [weak self] (buffer, time) in
                guard let self = self else { return }
                self.processAudioBuffer(buffer, time: time)
            }

            // 启动流程
            guard assetWriter?.startWriting() == true else {
                throw assetWriter?.error ?? NSError(domain: "AudioRecorder", code: -1)
            }

            try audioEngine.start()

            saveRecordingState(file: finalFileURL.path)

            isRecording = true
            recordingDuration = 0
            lastWarningTime = 0

            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
                [weak self] _ in
                guard let self = self else { return }
                self.recordingDuration += 1
                self.checkTimeWarning()
                if self.recordingDuration >= self.maxDuration { self.stopRecording() }
            }

            NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
            print("🎙️ 单文件可靠录音已启动 (fMP4): \(finalFileURL.lastPathComponent)")

        } catch {
            print("❌ 启动录音失败: \(error.localizedDescription)")
            showRecordingErrorAlert(message: error.localizedDescription)
        }
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let writer = assetWriter, let input = assetWriterInput, input.isReadyForMoreMediaData
        else { return }

        // 初始化时间戳
        if !isWriterStarted {
            initialTimestamp = time.audioTimeStamp.mSampleTime
            writer.startSession(atSourceTime: .zero)
            isWriterStarted = true
        }

        // 计算当前 Sample Buffer 的 CMSampleBuffer 并写入
        // 注意：AVAssetWriterInput 在 expectsMediaDataInRealTime = true 时需要 CMSampleBuffer
        if let sampleBuffer = createSampleBuffer(from: buffer, time: time) {
            input.append(sampleBuffer)
        }
    }

    private func createSampleBuffer(from buffer: AVAudioPCMBuffer, time: AVAudioTime)
        -> CMSampleBuffer?
    {
        let currentSampleTime = time.audioTimeStamp.mSampleTime - initialTimestamp
        let timescale = Int32(buffer.format.sampleRate)
        let presentationTime = CMTime(value: CMTimeValue(currentSampleTime), timescale: timescale)

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

        return sb
    }

    func stopRecording() {
        guard isRecording else { return }

        recordingTimer?.invalidate()
        recordingTimer = nil

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        assetWriterInput?.markAsFinished()

        let outputURL = currentRecordingURL
        assetWriter?.finishWriting { [weak self] in
            guard let self = self else { return }

            DispatchQueue.main.async {
                self.isRecording = false
                self.clearRecordingState()

                if let url = outputURL {
                    print("✅ 录音已保存: \(url.path)")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }

                self.assetWriter = nil
                self.assetWriterInput = nil
                self.currentRecordingURL = nil

                NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
            }
        }
    }

    func saveRecordingImmediately() {
        // 立即停止并等待写入完成
        guard isRecording else { return }

        recordingTimer?.invalidate()
        recordingTimer = nil

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        assetWriterInput?.markAsFinished()

        // 阻塞式等待（在应用退出时是安全的，因为 finiteWriting 是异步的，我们需要同步确保完成）
        let semaphore = DispatchSemaphore(value: 0)
        assetWriter?.finishWriting {
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2.0)

        isRecording = false
        clearRecordingState()
        print("🚨 录音已紧急保存完毕")
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
        guard recordingDuration >= warningStartTime else { return }
        if lastWarningTime == 0 || recordingDuration - lastWarningTime >= warningInterval {
            lastWarningTime = recordingDuration
            showTimeWarningNotification()
        }
    }

    // MARK: - UI Alerts

    private func showTimeWarningNotification() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "录音时间提醒"
            alert.informativeText = "当前录音已超过 4 小时，离 5 小时上限越来越近。已启用 fMP4 实时固化保护。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "知道了")
            alert.runModal()
        }
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
