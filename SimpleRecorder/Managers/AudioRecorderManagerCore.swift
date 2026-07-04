//
//  AudioRecorderManagerCore.swift
//  会议录音 Pro - 录音管理器（主文件）
//
//  这是 AudioRecorderManager 类的主文件，作为"总指挥"，包含：
//  - 状态机定义（RecordingState、RecordingInterruptionReason）
//  - 所有属性声明（跨文件 extension 共享）
//  - init / deinit
//  - 公开生命周期 API：startRecording / stopRecording / togglePause / pauseRecording / resumeRecording
//  - 紧急保存 API：saveRecordingImmediately
//  - 录音状态持久化（崩溃恢复用 UserDefaults）
//
//  具体功能模块拆分到以下 extension 文件：
//  - AudioRecorderManagerEngine.swift        音频引擎配置 / 麦克风采集 / 防休眠
//  - AudioRecorderManagerSystemAudio.swift   系统音频采集 / 弹性缓冲 / SCStream
//  - AudioRecorderManagerWriter.swift        Buffer 池 / AssetWriter 写入 / 文件命名 / MP3 转换
//  - AudioRecorderManagerDevice.swift        设备监听 / 设备激活
//  - AudioRecorderManagerUI.swift            弹窗 / 磁盘+权限检查 / 中断处理
//

import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation
import IOKit.pwr_mgt
import os
import ScreenCaptureKit

// MARK: - 录音状态枚举
/// 用单一枚举描述录音生命周期的所有核心状态，替代原来的多个布尔变量
enum RecordingState {
    case idle       // 空闲（未录音）
    case starting   // 正在启动（权限检查/引擎初始化期间）
    case recording  // 录音中
    case paused     // 已暂停
    case stopping   // 正在停止（文件写入收尾期间）
}

// MARK: - 录音中断原因枚举
/// 定义所有可能导致录音中断的场景
enum RecordingInterruptionReason {
    case deviceRemoved(deviceName: String)  // 当前麦克风设备被移除
    case deviceChanged  // 音频设备路由发生变更
    case engineConfigurationChanged  // 音频引擎配置变更
    case systemAudioStreamError(Error)  // 系统音频采集错误
    case diskSpaceFull  // 磁盘空间不足
    case writerFailed(Error?)  // 写入器失败

    /// 返回用户可读的中文描述
    var localizedDescription: String {
        switch self {
        case .deviceRemoved(let deviceName):
            return "您使用的麦克风「\(deviceName)」已断开"
        case .deviceChanged:
            return "您的音频设备发生了变化（例如插拔耳机或连接蓝牙设备）"
        case .engineConfigurationChanged:
            return "您的音频设备发生了变化（例如插拔耳机或连接蓝牙设备）"
        case .systemAudioStreamError:
            return "系统音频采集被中断（可能是权限被撤销）"
        case .diskSpaceFull:
            return "磁盘空间不足"
        case .writerFailed:
            return "录音文件保存失败"
        }
    }
}

/// 内部辅助类：用于在 saveRecordingImmediately 的通知回调里持有 observer 引用
final class NotificationObserverBox {
    var token: NSObjectProtocol?
}

class AudioRecorderManager: NSObject, ObservableObject {
    static let shared = AudioRecorderManager()

    @Published var recordingState: RecordingState = .idle
    @Published var currentRecordingURL: URL?
    @Published var recordingDuration: TimeInterval = 0
    @Published var isFinalizingOutput = false

    /// 对外兼容属性，外部代码（AppDelegate、Views）无需改动
    var isRecording: Bool { recordingState == .recording || recordingState == .paused || recordingState == .stopping }
    var isPaused: Bool { recordingState == .paused }

    // Core Audio & Asset Writer
    var audioEngine = AVAudioEngine()  // 【改为 var】允许重建以解决设备切换后的状态问题
    var assetWriter: AVAssetWriter?
    var assetWriterInput: AVAssetWriterInput?
    let writingQueue = DispatchQueue(
        label: "com.meetingrecorderpro.writingQueue", qos: .userInitiated)
    var recordingTimer: Timer?
    var sleepAssertionID: IOPMAssertionID = 0
    var accumulatedDuration: TimeInterval = 0
    var currentSegmentStartTime: Date?
    var actualStartTime: Date?

