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

extension AudioRecorderManager {

    // MARK: - 核心写入逻辑（带 PTS 时间戳）
    func processAudioBufferWithPTS(_ buffer: AVAudioPCMBuffer, pts: CMTime) {
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
                // 写入繁忙：短暂等待后重试一次，而不是直接丢弃
                usleep(2000)  // 2ms，远小于 43ms 的 buffer 间隔
                if currentInput.isReadyForMoreMediaData {
                    if let sampleBuffer = self.createSampleBuffer(from: bufferCopy, pts: pts) {
                        if !currentInput.append(sampleBuffer) {
                            LogManager.shared.error("追加采样数据失败（重试后）")
                        }
                    }
                } else {
                    // 重试后仍写不进去，记录并丢弃
                    self.droppedFrameCount += 1
                    LogManager.shared.warning("写入队列繁忙，丢弃采样 | 累计丢帧: \(self.droppedFrameCount)")
                }
            }
        }
    }

    func processAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        // 已废弃，由 processAudioBufferWithPTS 替代
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

        // 3. 时间: 24小时制 HH.mm
        dateFormatter.dateFormat = "HH.mm"
        let timePart = dateFormatter.string(from: now)

        // 双空格分隔，格式：2026.01.14  Mon  18.59 - ing.m4a
        return "\(datePart)  \(weekPart)  \(timePart) - ing.m4a"
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

    // MARK: - M4A 转 MP3（优先使用内嵌 LAME 分块转码）
    func convertToMP3(from sourceURL: URL, completion: @escaping (URL?) -> Void) {
        let mp3URL = sourceURL.deletingPathExtension().appendingPathExtension("mp3")

        LogManager.shared.info("开始转换 MP3 | 源文件: \(sourceURL.lastPathComponent)")

        DispatchQueue.global(qos: .userInitiated).async {
            let success = MP3Encoder.convertToMP3(from: sourceURL, to: mp3URL)

            if success {
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
