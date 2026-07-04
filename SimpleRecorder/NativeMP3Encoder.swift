//
//  NativeMP3Encoder.swift
//  会议录音 Pro - 原生 MP3 编码器
//
//  使用 macOS 原生 AudioToolbox 实现流式分块 M4A->MP3 转换
//  每次处理 8192 帧，峰值内存 <50MB，无第三方依赖
//

import AVFoundation

class NativeMP3Encoder {
    static let isEncodingAvailable: Bool = {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecorderProMP3Probe-\(UUID().uuidString)", isDirectory: true)
        let outputURL = tempDirectory.appendingPathComponent("probe.mp3")

        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDirectory) }

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEGLayer3,
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128000,
            ]

            _ = try AVAudioFile(forWriting: outputURL, settings: settings)
            return true
        } catch {
            LogManager.shared.warning("NativeMP3Encoder: 系统原生 MP3 编码不可用 - \(error.localizedDescription)")
            return false
        }
    }()

    /// 流式将 M4A/AAC 文件转换为 MP3
    /// - Parameters:
    ///   - sourceURL: 源音频文件路径（M4A/AAC）
    ///   - destinationURL: 目标 MP3 文件路径
    ///   - bitrate: 码率（kbps），默认 128
    /// - Returns: 是否转换成功
    static func convertToMP3(from sourceURL: URL, to destinationURL: URL, bitrate: Int32 = 128) -> Bool {
        guard isEncodingAvailable else {
            LogManager.shared.warning("NativeMP3Encoder: 当前系统不支持原生 MP3 编码，跳过转换")
            return false
        }

        // 步骤 1：打开源文件
        guard let sourceFile = try? AVAudioFile(forReading: sourceURL) else {
            LogManager.shared.error("NativeMP3Encoder: 无法打开源文件 \(sourceURL.lastPathComponent)")
            return false
        }

        let srcFormat = sourceFile.processingFormat
        let channels = max(1, min(2, srcFormat.channelCount))

        // 步骤 2：配置 MP3 输出格式
        let mp3Settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEGLayer3,
            AVSampleRateKey: srcFormat.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: Int(bitrate) * 1000,
        ]

        // 步骤 3：创建目标文件（若 macOS 不支持 MP3 编码器则返回 false）
        guard let destFile = try? AVAudioFile(forWriting: destinationURL, settings: mp3Settings) else {
            LogManager.shared.error("NativeMP3Encoder: 无法创建目标 MP3 文件（系统可能不支持此编码器）")
            return false
        }

        // 步骤 4：分块流式读取并写入（每块 8192 帧 ≈ 170ms @48kHz）
        let chunkSize: AVAudioFrameCount = 8192
        let totalFrames = sourceFile.length
        var processed: AVAudioFramePosition = 0

        while processed < totalFrames {
            let toRead = min(AVAudioFrameCount(totalFrames - processed), chunkSize)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: toRead) else {
                LogManager.shared.error("NativeMP3Encoder: 无法分配 PCM Buffer")
                return false
            }

            do {
                try sourceFile.read(into: buffer, frameCount: toRead)
            } catch {
                LogManager.shared.error("NativeMP3Encoder: 读取失败 - \(error.localizedDescription)")
                return false
            }

            guard buffer.frameLength > 0 else { break }

            do {
                try destFile.write(from: buffer)
            } catch {
                LogManager.shared.error("NativeMP3Encoder: 写入失败 - \(error.localizedDescription)")
                return false
            }

            processed += AVAudioFramePosition(buffer.frameLength)
        }

        guard processed > 0 else {
            LogManager.shared.error("NativeMP3Encoder: 源文件没有可编码的 PCM 数据")
            return false
        }

        LogManager.shared.info("NativeMP3Encoder: 转换完成 | 处理帧数: \(processed)")
        return true
    }
}
