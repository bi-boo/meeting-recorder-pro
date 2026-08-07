//
//  AudioRecorderManagerSystemAudio.swift
//  会议录音 Pro - 系统音频采集
//
//  职责范围：
//  - 仅系统音 / 麦克风+系统音混合 录音通路搭建
//  - SCStream 屏幕录制 API 启动与配置
//  - 系统音采样格式转换（CMSampleBuffer → AVAudioPCMBuffer）
//  - 弹性缓冲队列（对抗系统音和麦克风的时钟漂移）
//  - SCStream 错误回调处理
//

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

extension AudioRecorderManager {

    // MARK: - 仅系统音频录音配置
    @available(macOS 13.0, *)
    @MainActor
    func setupSystemAudioOnlyRecording(startupGeneration: Int) async throws {
        setupRecordingMixer()
        try await startSystemAudioCapture(startupGeneration: startupGeneration)

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

    // MARK: - 混合录音配置（麦克风 + 系统音频）
    @available(macOS 13.0, *)
    @MainActor
    func setupMixedRecording(
        startupGeneration: Int,
        reuseSystemAudioCapture: Bool = false
    ) async throws {
        // 1. AirPods 等蓝牙输出与外接麦克风并用时，使用独立采集链路，
        // 避免 AVAudioEngine 的隐式聚合设备返回静音帧。
        let useIndependentMicrophoneCapture = shouldUseIndependentMicrophoneCapture()
        if !useIndependentMicrophoneCapture {
            try updateInputDevice()
        }
        setupRecordingMixer()

        // 2. 混合录制：开启弹性缓冲以对齐异构时钟
        isSystemAudioBuffering = true

        // 3. 麦克风 -> Bus 0。麦克风保持 1.0，避免系统音存在时人声过轻。
        if useIndependentMicrophoneCapture {
            try setupIndependentMicrophoneCapture(toBus: 0)
        } else {
            let inputNode = audioEngine.inputNode
            let micFormat = inputNode.outputFormat(forBus: 0)
            guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
                throw NSError(
                    domain: "AudioRecorder", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "当前麦克风输出格式不可用"])
            }
            LogManager.shared.info(
                "混合录音麦克风输出格式 | 采样率: \(micFormat.sampleRate)Hz, 声道: \(micFormat.channelCount)ch")
            captureRecordingStartupInputConfiguration(micFormat)
            audioEngine.connect(
                inputNode, to: recordingMixer, fromBus: 0, toBus: 0, format: micFormat)
            inputNode.volume = 1.0
        }

