//
//  MP3Encoder.swift
//  会议录音 Pro
//
//  MP3 输出统一入口。优先使用内嵌 LAME 分块转码，避免长录音一次性解码到内存。
//

import AVFoundation
import Foundation
import lame

enum MP3Encoder {
    static var isEncodingAvailable: Bool {
        LameMP3Encoder.isEncodingAvailable || NativeMP3Encoder.isEncodingAvailable
    }

    static var backendName: String {
        if LameMP3Encoder.isEncodingAvailable {
            return "LAME"
        }
        if NativeMP3Encoder.isEncodingAvailable {
            return "Native"
        }
        return "Unavailable"
    }

    static func convertToMP3(from sourceURL: URL, to destinationURL: URL, bitrate: Int32 = 128) -> Bool {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            LogManager.shared.error("MP3Encoder: 目标文件已存在，拒绝覆盖 \(destinationURL.lastPathComponent)")
            return false
        }

        let tempURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.deletingPathExtension().lastPathComponent).\(UUID().uuidString).tmp.mp3")
        defer { try? fileManager.removeItem(at: tempURL) }

        let encoded: Bool
        if LameMP3Encoder.isEncodingAvailable {
            let maxAttempts = 3
            encoded = (1...maxAttempts).contains { attempt in
                if LameMP3Encoder.convertToMP3(
                    from: sourceURL, to: tempURL, bitrate: bitrate)
                {
                    return true
                }

                if attempt < maxAttempts {
                    let delay = 0.35 * Double(attempt)
                    LogManager.shared.warning(
                        "MP3Encoder: LAME 转码失败，\(String(format: "%.2f", delay))s 后重试 | attempt=\(attempt)"
                    )
                    Thread.sleep(forTimeInterval: delay)
                }

                return false
            }
        } else {
            LogManager.shared.warning("MP3Encoder: LAME 不可用，尝试系统原生 MP3 编码")
            encoded = NativeMP3Encoder.convertToMP3(from: sourceURL, to: tempURL, bitrate: bitrate)
        }

        guard encoded else { return false }

        do {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
            return true
        } catch {
            LogManager.shared.error("MP3Encoder: 移动 MP3 临时文件失败 - \(error.localizedDescription)")
            return false
        }
    }
}

private enum LameMP3Encoder {
    static let isEncodingAvailable = true

    static func convertToMP3(from sourceURL: URL, to destinationURL: URL, bitrate: Int32 = 128) -> Bool {
        let asset = AVURLAsset(url: sourceURL)
        guard let audioTrack = audioTrack(from: asset) else {
            LogManager.shared.error("LameMP3Encoder: 源文件没有音频轨道 \(sourceURL.lastPathComponent)")
            return false
        }

        let streamInfo = audioStreamInfo(from: audioTrack)
        let outputChannels = max(1, min(2, streamInfo.channels))
        let sampleRate = Int32(streamInfo.sampleRate.rounded())
        guard sampleRate > 0, outputChannels > 0 else {
            LogManager.shared.error("LameMP3Encoder: 源文件声道数无效")
            return false
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: outputChannels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        guard let reader = try? AVAssetReader(asset: asset) else {
            LogManager.shared.error("LameMP3Encoder: 无法创建 AVAssetReader")
            return false
        }

        let readerOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: outputSettings
        )
        guard reader.canAdd(readerOutput) else {
            LogManager.shared.error("LameMP3Encoder: 无法添加音频解码输出")
            return false
        }
        reader.add(readerOutput)

        guard let lameHandle = lame_init() else {
            LogManager.shared.error("LameMP3Encoder: lame_init 失败")
            return false
        }
        defer { lame_close(lameHandle) }

        lame_set_in_samplerate(lameHandle, sampleRate)
        lame_set_num_channels(lameHandle, Int32(outputChannels))
        lame_set_brate(lameHandle, bitrate)
        lame_set_quality(lameHandle, 5)
        lame_set_mode(lameHandle, outputChannels == 1 ? MONO : STEREO)

        guard lame_init_params(lameHandle) >= 0 else {
            LogManager.shared.error("LameMP3Encoder: lame_init_params 失败")
            return false
        }

        try? FileManager.default.removeItem(at: destinationURL)
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil),
            let outputHandle = try? FileHandle(forWritingTo: destinationURL)
        else {
            LogManager.shared.error("LameMP3Encoder: 无法创建目标 MP3 文件")
            return false
        }

