//
//  LameEncoder.swift
//  极简录音 - LAME MP3 编码器封装
//

import Foundation
import AVFoundation
import lame

/// LAME MP3 编码器 Swift 封装
/// 使用静态链接的 libmp3lame 库将 WAV/PCM 音频转换为 MP3
class LameEncoder {
    
    /// 将 M4A/AAC 文件转换为 MP3
    /// - Parameters:
    ///   - sourceURL: 源音频文件路径 (M4A/AAC)
    ///   - destinationURL: 目标 MP3 文件路径
    ///   - bitrate: 码率 (kbps)，默认 128
    /// - Returns: 是否转换成功
    static func convertToMP3(from sourceURL: URL, to destinationURL: URL, bitrate: Int32 = 128) -> Bool {
        // 步骤 1：使用 AVAudioFile 读取源文件
        guard let audioFile = try? AVAudioFile(forReading: sourceURL) else {
            print("❌ LameEncoder: 无法打开源文件")
            return false
        }
        
        let format = audioFile.processingFormat
        let sampleRate = Int32(format.sampleRate)
        let channels = format.channelCount
        
        print("🎵 LameEncoder: 源格式 - \(sampleRate)Hz, \(channels)ch")
        
        // 步骤 2：初始化 LAME 编码器
        guard let lame = lame_init() else {
            print("❌ LameEncoder: lame_init 失败")
            return false
        }
        
        defer {
            lame_close(lame)
        }
        
        // 配置 LAME
        lame_set_in_samplerate(lame, sampleRate)
        lame_set_num_channels(lame, Int32(channels))
        lame_set_brate(lame, bitrate)
        lame_set_quality(lame, 5)  // 2=高质量慢速, 5=平衡, 7=快速
        lame_set_mode(lame, channels == 1 ? MONO : STEREO)
        
        if lame_init_params(lame) < 0 {
            print("❌ LameEncoder: lame_init_params 失败")
            return false
        }
        
        // 步骤 3：读取音频数据并编码
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            print("❌ LameEncoder: 无法创建 PCM Buffer")
            return false
        }
        
        do {
            try audioFile.read(into: buffer)
        } catch {
            print("❌ LameEncoder: 读取音频数据失败 - \(error.localizedDescription)")
            return false
        }
        
        // 获取 PCM 数据
        guard let floatData = buffer.floatChannelData else {
            print("❌ LameEncoder: 无法获取 float 数据")
            return false
        }
        
        let numSamples = Int(buffer.frameLength)
        
        // 分配 MP3 输出缓冲区 (1.25 * numSamples + 7200 是推荐的最小大小)
        let mp3BufferSize = Int(1.25 * Double(numSamples)) + 7200
        var mp3Buffer = [UInt8](repeating: 0, count: mp3BufferSize)
        
        var mp3Size: Int32 = 0
        
        if channels == 1 {
            // 单声道：需要将 Float 转换为 short
            var pcmBuffer = [Int16](repeating: 0, count: numSamples)
            for i in 0..<numSamples {
                let sample = floatData[0][i]
                pcmBuffer[i] = Int16(max(-32768, min(32767, sample * 32767)))
            }
            
            mp3Size = lame_encode_buffer(
                lame,
                pcmBuffer,
                nil,
                Int32(numSamples),
                &mp3Buffer,
                Int32(mp3BufferSize)
            )
        } else {
            // 立体声
            var leftBuffer = [Int16](repeating: 0, count: numSamples)
            var rightBuffer = [Int16](repeating: 0, count: numSamples)
            
            for i in 0..<numSamples {
                leftBuffer[i] = Int16(max(-32768, min(32767, floatData[0][i] * 32767)))
                rightBuffer[i] = Int16(max(-32768, min(32767, floatData[1][i] * 32767)))
            }
            
            mp3Size = lame_encode_buffer(
                lame,
                leftBuffer,
                rightBuffer,
                Int32(numSamples),
                &mp3Buffer,
                Int32(mp3BufferSize)
            )
        }
        
        if mp3Size < 0 {
            print("❌ LameEncoder: 编码失败，错误码: \(mp3Size)")
            return false
        }
        
        // 刷新编码器获取剩余数据
        let flushSize = lame_encode_flush(lame, &mp3Buffer[Int(mp3Size)], Int32(mp3BufferSize - Int(mp3Size)))
        if flushSize > 0 {
            mp3Size += flushSize
        }
        
        // 步骤 4：写入 MP3 文件
        let mp3Data = Data(bytes: mp3Buffer, count: Int(mp3Size))
        
        do {
            try mp3Data.write(to: destinationURL)
            print("✅ LameEncoder: MP3 转换成功，大小: \(mp3Data.count / 1024) KB")
            return true
        } catch {
            print("❌ LameEncoder: 写入文件失败 - \(error.localizedDescription)")
            return false
        }
    }
}