    // 状态管理
    var isWriterStarted = false
    private var outputFinalizationCompletions: [() -> Void] = []
    // 使用 OSAllocatedUnfairLock 保护 totalFramesWritten（realtime 音频线程与主线程共同访问）
    let framesCounter = OSAllocatedUnfairLock<Int64>(initialState: 0)
    let audioBufferAcceptanceLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    var isAutoStoppedByLimit = false  // 标记是否因为达到时长上限而停止

    // 当前录音使用的音频源（录音开始时锁定）
    var currentAudioSource: AudioSource = .microphone

    // 系统音频采集相关（macOS 13.0+）
    var systemAudioStream: SCStream?
    var systemAudioOutput: SystemAudioStreamOutput?
    let systemAudioSampleQueueKey = DispatchSpecificKey<Bool>()
    let systemAudioSampleQueue = DispatchQueue(
        label: "com.meetingrecorderpro.systemAudioSampleQueue", qos: .userInitiated)

    // 【新增】麦克风设备激活相关（用于激活 iPhone 连续互通设备）
    var deviceActivationSession: AVCaptureSession?
    var deviceActivationInput: AVCaptureDeviceInput?

    // 用于混音的 Mixer Node
    var mixerNode: AVAudioMixerNode?
    var recordingMixer: AVAudioMixerNode!
    var systemAudioSourceNode: AVAudioSourceNode?

    // 系统音频缓冲队列
    var systemAudioBufferQueue = [AVAudioPCMBuffer]()
    var systemAudioBufferHeadIndex = 0
    var systemAudioBufferReadOffset: AVAudioFrameCount = 0  // 追踪第一帧缓冲区的读取进度
    var isSystemAudioBuffering = true  // 缓冲状态机
    let systemAudioPreRollHighWaterMark = 3  // 降低到 3 个包（约 60ms），减少断续感
    let systemAudioQueueLimit = 600  // 容错缓冲区上限
    let systemAudioQueueLock = NSLock()

    // 音频转换器缓存，用于修复系统音转换时的相位不连续/失真问题
    var cachedAudioConverter: AVAudioConverter?
    var lastSrcFormat: AVAudioFormat?
    var lastDstFormat: AVAudioFormat?
    var systemAudioCaptureGeneration = 0

    // 调试辅助标记
    var hasPrintedFirstSample = false
    var hasPrintedSystemAudioFormat = false
    var lastLevelLogTime: TimeInterval = 0

    // 【性能优化】音频 Buffer 池相关
    // 预分配 Buffer 避免在音频回调线程中频繁进行内存分配
    let bufferPoolLimit = 32
    var audioBufferPool = [AVAudioPCMBuffer]()
    let bufferPoolLock = NSLock()

    // 动态时长限制设置
    var maxDuration: TimeInterval {
        AppSettings.shared.maxRecordingDuration
    }

    // 统一的内部录音格式（48kHz, 单声道）
    let recordingFormat = AVAudioFormat(standardFormatWithSampleRate: 48000.0, channels: 1)!
    let warningInterval: TimeInterval = 10 * 60  // 每 10 分钟提醒
    var lastWarningTime: TimeInterval = 0

    // 最小磁盘空间要求：按当前最长录音和输出格式动态估算，同时保留 100MB 下限。
    var minimumDiskSpace: Int64 {
        let duration = max(AppSettings.shared.maxRecordingDuration, 5 * 60)
        let m4aBytes = Int64(duration * 128_000 / 8)
        let mp3Bytes = AppSettings.shared.outputFormat == .mp3 ? m4aBytes : 0
        let estimatedBytes = Int64(Double(m4aBytes + mp3Bytes) * 1.25)
        return max(100 * 1024 * 1024, estimatedBytes + 50 * 1024 * 1024)
    }

    // 崩溃恢复相关的 UserDefaults 键
    let recordingInProgressKey = "recording_in_progress"
    let recordingFilePathKey = "recording_file_path"
    let recordingStartTimeKey = "recording_start_time"

    // 录音中断检测相关
    var recordingDeviceID: String?  // 录音开始时使用的设备 ID
    var recordingDeviceName: String?  // 录音开始时使用的设备名称
    var lastDiskCheckTime: TimeInterval = 0  // 上次磁盘空间检查时间
    let diskCheckInterval: TimeInterval = 30  // 磁盘空间检查间隔（秒）
    var lastStatsLogTime: TimeInterval = 0  // 上次统计日志时间
    var isHandlingInterruption = false  // 防止中断处理重入

