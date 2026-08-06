//
//  AudioRecorderManagerWriter.swift
//  会议录音 Pro - 音频写入与文件管理
//
//  职责范围：
//  - 音频 Buffer 池化（避免高频内存分配）
//  - PTS 时间戳管理 + AVAssetWriter 写入
//  - CMSampleBuffer 构造
//  - 录音文件命名规则（启动时初始名 / 结束时最终名）
//  - M4A → MP3 转换
//  - AVAudioPCMBuffer 深拷贝扩展
//

import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

enum RecordingValidationError: LocalizedError {
    case missingOrEmptyFile
    case notPlayable
    case missingAudioTrack
    case invalidDuration

    var errorDescription: String? {
        switch self {
        case .missingOrEmptyFile:
            return "录音文件不存在或内容为空"
        case .notPlayable:
            return "录音文件无法播放"
        case .missingAudioTrack:
            return "录音文件不包含有效音轨"
        case .invalidDuration:
            return "录音文件时长无效"
        }
    }
}

/// AVFoundation 写入对象只在 `writingQueue` 串行访问。该载荷把非 Sendable 的
/// AVFoundation 引用封装在明确的队列边界内，避免把它们误传给其他并发执行器。
private final class QueuedAudioBufferWrite: @unchecked Sendable {
    weak var manager: AudioRecorderManager?
    let buffer: AVAudioPCMBuffer
    let pts: CMTime
    let writer: AVAssetWriter
    let input: AVAssetWriterInput

    init(
        manager: AudioRecorderManager,
        buffer: AVAudioPCMBuffer,
        pts: CMTime,
        writer: AVAssetWriter,
        input: AVAssetWriterInput
    ) {
        self.manager = manager
        self.buffer = buffer
        self.pts = pts
        self.writer = writer
        self.input = input
    }
}

extension AudioRecorderManager {

    // MARK: - 核心写入逻辑（带 PTS 时间戳）
    func processAudioBufferWithPTS(_ buffer: AVAudioPCMBuffer, pts: CMTime) {
        // acceptance lock 不只保护布尔值，还负责确定 enqueue 与 stop 的先后顺序：
        // - buffer 先拿到锁：必须在锁内排进 writingQueue，stop 随后才能排 finishWriting；
        // - stop 先拿到锁：关闭门禁后，后续 buffer 直接拒绝。
        // 这样不会出现“已通过门禁但尚未入队”的尾帧被 finishWriting 超车。
        let didEnqueue = audioBufferAcceptanceLock.withLock { accepting -> Bool in
            guard accepting else { return false }

            let bufferCopy: AVAudioPCMBuffer
            bufferPoolLock.lock()
            var pooledBuffer = audioBufferPool.popLast()

            // 如果格式不匹配或容量不足，直接丢弃池中过期的 buffer
            if let candidate = pooledBuffer,
                !candidate.format.isEqual(buffer.format)
                    || candidate.frameCapacity < buffer.frameLength
            {
                pooledBuffer = nil
            }

            if let pooledBuffer {
                let channels = min(
                    Int(buffer.format.channelCount),
                    Int(pooledBuffer.format.channelCount)
                )
                if let sourceChannels = buffer.floatChannelData,
                    let destinationChannels = pooledBuffer.floatChannelData
                {
                    for channel in 0..<channels {
                        let framesToCopy = min(buffer.frameLength, pooledBuffer.frameCapacity)
                        memcpy(
                            destinationChannels[channel],
                            sourceChannels[channel],
                            Int(framesToCopy) * MemoryLayout<Float>.size
                        )
                    }
                }
                pooledBuffer.frameLength = buffer.frameLength
                bufferCopy = pooledBuffer
                bufferPoolLock.unlock()
            } else {
                bufferPoolLock.unlock()
                guard let copiedBuffer = buffer.deepCopy() else { return false }
                bufferCopy = copiedBuffer
            }

            guard let enqueuedWriter = assetWriter, let enqueuedInput = assetWriterInput else {
                returnBufferToPool(bufferCopy)
                return false
            }

            let payload = QueuedAudioBufferWrite(
                manager: self,
                buffer: bufferCopy,
                pts: pts,
                writer: enqueuedWriter,
                input: enqueuedInput
            )
            writingQueue.async {
                guard let self = payload.manager else { return }

                defer {
                    self.returnBufferToPool(payload.buffer)
                }

                if !self.isWriterStarted {
                    payload.writer.startSession(atSourceTime: .zero)
                    self.isWriterStarted = true
                }

                guard payload.writer.status == .writing else {
                    self.incrementDroppedFrameCount()
                    return
                }

                if payload.input.isReadyForMoreMediaData {
                    if let sampleBuffer = self.createSampleBuffer(
                        from: payload.buffer,
                        pts: payload.pts
                    ), !payload.input.append(sampleBuffer)
                    {
                        LogManager.shared.error("追加采样数据失败")
                    }
                } else {
                    usleep(2000)
                    if payload.input.isReadyForMoreMediaData {
                        if let sampleBuffer = self.createSampleBuffer(
                            from: payload.buffer,
                            pts: payload.pts
                        ), !payload.input.append(sampleBuffer)
                        {
                            LogManager.shared.error("追加采样数据失败（重试后）")
                        }
                    } else {
                        let droppedFrames = self.incrementDroppedFrameCount()
                        LogManager.shared.warning(
                            "写入队列繁忙，丢弃采样 | 累计丢帧: \(droppedFrames)"
                        )
                    }
                }
            }
            return true
        }

        if !didEnqueue {
            incrementDroppedFrameCount()
        }
    }