        // 4. 启动系统音频采集。如果只是启动期重建 AVAudioEngine，
        // 复用已在运行的 SCStream，避免不必要的停止和二次授权。
        if reuseSystemAudioCapture {
            guard systemAudioStream != nil, systemAudioOutput != nil else {
                throw NSError(
                    domain: "AudioRecorder", code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "无法复用系统音频采集链路"])
            }
            LogManager.shared.info("启动期重建混音引擎，复用已运行的系统音频采集")
        } else {
            try await startSystemAudioCapture(startupGeneration: startupGeneration)
        }

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
            print("🎸 混合链路定向加固：Mic(v1.0), Sys(v0.7), 轻量弹性缓冲已开启")
        }

        installRecordingTap()
    }

    // MARK: - 系统音频采集启动
    @available(macOS 13.0, *)
    @MainActor
    func startSystemAudioCapture(startupGeneration: Int) async throws {
        guard recordingState == .starting,
            recordingStartupGeneration == startupGeneration
        else { throw CancellationError() }

        let captureGeneration = nextSystemAudioCaptureGeneration()
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
        // 正常录音排除自己的音频，避免回声。QA 模式下需要捕获 runner 播放的测试音。
        #if QA_AUTOMATION
            configuration.excludesCurrentProcessAudio = !QAAutomationRunner.isActive
        #else
            configuration.excludesCurrentProcessAudio = true
        #endif

        let output: SystemAudioStreamOutput
        let stream: SCStream

        // 使用 macOS 14.2+ 的仅音频采集方式
        if #available(macOS 14.2, *) {
            // macOS 14.2+ 支持 audio-only 权限
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: false)
            guard recordingState == .starting,
                recordingStartupGeneration == startupGeneration
            else { throw CancellationError() }

            guard let display = content.displays.first else {
                throw NSError(
                    domain: "AudioRecorder", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "无法获取显示器信息"])
            }

            // 排除当前应用程序（SimpleRecorder）的音频，避免回声；QA 模式需要捕获内置测试音。
            #if QA_AUTOMATION
                let excludedApplications = QAAutomationRunner.isActive
                    ? []
                    : content.applications.filter {
                        $0.bundleIdentifier == Bundle.main.bundleIdentifier
                    }
            #else
                let excludedApplications = content.applications.filter {
                    $0.bundleIdentifier == Bundle.main.bundleIdentifier
                }
            #endif

            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: [])

            output = SystemAudioStreamOutput { [weak self] sampleBuffer in
                self?.handleSystemAudioSampleBuffer(
                    sampleBuffer, captureGeneration: captureGeneration)
            }

            stream = SCStream(
                filter: filter, configuration: configuration, delegate: self)
        } else {
            // macOS 13.0-14.1 回退方案：需要使用 display filter
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            guard recordingState == .starting,
                recordingStartupGeneration == startupGeneration
            else { throw CancellationError() }

            guard let display = content.displays.first else {
                throw NSError(
                    domain: "AudioRecorder", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "无法获取显示器信息"])
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])

            output = SystemAudioStreamOutput { [weak self] sampleBuffer in
                self?.handleSystemAudioSampleBuffer(
                    sampleBuffer, captureGeneration: captureGeneration)
            }

            stream = SCStream(
                filter: filter, configuration: configuration, delegate: self)
        }

        try stream.addStreamOutput(
            output, type: .audio, sampleHandlerQueue: systemAudioSampleQueue)
        try await stream.startCapture()

        guard recordingState == .starting,
            recordingStartupGeneration == startupGeneration
        else {
            try? await stream.stopCapture()
            throw CancellationError()
        }

        // 所有 await 和代次校验完成后再发布到全局状态，防止已取消的旧 Task
        // 覆盖新会话的 stream/output。
        systemAudioOutput = output
        systemAudioStream = stream
        print("🔊 系统音频采集已启动")
    }

    // MARK: - 系统音频缓存重置

    func resetSystemAudioStateForResume() {
        performOnSystemAudioSampleQueueSynchronously {
            systemAudioQueueLock.lock()
            for buffer in systemAudioBufferQueue {
                returnBufferToPool(buffer)
            }
            systemAudioBufferQueue.removeAll()
            systemAudioBufferHeadIndex = 0
            systemAudioBufferReadOffset = 0
            isSystemAudioBuffering = (currentAudioSource == .both)
            cachedAudioConverter?.reset()
            cachedAudioConverter = nil
            lastSrcFormat = nil
            lastDstFormat = nil
            systemAudioQueueLock.unlock()
        }
    }

    func resetSystemAudioConverterCacheSynchronously() {
        performOnSystemAudioSampleQueueSynchronously {
            systemAudioQueueLock.lock()
            cachedAudioConverter?.reset()
            cachedAudioConverter = nil
            lastSrcFormat = nil
            lastDstFormat = nil
            systemAudioQueueLock.unlock()
        }
    }

    private func performOnSystemAudioSampleQueueSynchronously(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: systemAudioSampleQueueKey) == true {
            work()
        } else {
            systemAudioSampleQueue.sync(execute: work)
        }
    }

    func nextSystemAudioCaptureGeneration() -> Int {
        systemAudioQueueLock.lock()
        systemAudioCaptureGeneration += 1
        let generation = systemAudioCaptureGeneration
        systemAudioQueueLock.unlock()
        return generation
    }

    func invalidateSystemAudioCaptureGeneration() {
        systemAudioQueueLock.lock()
        systemAudioCaptureGeneration += 1
        systemAudioQueueLock.unlock()
    }

    func isCurrentSystemAudioGeneration(_ generation: Int) -> Bool {
        systemAudioQueueLock.lock()
        let isCurrent = generation == systemAudioCaptureGeneration
        systemAudioQueueLock.unlock()
        return isCurrent
    }

    // MARK: - 处理系统音频样本
    func handleSystemAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, captureGeneration: Int) {
        // 如果已暂停，直接丢弃数据
        guard isCurrentSystemAudioGeneration(captureGeneration), !isPaused else { return }

        guard CMSampleBufferIsValid(sampleBuffer),
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let srcFormat = AVAudioFormat(streamDescription: asbd) else { return }
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
            var hasProvided = false
            activeConverter.convert(to: finalBuffer, error: &error) { inNumPackets, outStatus in
                if hasProvided {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                hasProvided = true
                outStatus.pointee = .haveData
                return tempBuffer
            }

            if error == nil {
                self.enqueueSystemAudioBuffer(finalBuffer)
            }

        }
    }

    // MARK: - 弹性缓冲：填充系统音频帧到 SourceNode
    func fillSystemAudioBuffer(
        _ audioBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: AVAudioFrameCount
    ) -> OSStatus {
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)

        // 默认填充静音
        for i in 0..<ablPointer.count {
            if let data = ablPointer[i].mData {
                memset(data, 0, Int(ablPointer[i].mDataByteSize))
            }
        }

        guard systemAudioQueueLock.try() else {
            return noErr
        }
        defer { systemAudioQueueLock.unlock() }

        // 【弹性滞后缓冲逻辑】
        if isSystemAudioBuffering {
            // 水位只要达到轻量级指标（3个包）就恢复输出，减少等待感
            if activeSystemAudioBufferCount() < systemAudioPreRollHighWaterMark {
                return noErr
            } else {
                isSystemAudioBuffering = false
            }
        }

        // 队列耗尽时输出静音（已 memset 0），但不重新进入缓冲态
        // isSystemAudioBuffering = true 仅在首次启动和暂停恢复时设置，
        // 避免运行中因瞬时耗尽反复触发"缓冲→等 3 包→恢复"循环导致断续
        if activeSystemAudioBufferCount() == 0 {
            return noErr
        }

        var framesCopied: AVAudioFrameCount = 0
        let sampleSize = MemoryLayout<Float>.size

        while framesCopied < frameCount && systemAudioBufferHeadIndex < systemAudioBufferQueue.count {
            let buffer = systemAudioBufferQueue[systemAudioBufferHeadIndex]
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
                systemAudioBufferHeadIndex += 1
                systemAudioBufferReadOffset = 0
            }
        }

        return noErr
    }

    // MARK: - 缓冲队列入队/清空
    func enqueueSystemAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        var didDropOldBuffer = false

        systemAudioQueueLock.lock()
        compactSystemAudioBufferQueueIfNeeded()

        systemAudioBufferQueue.append(buffer)
        let overflow = activeSystemAudioBufferCount() - systemAudioQueueLimit
        if overflow > 0 {
            systemAudioBufferHeadIndex = min(
                systemAudioBufferQueue.count, systemAudioBufferHeadIndex + overflow)
            systemAudioBufferReadOffset = 0
            compactSystemAudioBufferQueueIfNeeded()
            didDropOldBuffer = true
        }
        systemAudioQueueLock.unlock()

        if didDropOldBuffer {
            LogManager.shared.warning("系统音频缓冲队列已满，丢弃旧数据 | 队列大小: \(systemAudioQueueLimit)")
        }
    }

    func clearSystemAudioBufferQueue() {
        systemAudioQueueLock.lock()
        systemAudioBufferQueue.removeAll()
        systemAudioBufferHeadIndex = 0
        systemAudioBufferReadOffset = 0
        systemAudioQueueLock.unlock()
    }

    func activeSystemAudioBufferCount() -> Int {
        max(0, systemAudioBufferQueue.count - systemAudioBufferHeadIndex)
    }

    func compactSystemAudioBufferQueueIfNeeded() {
        guard systemAudioBufferHeadIndex > 128,
            systemAudioBufferHeadIndex * 2 >= systemAudioBufferQueue.count
        else {
            return
        }

        systemAudioBufferQueue.removeFirst(systemAudioBufferHeadIndex)
        systemAudioBufferHeadIndex = 0
    }

}

// MARK: - SCStreamOutput 实现（系统音频采集回调）

@available(macOS 13.0, *)
class SystemAudioStreamOutput: NSObject, SCStreamOutput {
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

// MARK: - SCStreamDelegate 实现（系统音频采集错误处理）

@available(macOS 13.0, *)
extension AudioRecorderManager: SCStreamDelegate {
    /// 系统音频采集流发生错误时的回调
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // delegate 可能运行在 ScreenCaptureKit 内部队列；统一切主队列读取状态。
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                self.systemAudioStream === stream,
                (self.recordingState == .recording || self.recordingState == .paused),
                (self.currentAudioSource == .systemAudio || self.currentAudioSource == .both)
            else { return }

            LogManager.shared.error("系统音频采集流停止 | 错误: \(error.localizedDescription)")
            self.handleRecordingInterruption(reason: .systemAudioStreamError(error))
        }
    }
}
