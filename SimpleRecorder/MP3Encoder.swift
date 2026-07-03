//
//  MP3Encoder.swift
//  会议录音 Pro
//
//  可选 MP3 输出统一入口。仅在运行时确认编码器可用时启用，默认公开版仍以 M4A 为稳定输出格式。
//

import Foundation

enum MP3Encoder {
    static var isEncodingAvailable: Bool {
        NativeMP3Encoder.isEncodingAvailable
    }

    static var backendName: String {
        NativeMP3Encoder.isEncodingAvailable ? "Native" : "Unavailable"
    }

    static func convertToMP3(from sourceURL: URL, to destinationURL: URL, bitrate: Int32 = 128) -> Bool {
        guard NativeMP3Encoder.isEncodingAvailable else {
            LogManager.shared.warning("MP3Encoder: 当前系统原生 MP3 编码不可用")
            return false
        }

        return NativeMP3Encoder.convertToMP3(from: sourceURL, to: destinationURL, bitrate: bitrate)
    }
}