    // 丢帧诊断计数：音频 tap、写入队列和主线程 timer 都会访问，必须用锁保护。
    let droppedFrameCounter = OSAllocatedUnfairLock<Int>(initialState: 0)
    let totalFrameCounter = OSAllocatedUnfairLock<Int>(initialState: 0)

    // 非阻塞通知控制器（用于录音完成/中断通知，避免阻塞主线程）
    lazy var notificationController = ReminderWindowController()

    // MARK: - 设备监听属性（在 +Device extension 中使用）

    // 保存注册时的闭包引用，以确保 Remove 时传入同一个闭包（否则监听器无法移除）
    var defaultInputListener: AudioObjectPropertyListenerBlock?
    var deviceListListener: AudioObjectPropertyListenerBlock?
    var defaultInputPropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceListPropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    // MARK: - 初始化与析构

    private override init() {
        super.init()
        LogManager.shared.info("AudioRecorderManager 初始化")
        systemAudioSampleQueue.setSpecific(key: systemAudioSampleQueueKey, value: true)
        setupAudioHardwareListeners()
        setupEngineConfigurationChangeListener()
    }

    deinit {
        removeAudioHardwareListeners()
        NotificationCenter.default.removeObserver(self)
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

    // MARK: - 录音状态持久化（用于崩溃恢复）

    func saveRecordingState(file: String) {
        UserDefaults.standard.set(true, forKey: recordingInProgressKey)
        UserDefaults.standard.set(file, forKey: recordingFilePathKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: recordingStartTimeKey)
        UserDefaults.standard.synchronize()
    }

    func clearRecordingState() {
        UserDefaults.standard.set(false, forKey: recordingInProgressKey)
        UserDefaults.standard.removeObject(forKey: recordingFilePathKey)
        UserDefaults.standard.removeObject(forKey: recordingStartTimeKey)
        UserDefaults.standard.synchronize()
    }

    func resetFrameDropStats() {
        droppedFrameCounter.withLock { $0 = 0 }
        totalFrameCounter.withLock { $0 = 0 }
    }

    var droppedFrameCount: Int {
        droppedFrameCounter.withLock { $0 }
    }

    var totalFrameCount: Int {
        totalFrameCounter.withLock { $0 }
    }

    func incrementTotalFrameCount() {
        totalFrameCounter.withLock { $0 += 1 }
    }

    @discardableResult
    func incrementDroppedFrameCount() -> Int {
        droppedFrameCounter.withLock {
            $0 += 1
            return $0
        }
    }

    func frameDropStatsSnapshot() -> (dropped: Int, total: Int, rate: String) {
        let dropped = droppedFrameCounter.withLock { $0 }
        let total = totalFrameCounter.withLock { $0 }
        let rate = total > 0 ? String(format: "%.2f%%", Double(dropped) / Double(total) * 100) : "N/A"
        return (dropped, total, rate)
    }

    func setAcceptingAudioBuffers(_ accepting: Bool) {
        audioBufferAcceptanceLock.withLock { $0 = accepting }
    }

    func canAcceptAudioBuffers() -> Bool {
        audioBufferAcceptanceLock.withLock { $0 }
    }

    func beginOutputFinalization() {
        guard !isFinalizingOutput else { return }
        isFinalizingOutput = true
    }

    func endOutputFinalization() {
        let completions = outputFinalizationCompletions
        outputFinalizationCompletions.removeAll()
        isFinalizingOutput = false
        completions.forEach { $0() }
    }

    func waitForOutputFinalization(completion: @escaping () -> Void) {
        if isFinalizingOutput {
            outputFinalizationCompletions.append(completion)
        } else {
            completion()
        }
    }

    // MARK: - 公开 API：启动录音

    @discardableResult
    func startRecording() -> Bool {
        // 防止在非空闲状态下重复启动
        guard recordingState == .idle else {
            LogManager.shared.warning("忽略启动请求 | 当前状态: \(recordingState)")
            return false
        }
        LogManager.shared.info("收到录音启动请求")

        // 提前进入 starting 状态，防止并发调用
        recordingState = .starting

        // 检查权限
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        LogManager.shared.info("权限检测 | 当前麦克风授权状态: \(status.rawValue) (0:n/d, 1:res, 2:den, 3:auth)")

        switch status {
        case .authorized:
            return beginRecording()
        case .notDetermined:
            LogManager.shared.info("权限状态未确定，正在请求访问...")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                LogManager.shared.info("权限请求结果: \(granted ? "用户已授权" : "用户已拒绝")")
                if granted {
                    DispatchQueue.main.async { self?.beginRecording() }
                } else {
                    DispatchQueue.main.async { self?.recordingState = .idle }
                }
            }
            return true
        case .denied, .restricted:
            LogManager.shared.warning("权限被拒绝或受限，无法开始录音 | 状态: \(status.rawValue)")
            recordingState = .idle
            showMicrophonePermissionAlert()
            return false
        @unknown default:
            LogManager.shared.error("未知的权限状态: \(status.rawValue)")
            recordingState = .idle
            return false
        }
    }

