//
//  Recording.swift
//  极简录音 - 录音模型
//

import Foundation

struct Recording: Identifiable, Equatable {
    let id: String
    let url: URL
    let fileName: String
    let createdAt: Date
    let duration: TimeInterval?
    let fileSize: Int64
    
    init(url: URL) {
        self.id = url.path
        self.url = url
        self.fileName = url.lastPathComponent
        
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        self.createdAt = attributes?[.creationDate] as? Date ?? Date()
        self.fileSize = attributes?[.size] as? Int64 ?? 0
        
        // 获取音频时长
        self.duration = Recording.getAudioDuration(url: url)
    }
    
    // MARK: - Audio Duration
    static func getAudioDuration(url: URL) -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        // 使用同步方式获取时长（macOS 13+ 推荐使用 async load，但这里为了简单起见使用旧方法）
        if #available(macOS 13.0, *) {
            // 同步获取时长
            var duration: CMTime = .zero
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                do {
                    duration = try await asset.load(.duration)
                } catch {
                    duration = .zero
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 1)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isNaN || seconds <= 0 ? nil : seconds
        } else {
            let duration = CMTimeGetSeconds(asset.duration)
            return duration.isNaN ? nil : duration
        }
    }
    
    // MARK: - Formatted Properties
    var formattedDuration: String {
        guard let duration = duration else { return "--:--" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: createdAt)
    }
    
    var formattedFileSize: String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useMB, .useKB]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: fileSize)
    }
    
    // MARK: - Transcription Status
    var transcriptionFileName: String {
        // 支持多种音频格式：移除扩展名后加 .md
        let name = (fileName as NSString).deletingPathExtension
        return name + ".md"
    }
}

import AVFoundation
