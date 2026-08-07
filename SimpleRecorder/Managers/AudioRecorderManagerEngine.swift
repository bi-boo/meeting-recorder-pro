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
import CoreMedia
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
            NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
            showDiskSpaceAlert()
            return false
        }
        guard checkDirectoryWritable(at: recordingsPath) else {
            recordingState = .idle
            NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
            showDirectoryPermissionAlert()
            return false
        }

        // currentAudioSource 已在权限检查前锁定，避免用户在异步授权期间切换设置，
        // 也确保仅系统声音模式不会误走麦克风权限。

        // 系统音频采集依赖 ScreenCaptureKit 的显示器捕获对象，需在启动采集前阻止显示器睡眠。
        setupDisplaySleepPreventionForSystemAudio()

        // 根据音频源类型选择不同的启动方式
        switch currentAudioSource {
        case .microphone:
            // 麦克风模式：同步启动
            return startMicrophoneRecording(at: recordingsPath)
        case .systemAudio, .both:
            // 系统音频模式：需要 async，使用 Task 启动
            if #available(macOS 13.0, *) {
                let startupGeneration = recordingStartupGeneration
                Task { @MainActor in
                    guard self.recordingState == .starting,
                        self.recordingStartupGeneration == startupGeneration
                    else { return }
                    await self.startSystemAudioRecording(
                        at: recordingsPath,
                        startupGeneration: startupGeneration
                    )
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
            setAcceptingAudioBuffers(false)
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

            prepareRecordingStartupStabilityAttempt()
            try audioEngine.start()
            scheduleRecordingStartupStabilization(fileURL: finalFileURL)
            return true

        } catch {
            setAcceptingAudioBuffers(false)
            LogManager.shared.error("麦克风录音启动失败 | 错误: \(error.localizedDescription)")

            // 轻量级清理：只清理本次录音创建的资源，不调用 reset() 避免破坏引擎状态
            // 移除可能已安装的 tap
            if microphoneSourceNode == nil {
                audioEngine.inputNode.removeTap(onBus: 0)
            }
            recordingMixer?.removeTap(onBus: 0)
            stopIndependentMicrophoneCapture()
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

            resetRecordingStartupStabilityState()
            releaseDisplaySleepPrevention()
            recordingState = .idle
            NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
            return false
        }
    }

    // MARK: - 系统音频录音启动（异步）
    @available(macOS 13.0, *)
    @MainActor
    func startSystemAudioRecording(at recordingsPath: URL, startupGeneration: Int) async {
        guard recordingState == .starting,
            recordingStartupGeneration == startupGeneration
        else { return }

        do {
            setAcceptingAudioBuffers(false)
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
                try await setupSystemAudioOnlyRecording(startupGeneration: startupGeneration)
            } else {
                try await setupMixedRecording(startupGeneration: startupGeneration)
            }

            guard recordingState == .starting,
                recordingStartupGeneration == startupGeneration
            else { throw CancellationError() }

            guard assetWriter?.startWriting() == true else {
                throw assetWriter?.error ?? NSError(domain: "AudioRecorder", code: -1)
            }

            // 启动音频引擎以开始处理
            prepareRecordingStartupStabilityAttempt()
            try audioEngine.start()
            scheduleRecordingStartupStabilization(fileURL: finalFileURL)

        } catch {
            guard recordingStartupGeneration == startupGeneration else {
                LogManager.shared.info("忽略已取消的系统音频启动任务")
                return
            }
            setAcceptingAudioBuffers(false)
            LogManager.shared.error("系统音频录音启动失败 | 错误: \(error.localizedDescription)")

            // 轻量级清理：只清理本次录音创建的资源
            // 移除可能已安装的 tap
            if microphoneSourceNode == nil {
                audioEngine.inputNode.removeTap(onBus: 0)
            }
            recordingMixer?.removeTap(onBus: 0)
            stopIndependentMicrophoneCapture()
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
            invalidateSystemAudioCaptureGeneration()
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

            resetRecordingStartupStabilityState()
            releaseDisplaySleepPrevention()
            recordingState = .idle
            NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
        }
    }

    // MARK: - 启动期设备格式稳定

    func captureRecordingStartupInputConfiguration(_ format: AVAudioFormat) {
        startupConfiguredInputSampleRate = format.sampleRate
        startupConfiguredInputChannelCount = format.channelCount
    }

    func prepareRecordingStartupStabilityAttempt() {
        startupConfigurationChanged = false
        startupObservedFrameCount.withLock { $0 = 0 }
        capturedMicrophoneFrameCount.withLock { $0 = 0 }
    }

    func resetRecordingStartupStabilityState() {
        startupConfigurationChanged = false
        startupStabilityStartedAt = nil
        startupConfiguredInputSampleRate = nil
        startupConfiguredInputChannelCount = nil
        startupObservedFrameCount.withLock { $0 = 0 }
        capturedMicrophoneFrameCount.withLock { $0 = 0 }
    }

    func isRecordingStartupInputConfigurationStable() -> Bool {
        if let captureSession = microphoneCaptureSession {
            guard captureSession.isRunning,
                let activeInputDeviceID,
                AppSettings.shared.availableInputDevices.contains(where: {
                    $0.id == activeInputDeviceID
                })
            else { return false }

            if AppSettings.shared.selectedDeviceID == "default" {
                return currentDefaultInputDeviceInfo()?.id == activeInputDeviceID
            }
            return true
        }

        guard let expectedSampleRate = startupConfiguredInputSampleRate,
            let expectedChannelCount = startupConfiguredInputChannelCount
        else { return false }

        let currentFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        guard currentFormat.sampleRate > 0, currentFormat.channelCount > 0 else { return false }

        // 采样率和声道数相同不代表仍是同一个麦克风。CoreAudio 可能在引擎
        // 已产生首批帧后才完成默认输入路由切换，启动门禁必须同时核对设备 ID。
        guard RecordingStartupStabilityPolicy.inputDeviceIsStable(
            activeInputDeviceID: activeInputDeviceID,
            currentDefaultInputDeviceID: currentDefaultInputDeviceInfo()?.id
        ) else { return false }

        return abs(currentFormat.sampleRate - expectedSampleRate) <= 0.5
            && currentFormat.channelCount == expectedChannelCount
    }

    /// 含麦克风的模式必须确认引擎仍在运行、输入格式与建图时一致，且已经产生音频帧。
    /// 配置变化通知只作为诊断信号；在限定总时长内允许设备完成多轮格式协商。
    func scheduleRecordingStartupStabilization(fileURL: URL) {
        guard recordingState == .starting else { return }

        if currentAudioSource == .systemAudio {
            finalizeRecordingStart(fileURL: fileURL)
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if startupStabilityStartedAt == nil {
            startupStabilityStartedAt = now
        }

        let generation = recordingStartupGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + startupStabilizationDelay) { [weak self] in
            guard let self = self,
                self.recordingState == .starting,
                self.recordingStartupGeneration == generation
            else { return }

            let elapsed = ProcessInfo.processInfo.systemUptime
                - (self.startupStabilityStartedAt ?? ProcessInfo.processInfo.systemUptime)
            let engineIsRunning = self.audioEngine.isRunning
            let inputConfigurationIsStable = self.isRecordingStartupInputConfigurationStable()
            let observedFrames = self.microphoneCaptureSession == nil
                ? self.startupObservedFrameCount.withLock { $0 }
                : self.capturedMicrophoneFrameCount.withLock { $0 }
            let minimumObservationReached =
                elapsed >= self.minimumStartupStabilizationDuration
            let deadlineReached = elapsed >= self.maximumStartupStabilizationDuration
            let elapsedText = String(format: "%.2f", elapsed)
            let action = RecordingStartupStabilityPolicy.action(
                engineIsRunning: engineIsRunning,
                inputConfigurationIsStable: inputConfigurationIsStable,
                hasObservedAudioFrames: observedFrames > 0,
                minimumObservationReached: minimumObservationReached,
                deadlineReached: deadlineReached
            )

            LogManager.shared.debug(
                "录音启动稳定性检查 | 引擎运行: \(engineIsRunning), 输入格式稳定: \(inputConfigurationIsStable), 已观察帧: \(observedFrames), 配置通知: \(self.startupConfigurationChanged), 已等待: \(elapsedText)s")

            switch action {
            case .finalize:
                if self.startupConfigurationChanged {
                    LogManager.shared.info("启动期配置通知后引擎、输入格式和音频帧均已稳定，继续录音")
                }
                self.finalizeRecordingStart(fileURL: fileURL)
            case .wait:
                self.startupConfigurationChanged = false
                LogManager.shared.info("录音引擎和输入格式已稳定，继续等待首批音频帧")
                self.scheduleRecordingStartupStabilization(fileURL: fileURL)
            case .rebuild:
                LogManager.shared.warning(
                    "启动期录音链路尚未稳定，等待设备协商后重建采集链路 | 已等待: \(elapsedText)s")
                Task { @MainActor in
                    await self.rebuildCaptureDuringStartup(
                        fileURL: fileURL,
                        generation: generation
                    )
                }
            case .fail:
                self.failRecordingStartup(
                    fileURL: fileURL,
                    message: "麦克风在 3 秒内未能形成稳定的录音链路，请重新选择麦克风后再试。"
                )
            }
        }
    }

    @MainActor
    func rebuildCaptureDuringStartup(fileURL: URL, generation: Int) async {
        guard recordingState == .starting, recordingStartupGeneration == generation else { return }

        setAcceptingAudioBuffers(false)

        do {
            // 启动期的 AVAudioEngine 格式协商只需重建麦克风/混音链路。
            // 混合录音已启动的 SCStream 不受该通知影响，保留它可避免
            // stopCapture() 的异步等待卡住整个恢复任务。
            let canReuseSystemAudioCapture = currentAudioSource == .both
                && systemAudioStream != nil
                && systemAudioOutput != nil
            prepareAudioEngineForNewRecording(
                preserveSystemAudioCapture: canReuseSystemAudioCapture)
            if currentAudioSource == .microphone {
                try setupMicrophoneOnlyRecording()
            } else if #available(macOS 13.0, *) {
                try await setupMixedRecording(
                    startupGeneration: generation,
                    reuseSystemAudioCapture: canReuseSystemAudioCapture
                )
            }

            guard recordingState == .starting,
                recordingStartupGeneration == generation
            else { return }
            prepareRecordingStartupStabilityAttempt()
            try audioEngine.start()
            scheduleRecordingStartupStabilization(fileURL: fileURL)
        } catch {
            guard recordingState == .starting,
                recordingStartupGeneration == generation
            else {
                LogManager.shared.info("忽略已取消的启动期采集重建任务")
                return
            }
            failRecordingStartup(
                fileURL: fileURL,
                message: "输入设备稳定后重新建立录音链路失败：\(error.localizedDescription)"
            )
        }
    }

    func failRecordingStartup(fileURL: URL, message: String) {
        recordingStartupGeneration += 1
        setAcceptingAudioBuffers(false)
        cleanupAudioCapture()
        assetWriter?.cancelWriting()
        assetWriter = nil
        assetWriterInput = nil
        isWriterStarted = false
        currentRecordingURL = nil
        recordingDeviceID = nil
        recordingDeviceName = nil
        recordingInputSampleRate = nil
        recordingInputChannelCount = nil
        activeInputDeviceID = nil
        activeInputDeviceName = nil
        expectedDefaultInputDeviceID = nil
        resetRecordingStartupStabilityState()
        engineConfigurationRecoveryAttempts = 0
        try? FileManager.default.removeItem(at: fileURL)
        clearRecordingState()
        releaseSleepPrevention()
        recordingState = .idle
        LogManager.shared.error("录音启动稳定性检查失败 | \(message)")
        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
        showRecordingErrorAlert(message: message)
    }

    // MARK: - 录音启动完成处理
    func finalizeRecordingStart(fileURL: URL) {
        guard recordingState == .starting else {
            LogManager.shared.warning("忽略过期的录音启动完成回调 | 当前状态: \(recordingState)")
            return
        }

        // 开始新的录音会话
        let sessionID = LogManager.shared.startRecordingSession()

        accumulatedDuration = 0
        actualStartTime = Date()
        currentSegmentStartTime = actualStartTime
        saveRecordingState(file: fileURL.path)

        recordingState = .recording
        setAcceptingAudioBuffers(true)
        recordingDuration = 0
        framesCounter.withLock { $0 = 0 }
        systemAudioBufferHeadIndex = 0
        systemAudioBufferReadOffset = 0
        // 初始缓冲状态：仅在混合模式下默认开启以平滑时钟，仅系统音频模式下将由 setup 逻辑显式关闭
        isSystemAudioBuffering = (currentAudioSource == .both)
        lastWarningTime = 0
        lastDiskCheckTime = Date().timeIntervalSince1970
        isHandlingInterruption = false
        engineConfigurationRecoveryAttempts = 0
        lastObservedFrameCount = 0
        audioStallBeganAt = nil
        resetFrameDropStats()

        hasPrintedFirstSample = false
        hasPrintedSystemAudioFormat = false
        lastStatsLogTime = Date().timeIntervalSince1970

        // 【录音中断检测】保存当前实际使用的设备信息。
        // 当用户选择“系统默认”时，也记录解析后的真实设备，避免日志和重启逻辑误判。
        recordingDeviceID = activeInputDeviceID ?? AppSettings.shared.selectedDeviceID
        recordingDeviceName =
            activeInputDeviceName
            ?? AppSettings.shared.availableInputDevices.first(where: {
                $0.id == AppSettings.shared.selectedDeviceID
            })?.name

        if microphoneCaptureSession != nil {
            recordingInputSampleRate = recordingFormat.sampleRate
            recordingInputChannelCount = recordingFormat.channelCount
        } else if currentAudioSource != .systemAudio {
            let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
            recordingInputSampleRate = inputFormat.sampleRate
            recordingInputChannelCount = inputFormat.channelCount
        } else {
            recordingInputSampleRate = nil
            recordingInputChannelCount = nil
        }
        resetRecordingStartupStabilityState()

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
                let activeRecordingDirectory =
                    self.currentRecordingURL?.deletingLastPathComponent()
                    ?? AppSettings.shared.recordingsPath
                if !self.checkDiskSpace(at: activeRecordingDirectory) {
                    self.handleRecordingInterruption(reason: .diskSpaceFull)
                    return
                }
            }

            // 【录音中断检测】检查 AssetWriter 状态
            if let writer = self.assetWriter, writer.status == .failed {
                self.handleRecordingInterruption(reason: .writerFailed(writer.error))
                return
            }

            // 【录音中断检测】设备切换后 AVAudioEngine 可能仍显示 running，
            // 但录制 tap 已经不再产出音频帧。用帧数增长检测这种“假运行”。
            if self.checkAudioCaptureProgress(currentTime: currentTime) {
                return
            }

            // 【日志统计】每 30 秒记录一次录音状态
            if currentTime - self.lastStatsLogTime >= 30.0 {
                self.lastStatsLogTime = currentTime
                let framesWritten = self.framesCounter.withLock { $0 }
                let durationStr = String(format: "%.1f", self.recordingDuration)
                let stats = self.frameDropStatsSnapshot()
                let hwFormat = self.audioEngine.inputNode.inputFormat(forBus: 0)
                LogManager.shared.debug("录音进度 | 时长: \(durationStr)s, 已写入帧数: \(framesWritten), 丢帧: \(stats.dropped)/\(stats.total) (\(stats.rate)), 硬件格式: \(hwFormat.sampleRate)Hz/\(hwFormat.channelCount)ch")
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer

        // 录音时始终禁止系统睡眠
        setupSleepPrevention()
        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)

        let deviceSelection =
            AppSettings.shared.selectedDeviceID == "default" ? "系统默认" : "用户已选择"
        LogManager.shared.info(
            "录音已启动 | 会话ID: \(sessionID), 音源: \(currentAudioSource.displayName), 输入设备: \(deviceSelection), 格式: \(fileURL.pathExtension.uppercased())"
        )
    }

    /// 检查录音 tap 是否还在持续产出帧。
    /// 返回 true 表示已触发中断处理，调用方应停止后续计时器逻辑。
    func checkAudioCaptureProgress(currentTime: TimeInterval) -> Bool {
        guard recordingState == .recording else {
            return false
        }

        let framesWritten = framesCounter.withLock { $0 }
        if framesWritten > lastObservedFrameCount {
            lastObservedFrameCount = framesWritten
            audioStallBeganAt = nil
            return false
        }

        guard recordingDuration >= audioStallGracePeriod else {
            return false
        }

        if audioStallBeganAt == nil {
            audioStallBeganAt = currentTime
            LogManager.shared.warning(
                "录音采集暂无新增帧，开始观察 | 已写入帧数: \(framesWritten)")
            return false
        }

        guard let stallBeganAt = audioStallBeganAt,
            currentTime - stallBeganAt >= audioStallTimeout
        else {
            return false
        }

        LogManager.shared.error(
            "录音采集疑似卡死 | \(String(format: "%.1f", audioStallTimeout))s 内无新增音频帧, 已写入帧数: \(framesWritten)")
        handleRecordingInterruption(reason: .engineConfigurationChanged)
        return true
    }

    // MARK: - 音频引擎预备（确保干净状态）
    /// 在每次新录音开始前调用，确保音频引擎处于干净状态
    /// 这对于从之前失败的录音恢复非常重要
    func prepareAudioEngineForNewRecording(preserveSystemAudioCapture: Bool = false) {
        setAcceptingAudioBuffers(false)
        if !preserveSystemAudioCapture {
            invalidateSystemAudioCaptureGeneration()
        }

        let usedIndependentMicrophoneCapture = microphoneSourceNode != nil
        stopIndependentMicrophoneCapture()

        // 1. 停止引擎（如果正在运行）
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        // 2. 移除所有可能存在的 tap
        if !usedIndependentMicrophoneCapture {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
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
        if let sourceNode = microphoneSourceNode {
            audioEngine.detach(sourceNode)
            microphoneSourceNode = nil
        }
        if let mixer = mixerNode {
            audioEngine.detach(mixer)
            mixerNode = nil
        }

        // 4. 【关键修复】创建全新的 AVAudioEngine 实例
        // 这可以彻底解决设备切换后 inputNode 状态不稳定导致的崩溃问题
        audioEngine = AVAudioEngine()
        setupEngineConfigurationChangeListener()

        // 5. 清空系统音频缓冲队列
        systemAudioQueueLock.lock()
        systemAudioBufferQueue.removeAll()
        systemAudioBufferHeadIndex = 0
        systemAudioBufferReadOffset = 0
        systemAudioQueueLock.unlock()

        // 6. 清理音频转换器缓存
        resetSystemAudioConverterCacheSynchronously()

        LogManager.shared.debug("音频引擎已重建，准备开始新录音")
    }

    // MARK: - 仅麦克风录音配置
    func setupMicrophoneOnlyRecording() throws {
        if shouldUseIndependentMicrophoneCapture() {
            setupRecordingMixer()
            try setupIndependentMicrophoneCapture(toBus: 0)
            installRecordingTap()
            return
        }

        // 1. 设置硬件输入设备（如果选择了特定设备）
        try updateInputDevice()

        // 2. 获取输入节点的输出格式。对 2 声道 USB/蓝牙麦克风，后续交给 mixer 转为统一录制格式。
        let inputNode = audioEngine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            throw NSError(
                domain: "AudioRecorder", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "当前麦克风输出格式不可用"])
        }
        LogManager.shared.info(
            "麦克风录音输入格式 | 采样率: \(micFormat.sampleRate)Hz, 声道: \(micFormat.channelCount)ch")
        captureRecordingStartupInputConfiguration(micFormat)

        // 3. 纯麦克风也走 mixer，统一做重采样/声道折叠，避免 2 声道输入被直接 tap 成静音。
        setupRecordingMixer()
        audioEngine.connect(inputNode, to: recordingMixer, fromBus: 0, toBus: 0, format: micFormat)
        inputNode.volume = 1.0
        installRecordingTap()
    }

    // MARK: - 蓝牙输出下的独立麦克风采集

    func setupIndependentMicrophoneCapture(toBus bus: AVAudioNodeBus) throws {
        try updateInputDevice(changeSystemDefault: false)

        guard let targetID = activeInputDeviceID,
            targetID != "default"
        else {
            throw NSError(
                domain: "AudioRecorder", code: -20,
                userInfo: [NSLocalizedDescriptionKey: "无法解析要录制的麦克风"])
        }

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )
        guard let device = discoverySession.devices.first(where: { $0.uniqueID == targetID }) else {
            throw NSError(
                domain: "AudioRecorder", code: -21,
                userInfo: [NSLocalizedDescriptionKey: "所选麦克风当前不可用"])
        }

        stopIndependentMicrophoneCapture()
        clearMicrophoneAudioState()

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: recordingFormat.sampleRate,
            AVNumberOfChannelsKey: recordingFormat.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
        ]

        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw NSError(
                domain: "AudioRecorder", code: -22,
                userInfo: [NSLocalizedDescriptionKey: "无法建立所选麦克风的独立采集链路"])
        }

        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        let generation = microphoneCaptureGeneration.withLock { value in
            value += 1
            return value
        }
        let streamOutput = MicrophoneAudioStreamOutput { [weak self] sampleBuffer in
            self?.handleMicrophoneSampleBuffer(sampleBuffer, captureGeneration: generation)
        }
        output.setSampleBufferDelegate(streamOutput, queue: microphoneSampleQueue)

        microphoneCaptureSession = session
        microphoneCaptureInput = input
        microphoneCaptureOutput = output
        microphoneStreamOutput = streamOutput

        microphoneSessionQueue.sync {
            session.startRunning()
        }
        guard session.isRunning else {
            stopIndependentMicrophoneCapture()
            throw NSError(
                domain: "AudioRecorder", code: -23,
                userInfo: [NSLocalizedDescriptionKey: "所选麦克风未能开始采集"])
        }

        let sourceNode = AVAudioSourceNode(format: recordingFormat) {
            [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            return self.fillMicrophoneAudioBuffer(audioBufferList, frameCount: frameCount)
        }
        microphoneSourceNode = sourceNode
        audioEngine.attach(sourceNode)
        audioEngine.connect(
            sourceNode, to: recordingMixer, fromBus: 0, toBus: bus, format: recordingFormat)
        sourceNode.volume = 1.0

        captureRecordingStartupInputConfiguration(recordingFormat)
        LogManager.shared.info(
            "已启用与蓝牙输出解耦的麦克风采集 | 名称: \(device.localizedName), ID: \(targetID)")
    }

    func stopIndependentMicrophoneCapture() {
        microphoneCaptureGeneration.withLock { $0 += 1 }

        let output = microphoneCaptureOutput
        output?.setSampleBufferDelegate(nil, queue: nil)

        if let session = microphoneCaptureSession {
            microphoneSessionQueue.sync {
                if session.isRunning {
                    session.stopRunning()
                }
            }
        }

        microphoneCaptureSession = nil
        microphoneCaptureInput = nil
        microphoneCaptureOutput = nil
        microphoneStreamOutput = nil
        clearMicrophoneAudioState()
    }

    func handleMicrophoneSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        captureGeneration: Int
    ) {
        guard microphoneCaptureGeneration.withLock({ $0 == captureGeneration }),
            !isPaused,
            CMSampleBufferIsValid(sampleBuffer),
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription),
            let sourceFormat = AVAudioFormat(streamDescription: streamDescription)
        else { return }

        let sourceFrameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard sourceFrameCount > 0,
            let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat, frameCapacity: sourceFrameCount)
        else { return }
        sourceBuffer.frameLength = sourceFrameCount

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sourceFrameCount),
            into: sourceBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return }

        let finalBuffer: AVAudioPCMBuffer
        if sourceFormat.isEqual(recordingFormat) {
            finalBuffer = sourceBuffer
        } else {
            let converter: AVAudioConverter
            if let cached = cachedMicrophoneAudioConverter,
                let previousSource = lastMicrophoneSourceFormat,
                let previousDestination = lastMicrophoneDestinationFormat,
                previousSource.isEqual(sourceFormat),
                previousDestination.isEqual(recordingFormat)
            {
                converter = cached
            } else {
                guard let newConverter = AVAudioConverter(
                    from: sourceFormat, to: recordingFormat)
                else { return }
                cachedMicrophoneAudioConverter = newConverter
                lastMicrophoneSourceFormat = sourceFormat
                lastMicrophoneDestinationFormat = recordingFormat
                converter = newConverter
            }

            let ratio = recordingFormat.sampleRate / sourceFormat.sampleRate
            let destinationCapacity = AVAudioFrameCount(
                ceil(Double(sourceFrameCount) * ratio) + 32)
            guard let destinationBuffer = AVAudioPCMBuffer(
                pcmFormat: recordingFormat,
                frameCapacity: max(destinationCapacity, 1))
            else { return }

            var conversionError: NSError?
            var suppliedInput = false
            let conversionStatus = converter.convert(
                to: destinationBuffer,
                error: &conversionError
            ) { _, inputStatus in
                if suppliedInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return sourceBuffer
            }
            guard conversionStatus != .error,
                conversionError == nil,
                destinationBuffer.frameLength > 0
            else { return }
            finalBuffer = destinationBuffer
        }

        capturedMicrophoneFrameCount.withLock {
            $0 += Int64(finalBuffer.frameLength)
        }
        enqueueMicrophoneAudioBuffer(finalBuffer)
    }

    func enqueueMicrophoneAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        microphoneAudioQueueLock.lock()
        microphoneAudioBufferQueue.append(buffer)
        let overflow = microphoneAudioBufferQueue.count - microphoneAudioBufferHeadIndex
            - microphoneAudioQueueLimit
        if overflow > 0 {
            microphoneAudioBufferHeadIndex += overflow
            microphoneAudioBufferReadOffset = 0
        }
        if microphoneAudioBufferHeadIndex > 128,
            microphoneAudioBufferHeadIndex * 2 >= microphoneAudioBufferQueue.count
        {
            microphoneAudioBufferQueue.removeFirst(microphoneAudioBufferHeadIndex)
            microphoneAudioBufferHeadIndex = 0
        }
        microphoneAudioQueueLock.unlock()
    }

    func fillMicrophoneAudioBuffer(
        _ audioBufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount
    ) -> OSStatus {
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for buffer in destinationBuffers {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }

        guard microphoneAudioQueueLock.try() else { return noErr }
        defer { microphoneAudioQueueLock.unlock() }

        var framesCopied: AVAudioFrameCount = 0
        let sampleSize = MemoryLayout<Float>.size
        while framesCopied < frameCount,
            microphoneAudioBufferHeadIndex < microphoneAudioBufferQueue.count
        {
            let sourceBuffer = microphoneAudioBufferQueue[microphoneAudioBufferHeadIndex]
            let framesAvailable = sourceBuffer.frameLength - microphoneAudioBufferReadOffset
            let framesToCopy = min(frameCount - framesCopied, framesAvailable)
            let sourceBuffers = UnsafeMutableAudioBufferListPointer(
                sourceBuffer.mutableAudioBufferList)

            for index in 0..<min(destinationBuffers.count, sourceBuffers.count) {
                guard let sourceData = sourceBuffers[index].mData,
                    let destinationData = destinationBuffers[index].mData
                else { continue }
                memcpy(
                    destinationData.advanced(by: Int(framesCopied) * sampleSize),
                    sourceData.advanced(by: Int(microphoneAudioBufferReadOffset) * sampleSize),
                    Int(framesToCopy) * sampleSize
                )
            }

            framesCopied += framesToCopy
            microphoneAudioBufferReadOffset += framesToCopy
            if microphoneAudioBufferReadOffset >= sourceBuffer.frameLength {
                microphoneAudioBufferHeadIndex += 1
                microphoneAudioBufferReadOffset = 0
            }
        }
        return noErr
    }

    func clearMicrophoneAudioState() {
        performOnMicrophoneSampleQueueSynchronously {
            microphoneAudioQueueLock.lock()
            microphoneAudioBufferQueue.removeAll()
            microphoneAudioBufferHeadIndex = 0
            microphoneAudioBufferReadOffset = 0
            cachedMicrophoneAudioConverter?.reset()
            cachedMicrophoneAudioConverter = nil
            lastMicrophoneSourceFormat = nil
            lastMicrophoneDestinationFormat = nil
            microphoneAudioQueueLock.unlock()
        }
    }

    private func performOnMicrophoneSampleQueueSynchronously(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: microphoneSampleQueueKey) == true {
            work()
        } else {
            microphoneSampleQueue.sync(execute: work)
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
            guard let self = self else { return }

            if self.isStarting {
                if buffer.frameLength > 0 {
                    self.startupObservedFrameCount.withLock {
                        $0 += Int64(buffer.frameLength)
                    }
                }
                return
            }

            guard self.isRecording else { return }

            // 原子地读取当前帧计数并递增，确保 PTS 绝对准确且无数据竞争
            let pts = self.framesCounter.withLock { frames -> CMTime in
                let current = frames
                frames += Int64(buffer.frameLength)
                return CMTime(value: current, timescale: Int32(format.sampleRate))
            }

            if buffer.frameLength > 0 {
                self.incrementTotalFrameCount()
                self.processAudioBufferWithPTS(buffer, pts: pts)
            }
        }
    }

    // MARK: - 音频采集资源清理
    func cleanupAudioCapture() {
        LogManager.shared.debug("开始清理音频采集资源...")
        setAcceptingAudioBuffers(false)
        invalidateSystemAudioCaptureGeneration()

        let usedIndependentMicrophoneCapture = microphoneSourceNode != nil
        stopIndependentMicrophoneCapture()

        // 1. 停止并移除 tap (必须首先执行)
        if !usedIndependentMicrophoneCapture {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
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
        microphoneSourceNode = nil
        self.recordingMixer = nil
        mixerNode = nil
        resetSystemAudioConverterCacheSynchronously()

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
        if sleepAssertionID == 0 {
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

        setupDisplaySleepPreventionForSystemAudio()
    }

    /// 录制系统音频时阻止显示器睡眠，避免 ScreenCaptureKit 捕获对象失效导致录音中断
    func setupDisplaySleepPreventionForSystemAudio() {
        guard currentAudioSource == .systemAudio || currentAudioSource == .both else { return }
        guard displaySleepAssertionID == 0 else { return }

        let reason = "正在录制系统音频，保持显示器唤醒以避免系统音频采集中断。" as CFString
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            "MeetingRecorderProSystemAudioDisplay" as CFString,
            reason,
            nil,
            nil,
            0,
            nil,
            &displaySleepAssertionID
        )

        if result == kIOReturnSuccess {
            LogManager.shared.info("已开启系统音频防显示器睡眠断言 | AssertionID: \(displaySleepAssertionID)")
        } else {
            LogManager.shared.warning("开启系统音频防显示器睡眠断言失败 | 错误码: \(result)")
        }
    }

    /// 释放防止休眠断言
    func releaseSleepPrevention() {
        if sleepAssertionID != 0 {
            let result = IOPMAssertionRelease(sleepAssertionID)
            if result == kIOReturnSuccess {
                LogManager.shared.info("已释放录音防休眠断言")
                sleepAssertionID = 0
            } else {
                LogManager.shared.warning("释放防休眠断言失败 | 错误码: \(result)")
            }
        }

        releaseDisplaySleepPrevention()
    }

    /// 释放系统音频防显示器睡眠断言
    func releaseDisplaySleepPrevention() {
        guard displaySleepAssertionID != 0 else { return }

        let result = IOPMAssertionRelease(displaySleepAssertionID)
        if result == kIOReturnSuccess {
            LogManager.shared.info("已释放系统音频防显示器睡眠断言")
            displaySleepAssertionID = 0
        } else {
            LogManager.shared.warning("释放系统音频防显示器睡眠断言失败 | 错误码: \(result)")
        }
    }
}

final class MicrophoneAudioStreamOutput: NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate
{
    private let onSampleBuffer: (CMSampleBuffer) -> Void

    init(onSampleBuffer: @escaping (CMSampleBuffer) -> Void) {
        self.onSampleBuffer = onSampleBuffer
        super.init()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        onSampleBuffer(sampleBuffer)
    }
}