    // MARK: - 公开 API：停止录音

    func stopRecording() {
        guard recordingState == .recording || recordingState == .paused else {
            LogManager.shared.warning("忽略停止请求 | 当前状态: \(recordingState)")
            return
        }
        recordingState = .stopping
        setAcceptingAudioBuffers(false)

        let finalDuration = recordingDuration
        let finalFrames = framesCounter.withLock { $0 }
        let stats = frameDropStatsSnapshot()
        LogManager.shared.info(
            "正在结束录音 | 已录制时长: \(String(format: "%.1f", finalDuration))s, 总帧数: \(finalFrames), 丢帧: \(stats.dropped)/\(stats.total) (\(stats.rate))")
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
            guard let currentWriter = currentWriter else {
                DispatchQueue.main.async {
                    self.recordingState = .idle
                    self.isWriterStarted = false
                    self.isHandlingInterruption = false
                    self.assetWriter = nil
                    self.assetWriterInput = nil
                    self.currentRecordingURL = nil
                    self.recordingDeviceID = nil
                    self.recordingDeviceName = nil
                    self.clearRecordingState()
                    self.releaseSleepPrevention()
                    LogManager.shared.endRecordingSession()
                    NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
                }
                return
            }

            currentInput?.markAsFinished()
            LogManager.shared.debug("写入队列已接收停止指令，正在固化文件...")

            currentWriter.finishWriting { [weak self] in
                guard let self = self else { return }

                DispatchQueue.main.async {
                    self.recordingState = .idle
                    self.clearRecordingState()

                    // 结束录音会话
                    LogManager.shared.endRecordingSession()

                    if currentWriter.status == .completed, let url = outputURL {
                        let finalURL = self.renameToFinalFormat(url: url)
                        let fileSize =
                            (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size]
                                as? Int64) ?? 0
                        let fileSizeMB = Double(fileSize) / (1024 * 1024)
                        LogManager.shared.info(
                            "录音已保存 | 时长: \(String(format: "%.1f", finalDuration))s, 文件大小: \(String(format: "%.2f", fileSizeMB))MB, 路径: \(finalURL.path)"
                        )

                        // 如果是因为达到上限停止的，给予弹窗提示
                        if self.isAutoStoppedByLimit {
                            self.showRecordingLimitReachedAlert(duration: finalDuration)
                            self.isAutoStoppedByLimit = false
                        }

                        let shouldOpenFolder = AppSettings.shared.openFolderAfterRecording

                        // 检查是否需要转换为 MP3。转码延迟到当前收尾闭包返回后启动，
                        // 确保 AVAssetWriter 已释放刚写完的 M4A 文件。
                        if AppSettings.shared.outputFormat == .mp3 && MP3Encoder.isEncodingAvailable {
                            self.beginOutputFinalization()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                                guard let self = self else { return }
                                self.convertToMP3(from: finalURL) { mp3URL in
                                    if shouldOpenFolder {
                                        if let mp3URL = mp3URL {
                                            NSWorkspace.shared.activateFileViewerSelecting([mp3URL])
                                        } else {
                                            NSWorkspace.shared.activateFileViewerSelecting([finalURL])
                                        }
                                    }
                                    self.endOutputFinalization()
                                }
                            }
                        } else {
                            if shouldOpenFolder {
                                NSWorkspace.shared.activateFileViewerSelecting([finalURL])
                            }
                        }
                    } else if let err = currentWriter.error {
                        LogManager.shared.error("写入结束时出错 | 错误: \(err.localizedDescription)")
                    } else {
                        LogManager.shared.warning(
                            "写入可能未正常完成 | 状态: \(currentWriter.status.rawValue)")
                    }

                    // 3. 后续清理
                    if self.assetWriter === currentWriter { self.assetWriter = nil }
                    if self.assetWriterInput === currentInput { self.assetWriterInput = nil }
                    self.currentRecordingURL = nil

                    self.releaseSleepPrevention()
                    NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
                }
            }
        }
    }

    // MARK: - 公开 API：暂停 / 继续

    func togglePause() {
        if isPaused {
            resumeRecording()
        } else {
            pauseRecording()
        }
    }

    func pauseRecording() {
        guard recordingState == .recording else {
            LogManager.shared.warning("忽略暂停请求 | 当前状态: \(recordingState)")
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
        systemAudioBufferHeadIndex = 0
        systemAudioBufferReadOffset = 0
        systemAudioQueueLock.unlock()

        // 5. 【关键优化】系统音频采集 (SCStream) 在暂停时不关闭。
        recordingState = .paused

        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
    }

    func resumeRecording() {
        guard recordingState == .paused else {
            LogManager.shared.warning("忽略继续请求 | 当前状态: \(recordingState)")
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

        // 2. 先在系统音频采集队列上重置缓冲和 converter，再恢复录音态。
        //    这样不会和正在执行的 SCStream 音频回调并发访问同一个 AVAudioConverter。
        resetSystemAudioStateForResume()
        recordingState = .recording

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

        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
    }

    // MARK: - 公开 API：紧急保存

    /// 立即保存当前录音（异步，完成后在主线程回调）
    func saveRecordingImmediately(completion: (() -> Void)? = nil) {
        // 若已进入 stopping 状态（finishWriting 正在异步执行），
        // 不重复调用 finishWriting（会导致 crash），而是等待现有流程完成后触发 completion
        if recordingState == .stopping {
            let observerBox = NotificationObserverBox()
            observerBox.token = NotificationCenter.default.addObserver(
                forName: .recordingStateChanged, object: nil, queue: .main
            ) { _ in
                if let token = observerBox.token {
                    NotificationCenter.default.removeObserver(token)
                    observerBox.token = nil
                }
                self.waitForOutputFinalization {
                    completion?()
                }
            }
            return
        }

        guard recordingState == .recording || recordingState == .paused else {
            completion?(); return
        }

        recordingState = .stopping
        setAcceptingAudioBuffers(false)

        recordingTimer?.invalidate()
        recordingTimer = nil

        let outputURL = currentRecordingURL

        cleanupAudioCapture()

        let currentWriter = assetWriter
        let currentInput = assetWriterInput

        writingQueue.async { [weak self] in
            guard let currentWriter = currentWriter else {
                DispatchQueue.main.async {
                    guard let self = self else { completion?(); return }
                    self.recordingState = .idle
                    self.isWriterStarted = false
                    self.isHandlingInterruption = false
                    self.assetWriter = nil
                    self.assetWriterInput = nil
                    self.currentRecordingURL = nil
                    self.recordingDeviceID = nil
                    self.recordingDeviceName = nil
                    self.clearRecordingState()
                    self.releaseSleepPrevention()
                    NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
                    completion?()
                }
                return
            }

            currentInput?.markAsFinished()
            currentWriter.finishWriting {
                DispatchQueue.main.async {
                    guard let self = self else { completion?(); return }

                    self.recordingState = .idle
                    self.isWriterStarted = false
                    self.isHandlingInterruption = false

                    self.assetWriter = nil
                    self.assetWriterInput = nil
                    self.currentRecordingURL = nil
                    self.recordingDeviceID = nil
                    self.recordingDeviceName = nil

                    self.clearRecordingState()
                    self.releaseSleepPrevention()

                    let completeSave: () -> Void = {
                        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
                        completion?()
                    }

                    if let url = outputURL, FileManager.default.fileExists(atPath: url.path) {
                        let finalURL = self.renameToFinalFormat(url: url)
                        LogManager.shared.info("录音已紧急保存并重命名 | 文件: \(finalURL.lastPathComponent)")

                        if AppSettings.shared.outputFormat == .mp3 && MP3Encoder.isEncodingAvailable {
                            self.beginOutputFinalization()
                            self.convertToMP3(from: finalURL) { _ in
                                self.endOutputFinalization()
                                completeSave()
                            }
                            return
                        }
                    } else {
                        LogManager.shared.info("录音已紧急保存")
                    }

                    completeSave()
                }
            }
        }
    }
}
