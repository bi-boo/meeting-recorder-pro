//
//  AudioRecorderManagerEngine.swift
//  会议录音 Pro - 音频引擎配置
//
//  职责范围：
//  - 录音启动流程编排（环境预检 → 选择音源 → 配置引擎）
//  - 麦克风采集通路搭建（AVAudioEngine + Tap）
//  - 录音资源清理
//  - 防止系统休眠
//

import AVFoundation
import AppKit
import Foundation
import IOKit.pwr_mgt

extension AudioRecorderManager {

    // MARK: - 录音启动入口

    @discardableResult
    func beginRecording() -> Bool {
        // recordingState 已在 startRecording() 设为 .starting，此处无需再设

        let recordingsPath = AppSettings.shared.recordingsPath

        // 环境预检
        guard checkDiskSpace(at: recordingsPath) else {
            recordingState = .idle
            showDiskSpaceAlert()
            return false
        }
        guard checkDirectoryWritable(at: recordingsPath) else {
            recordingState = .idle
            showDirectoryPermissionAlert()
            return false
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
            return startMicrophoneRecording(at: recordingsPath)
        case .systemAudio, .both:
            // 系统音频模式：需要 async，使用 Task 启动
            if #available(macOS 13.0, *) {
                Task { @MainActor in
                    await self.startSystemAudioRecording(at: recordingsPath)
                }
                return true
            } else {
                // 降级到麦克风
                return startMicrophoneRecording(at: recordingsPath)
            }
        }
    }

    // MARK: - 麦克风录音启动（同步）
    @discardableResult
    func startMicrophoneRecording(at recordingsPath: URL) -> Bool {
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
            framesCounter.withLock { $0 = 0 }

            // 在配置新录音前确保引擎处于干净状态
            prepareAudioEngineForNewRecording()

            try setupMicrophoneOnlyRecording()

            guard assetWriter?.startWriting() == true else {
                throw assetWriter?.error ?? NSError(domain: "AudioRecorder", code: -1)
            }

            try audioEngine.start()
            finalizeRecordingStart(fileURL: finalFileURL)
            return true

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

            recordingState = .idle
            return false
        }
    }

    // MARK: - 系统音频录音启动（异步）
    @available(macOS 13.0, *)
    func startSystemAudioRecording(at recordingsPath: URL) async {
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
            framesCounter.withLock { $0 = 0 }

            // 在配置新录音前确保引擎处于干净状态
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
            let stream = systemAudioStream
            systemAudioStream = nil
            systemAudioOutput = nil
            Task {
                try? await stream?.stopCapture()
            }

            // 清空缓冲队列
            clearSystemAudioBufferQueue()

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

            recordingState = .idle
        }
    }

    // MARK: - 录音启动完成处理
    func finalizeRecordingStart(fileURL: URL) {
        // 开始新的录音会话
        let sessionID = LogManager.shared.startRecordingSession()

        accumulatedDuration = 0
        actualStartTime = Date()
        currentSegmentStartTime = actualStartTime
        saveRecordingState(file: fileURL.path)

        recordingState = .recording
        recordingDuration = 0
        framesCounter.withLock { $0 = 0 }
        systemAudioBufferHeadIndex = 0
        systemAudioBufferReadOffset = 0
        // 初始缓冲状态：仅在混合模式下默认开启以平滑时钟，仅系统音频模式下将由 setup 逻辑显式关闭
        isSystemAudioBuffering = (currentAudioSource == .both)
        lastWarningTime = 0
        lastDiskCheckTime = Date().timeIntervalSince1970
        isHandlingInterruption = false
        droppedFrameCount = 0
        totalFrameCount = 0

        hasPrintedFirstSample = false
        hasPrintedSystemAudioFormat = false
        lastStatsLogTime = Date().timeIntervalSince1970

        // 【录音中断检测】保存当前使用的设备信息
        recordingDeviceID = AppSettings.shared.selectedDeviceID
        recordingDeviceName =
            AppSettings.shared.availableInputDevices.first(where: {
                $0.id == AppSettings.shared.selectedDeviceID
            })?.name

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let startDate = self.currentSegmentStartTime else { return }
            self.recordingDuration = self.accumulatedDuration + Date().timeIntervalSince(startDate)

            // 检查是否达到时长上限
            if self.recordingDuration >= self.maxDuration {
                self.isAutoStoppedByLimit = true
                self.stopRecording()
                return
            }

            // 【录音中断检测】定期检查磁盘空间（每 30 秒）
            let currentTime = Date().timeIntervalSince1970
            if currentTime - self.lastDiskCheckTime >= self.diskCheckInterval {
                self.lastDiskCheckTime = currentTime
                if !self.checkDiskSpace(at: AppSettings.shared.recordingsPath) {
                    self.handleRecordingInterruption(reason: .diskSpaceFull)
                    return
                }
            }

            // 【录音中断检测】检查 AssetWriter 状态
            if let writer = self.assetWriter, writer.status == .failed {
                self.handleRecordingInterruption(reason: .writerFailed(writer.error))
                return
            }

            // 【日志统计】每 30 秒记录一次录音状态
            if currentTime - self.lastStatsLogTime >= 30.0 {
                self.lastStatsLogTime = currentTime
                let framesWritten = self.framesCounter.withLock { $0 }
                let durationStr = String(format: "%.1f", self.recordingDuration)
                let dropRate = self.totalFrameCount > 0 ? String(format: "%.2f%%", Double(self.droppedFrameCount) / Double(self.totalFrameCount) * 100) : "N/A"
                let hwFormat = self.audioEngine.inputNode.inputFormat(forBus: 0)
                LogManager.shared.debug("录音进度 | 时长: \(durationStr)s, 已写入帧数: \(framesWritten), 丢帧: \(self.droppedFrameCount)/\(self.totalFrameCount) (\(dropRate)), 硬件格式: \(hwFormat.sampleRate)Hz/\(hwFormat.channelCount)ch")
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer

        // 录音时始终禁止系统睡眠
        setupSleepPrevention()
        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)

        let deviceName = recordingDeviceName ?? "默认设备"
        LogManager.shared.info(
            "录音已启动 | 会话ID: \(sessionID), 音源: \(currentAudioSource.displayName), 输入设备: \(deviceName), 文件: \(fileURL.lastPathComponent)"
        )
    }

    // MARK: - 音频引擎预备（确保干净状态）
    /// 在每次新录音开始前调用，确保音频引擎处于干净状态
    /// 这对于从之前失败的录音恢复非常重要
    func prepareAudioEngineForNewRecording() {
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

        // 4. 【关键修复】创建全新的 AVAudioEngine 实例
        // 这可以彻底解决设备切换后 inputNode 状态不稳定导致的崩溃问题
        audioEngine = AVAudioEngine()

        // 5. 清空系统音频缓冲队列
        systemAudioQueueLock.lock()
        systemAudioBufferQueue.removeAll()
        systemAudioBufferHeadIndex = 0
        systemAudioBufferReadOffset = 0
        systemAudioQueueLock.unlock()

        // 6. 清理音频转换器缓存
        cachedAudioConverter = nil
        lastSrcFormat = nil
        lastDstFormat = nil

        LogManager.shared.debug("音频引擎已重建，准备开始新录音")
    }

    // MARK: - 仅麦克风录音配置
    func setupMicrophoneOnlyRecording() throws {
        // 1. 设置硬件输入设备（如果选择了特定设备）
        try updateInputDevice()

        // 2. 获取输入节点的硬件格式
        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)

        LogManager.shared.info(
            "硬件输入格式 | 采样率: \(hwFormat.sampleRate)Hz, 声道: \(hwFormat.channelCount)ch")

        // 3. 纯麦克风模式优化：跳过 recordingMixer，直接在 inputNode 上安装 tap
        // installTap 的 format 参数会让 AVAudioEngine 内部自动处理格式转换（重采样+声道映射），
        // 省去 AVAudioMixerNode 额外的混音处理层，减少一个潜在的缓冲抖动源
        audioEngine.mainMixerNode.outputVolume = 0  // 静音输出（仅录制，不播放）

        let format = recordingFormat
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) {
            [weak self] buffer, time in
            guard let self = self, self.isRecording else { return }

            let pts = self.framesCounter.withLock { frames -> CMTime in
                let current = frames
                frames += Int64(buffer.frameLength)
                return CMTime(value: current, timescale: Int32(format.sampleRate))
            }

            if buffer.frameLength > 0 {
                self.totalFrameCount += 1
                self.processAudioBufferWithPTS(buffer, pts: pts)
            }
        }
    }

    func setupRecordingMixer() {
        recordingMixer = AVAudioMixerNode()
        audioEngine.attach(recordingMixer)

        // 统一输出为 48kHz 单声道
        audioEngine.connect(recordingMixer, to: audioEngine.mainMixerNode, format: recordingFormat)

        // 【音质优化】预留 3dB 以上的 Headroom，防止混合时的数字削波导致沙哑
        recordingMixer.outputVolume = 1.0
        audioEngine.mainMixerNode.outputVolume = 0

        print("🎛️ 混音链路已就位：录制格式 48kHz 单声道")
    }

    func installRecordingTap() {
        let format = recordingMixer.outputFormat(forBus: 0)
        recordingMixer.installTap(onBus: 0, bufferSize: 2048, format: format) {
            [weak self] buffer, time in
            // 【关键修复】移除 isPaused 检查
            // audioEngine.pause() 会暂停引擎本身，tap 回调在暂停期间不会被调用
            // 这样恢复时 tap 能立即处理数据，不会因 isPaused 设置时机导致丢数据
            guard let self = self, self.isRecording else { return }

            // 原子地读取当前帧计数并递增，确保 PTS 绝对准确且无数据竞争
            let pts = self.framesCounter.withLock { frames -> CMTime in
                let current = frames
                frames += Int64(buffer.frameLength)
                return CMTime(value: current, timescale: Int32(format.sampleRate))
            }

            if buffer.frameLength > 0 {
                self.totalFrameCount += 1
                self.processAudioBufferWithPTS(buffer, pts: pts)
            }
        }
    }

    // MARK: - 音频采集资源清理
    func cleanupAudioCapture() {
        LogManager.shared.debug("开始清理音频采集资源...")

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
        let queueCount = systemAudioBufferQueue.count
        systemAudioBufferQueue.removeAll()
        systemAudioBufferHeadIndex = 0
        systemAudioBufferReadOffset = 0
        systemAudioQueueLock.unlock()

        // 6. 清理设备激活会话（用于 iPhone 连续互通等设备）
        stopDeviceActivationSession()

        LogManager.shared.debug("音频采集资源已清理 | 清空缓冲队列: \(queueCount) 帧")
    }

    // MARK: - Power Management (Sleep Prevention)

    /// 开启防止休眠断言
    func setupSleepPrevention() {
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
            LogManager.shared.info("已开启录音防休眠断言 | AssertionID: \(sleepAssertionID)")
        } else {
            LogManager.shared.warning("开启防休眠断言失败 | 错误码: \(result)")
        }
    }

    /// 释放防止休眠断言
    func releaseSleepPrevention() {
        guard sleepAssertionID != 0 else { return }
        let result = IOPMAssertionRelease(sleepAssertionID)
        if result == kIOReturnSuccess {
            LogManager.shared.info("已释放录音防休眠断言")
            sleepAssertionID = 0
        } else {
            LogManager.shared.warning("释放防休眠断言失败 | 错误码: \(result)")
        }
    }
}