    // MARK: - 写入完成验证与统一清理

    /// AVAssetWriter 的 `.completed` 只代表容器完成写入；清除崩溃恢复标记前，
    /// 还要确认文件存在、可播放、含音轨且时长有效。
    func validateFinalizedRecording(
        at url: URL,
        completion: @escaping (Result<TimeInterval, Error>) -> Void
    ) {
        Task { @MainActor in
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard let size = attributes[.size] as? NSNumber, size.int64Value > 0 else {
                    throw RecordingValidationError.missingOrEmptyFile
                }

                let asset = AVURLAsset(url: url)
                async let playable = asset.load(.isPlayable)
                async let duration = asset.load(.duration)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)

                guard try await playable else {
                    throw RecordingValidationError.notPlayable
                }
                guard !audioTracks.isEmpty else {
                    throw RecordingValidationError.missingAudioTrack
                }

                let seconds = CMTimeGetSeconds(try await duration)
                guard seconds.isFinite, seconds > 0 else {
                    throw RecordingValidationError.invalidDuration
                }

                completion(.success(seconds))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func completeSuccessfulWriterCleanup(
        writer: AVAssetWriter,
        input: AVAssetWriterInput?
    ) {
        if assetWriter === writer { assetWriter = nil }
        if assetWriterInput === input { assetWriterInput = nil }
        isWriterStarted = false
        currentRecordingURL = nil
        recordingDeviceID = nil
        recordingDeviceName = nil
        recordingInputSampleRate = nil
        recordingInputChannelCount = nil
        audioStallBeganAt = nil
        activeInputDeviceID = nil
        activeInputDeviceName = nil
        expectedDefaultInputDeviceID = nil
        resetRecordingStartupStabilityState()
        isHandlingInterruption = false
        engineConfigurationEvaluationWorkItem?.cancel()
        engineConfigurationEvaluationWorkItem = nil
        engineConfigurationEvaluationGeneration += 1
        engineConfigurationRecoveryAttempts = 0
        releaseSleepPrevention()
        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
    }

    func completeFailedWriterFinalization(
        writer: AVAssetWriter,
        input: AVAssetWriterInput?,
        message: String
    ) {
        if let path = currentRecordingURL?.path
            ?? UserDefaults.standard.string(forKey: recordingFilePathKey)
        {
            archiveFailedRecordingRecovery(path: path)
        }
        clearRecordingState()
        recordingState = .idle
        LogManager.shared.error("录音文件固化验证失败 | 错误: \(message)")
        LogManager.shared.endRecordingSession()
        completeSuccessfulWriterCleanup(writer: writer, input: input)
        showRecordingSaveFailedAlert(
            message: "录音文件未能确认完整，独立恢复记录和现有文件已保留。\n\n原因：\(message)")
    }

    // 将使用完的 Buffer 归还给池以便重用
    func returnBufferToPool(_ buffer: AVAudioPCMBuffer) {
        bufferPoolLock.lock()
        if audioBufferPool.count < bufferPoolLimit {
            audioBufferPool.append(buffer)
        }
        bufferPoolLock.unlock()
    }

    func createSampleBuffer(from buffer: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer? {
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

    // MARK: - 命名格式化
    func generateInitialFileName() -> String {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        // 1. 日期: YYYY.MM.DD
        dateFormatter.dateFormat = "yyyy.MM.dd"
        let datePart = dateFormatter.string(from: now)

        // 2. 星期: 三字母缩写 (Mon/Tue...)
        dateFormatter.dateFormat = "E"
        let weekPart = dateFormatter.string(from: now)

        // 3. 时间: 24小时制 HH.mm.ss
        dateFormatter.dateFormat = "HH.mm.ss"
        let timePart = dateFormatter.string(from: now)
        let uniquePart = UUID().uuidString.prefix(8).lowercased()

        // 双空格分隔，格式：2026.01.14  Mon  18.59.12 - a1b2c3d4 - ing.m4a
        return "\(datePart)  \(weekPart)  \(timePart) - \(uniquePart) - ing.m4a"
    }

    func renameToFinalFormat(url: URL) -> URL {
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

        // 4. 时长: Xmin（使用实际录音时长，排除暂停时间）
        let totalSeconds = Int(recordingDuration > 0 ? recordingDuration : endDate.timeIntervalSince(startDate))
        let minutes = max(1, totalSeconds / 60)
        let durationPart = "\(minutes)min"

        // 基础文件名：2026.01.14  Mon  18.59 - 13min.m4a
        let baseFileName = "\(datePart)  \(weekPart)  \(startPart) - \(durationPart)"
        let directory = url.deletingLastPathComponent()
        let newURL = uniqueRecordingURL(
            in: directory,
            baseFileName: baseFileName,
            fileExtension: "m4a",
            conflictExtensions: ["m4a", "mp3"]
        )

        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            return newURL
        } catch {
            LogManager.shared.error("重命名失败: \(error.localizedDescription)")
            return url
        }
    }

    func uniqueRecordingURL(
        in directory: URL,
        baseFileName: String,
        fileExtension: String,
        conflictExtensions: [String]
    ) -> URL {
        var counter = 0

        while true {
            let suffix = counter == 0 ? "" : " (\(counter))"
            let fileName = "\(baseFileName)\(suffix)"
            let hasConflict = conflictExtensions.contains { ext in
                let candidate = directory.appendingPathComponent("\(fileName).\(ext)")
                return FileManager.default.fileExists(atPath: candidate.path)
            }

            if !hasConflict {
                return directory.appendingPathComponent("\(fileName).\(fileExtension)")
            }

            counter += 1
        }
    }

    // MARK: - M4A 转 MP3（使用 macOS 原生分块转码）
    func convertToMP3(from sourceURL: URL, completion: @escaping (URL?) -> Void) {
        let directory = sourceURL.deletingLastPathComponent()
        let baseFileName = sourceURL.deletingPathExtension().lastPathComponent
        let mp3URL = uniqueRecordingURL(
            in: directory,
            baseFileName: baseFileName,
            fileExtension: "mp3",
            conflictExtensions: ["mp3"]
        )

        LogManager.shared.info("开始转换 MP3 | 源文件: \(sourceURL.lastPathComponent)")

        DispatchQueue.global(qos: .userInitiated).async {
            let success = MP3Encoder.convertToMP3(from: sourceURL, to: mp3URL)

            guard success else {
                LogManager.shared.warning("MP3 转换失败，保留原 M4A 文件")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // 编码器返回成功后重新打开最终 MP3，复用录音收尾的完整媒体验证。
            // 只有文件存在、可播放、含音轨且时长有效时，才能删除源 M4A。
            self.validateFinalizedRecording(at: mp3URL) { result in
                switch result {
                case .success(let duration):
                    guard RecordingFinalizationPolicy.shouldRemoveSourceAfterMP3Finalization(
                        encoderSucceeded: success,
                        mediaValidationSucceeded: true,
                        finalFileExists: FileManager.default.fileExists(atPath: mp3URL.path)
                    ) else {
                        LogManager.shared.error(
                            "MP3 验证后文件不存在，保留原 M4A 文件 | 目标: \(mp3URL.lastPathComponent)"
                        )
                        completion(nil)
                        return
                    }

                    do {
                        try FileManager.default.removeItem(at: sourceURL)
                    } catch {
                        // MP3 已通过验证；删除源文件失败时保留两份，不误报转码失败。
                        LogManager.shared.warning(
                            "MP3 已验证，但原 M4A 删除失败，已保留两份 | 错误: \(error.localizedDescription)"
                        )
                    }

                    let fileSize =
                        ((try? FileManager.default.attributesOfItem(atPath: mp3URL.path)[.size])
                            as? NSNumber)?.int64Value ?? 0
                    let fileSizeMB = Double(fileSize) / (1024 * 1024)
                    LogManager.shared.info(
                        "MP3 转换完成并已验证 | 文件: \(mp3URL.lastPathComponent), 时长: \(String(format: "%.1f", duration))s, 大小: \(String(format: "%.2f", fileSizeMB))MB"
                    )
                    completion(mp3URL)

                case .failure(let error):
                    LogManager.shared.error(
                        "MP3 转换后完整性验证失败，保留原 M4A 文件 | 错误: \(error.localizedDescription)"
                    )
                    completion(nil)
                }
            }
        }
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