        var didComplete = false
        defer {
            try? outputHandle.close()
            if !didComplete {
                reader.cancelReading()
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        guard reader.startReading() else {
            LogManager.shared.error(
                "LameMP3Encoder: 解码启动失败 - \(reader.error?.localizedDescription ?? "未知错误")"
            )
            return false
        }

        var processedFrames = 0

        while reader.status == .reading {
            guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else { break }

            guard let samples = interleavedInt16Samples(from: sampleBuffer) else {
                return false
            }

            let frames = samples.count / outputChannels
            guard frames > 0 else { continue }
            var mp3Buffer = [UInt8](
                repeating: 0, count: Int(1.25 * Double(frames)) + 7200)

            var pcmSamples = samples
            let encodedBytes: Int32
            if outputChannels == 1 {
                encodedBytes = lame_encode_buffer(
                    lameHandle, &pcmSamples, nil, Int32(frames), &mp3Buffer,
                    Int32(mp3Buffer.count))
            } else {
                encodedBytes = lame_encode_buffer_interleaved(
                    lameHandle, &pcmSamples, Int32(frames), &mp3Buffer,
                    Int32(mp3Buffer.count))
            }

            guard encodedBytes >= 0 else {
                LogManager.shared.error("LameMP3Encoder: 编码失败，错误码: \(encodedBytes)")
                return false
            }

            if encodedBytes > 0 {
                outputHandle.write(Data(mp3Buffer.prefix(Int(encodedBytes))))
            }

            processedFrames += frames
        }

        guard reader.status == .completed else {
            LogManager.shared.error(
                "LameMP3Encoder: 解码失败 - \(reader.error?.localizedDescription ?? "状态: \(reader.status.rawValue)")"
            )
            return false
        }

        guard processedFrames > 0 else {
            LogManager.shared.error("LameMP3Encoder: 源文件没有可编码的 PCM 数据")
            return false
        }

        var flushBuffer = [UInt8](repeating: 0, count: 7200)
        let flushBytes = lame_encode_flush(lameHandle, &flushBuffer, Int32(flushBuffer.count))
        guard flushBytes >= 0 else {
            LogManager.shared.error("LameMP3Encoder: flush 失败，错误码: \(flushBytes)")
            return false
        }

        if flushBytes > 0 {
            outputHandle.write(Data(flushBuffer.prefix(Int(flushBytes))))
        }

        didComplete = true
        LogManager.shared.info(
            "LameMP3Encoder: 转换完成 | 处理帧数: \(processedFrames), 后端: \(MP3Encoder.backendName)"
        )
        return true
    }

    private static func audioStreamInfo(from track: AVAssetTrack) -> (
        sampleRate: Double, channels: Int
    ) {
        for audioDescription in audioFormatDescriptions(from: track) {
            guard
                let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                    audioDescription)
            else {
                continue
            }

            let asbd = streamDescription.pointee
            if asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 {
                return (asbd.mSampleRate, Int(asbd.mChannelsPerFrame))
            }
        }

        return (48_000, 1)
    }

    private static func audioTrack(from asset: AVURLAsset) -> AVAssetTrack? {
        let result = BlockingAsyncResultBox<[AVAssetTrack]>()
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            do {
                result.store(.success(try await asset.loadTracks(withMediaType: .audio)))
            } catch {
                result.store(.failure(error))
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 30) == .success else {
            LogManager.shared.error("LameMP3Encoder: 加载音频轨道超时")
            return nil
        }

        switch result.load() {
        case .success(let tracks):
            return tracks.first
        case .failure(let error):
            LogManager.shared.error("LameMP3Encoder: 加载音频轨道失败 - \(error.localizedDescription)")
            return nil
        case .none:
            LogManager.shared.error("LameMP3Encoder: 加载音频轨道失败")
            return nil
        }
    }

    private static func audioFormatDescriptions(from track: AVAssetTrack) -> [
        CMAudioFormatDescription
    ] {
        let result = BlockingAsyncResultBox<[CMFormatDescription]>()
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            do {
                result.store(.success(try await track.load(.formatDescriptions)))
            } catch {
                result.store(.failure(error))
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 30) == .success else {
            LogManager.shared.warning("LameMP3Encoder: 加载音频格式描述超时，使用默认 48kHz/mono")
            return []
        }

        switch result.load() {
        case .success(let descriptions):
            return descriptions
        case .failure(let error):
            LogManager.shared.warning(
                "LameMP3Encoder: 加载音频格式描述失败，使用默认 48kHz/mono - \(error.localizedDescription)"
            )
            return []
        case .none:
            LogManager.shared.warning("LameMP3Encoder: 加载音频格式描述失败，使用默认 48kHz/mono")
            return []
        }
    }

    private static func interleavedInt16Samples(from sampleBuffer: CMSampleBuffer) -> [Int16]? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            LogManager.shared.error("LameMP3Encoder: 解码输出缺少 PCM 数据块")
            return nil
        }

        let byteLength = CMBlockBufferGetDataLength(blockBuffer)
        guard byteLength > 0 else { return [] }
        guard byteLength % MemoryLayout<Int16>.size == 0 else {
            LogManager.shared.error("LameMP3Encoder: PCM 数据长度不合法")
            return nil
        }

        var data = Data(count: byteLength)
        let status = data.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let destination = rawBuffer.baseAddress else {
                return OSStatus(-1)
            }

            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: byteLength,
                destination: destination
            )
        }

        guard status == kCMBlockBufferNoErr else {
            LogManager.shared.error("LameMP3Encoder: PCM 数据复制失败，错误码: \(status)")
            return nil
        }

        return data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Int16.self))
        }
    }
}

private final class BlockingAsyncResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?

    func store(_ result: Result<T, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
