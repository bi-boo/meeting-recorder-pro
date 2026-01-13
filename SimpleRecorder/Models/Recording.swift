//
//  Recording.swift
//  极简录音 - 录音模型
//

import AVFoundation
import Foundation

struct Recording: Identifiable, Equatable {
    let id: String
    let url: URL
    let fileName: String
    let createdAt: Date
    let duration: TimeInterval?
    let fileSize: Int64

    // 从文件名解析的录音时间（用于时间轴定位）
    let recordingDate: Date

    init(url: URL) {
        self.id = url.path
        self.url = url
        self.fileName = url.lastPathComponent

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        self.createdAt = attributes?[.creationDate] as? Date ?? Date()
        self.fileSize = attributes?[.size] as? Int64 ?? 0

        // 获取音频时长
        self.duration = Recording.getAudioDuration(url: url)

        // 从文件名解析录音时间
        self.recordingDate =
            Recording.parseRecordingDate(from: url.lastPathComponent) ?? self.createdAt
    }

    // MARK: - 从文件名解析时间
    /// 解析文件名中的日期，格式：录音_yyyy-MM-dd_HH:mm.m4a 或 录音_yyyy-MM-dd_HHmm.m4a
    static func parseRecordingDate(from fileName: String) -> Date? {
        // 尝试匹配最新格式：2026.01.13 - pm 23.42 - 56 min.m4a 或 2026.01.13 - pm 23.42 - ing.m4a
        let v4Pattern = #"(\d{4})\.(\d{2})\.(\d{2}) - [ap]m (\d{2})\.(\d{2})"#
        if let date = parseWithPattern(v4Pattern, from: fileName) {
            return date
        }

        // 尝试匹配次新格式：2026.01.13_PM_18.00-18.02_00"02.m4a
        let v3Pattern = #"(\d{4})\.(\d{2})\.(\d{2})_[AP]M_(\d{2})\.(\d{2})"#
        if let date = parseWithPattern(v3Pattern, from: fileName) {
            return date
        }

        // 尝试匹配旧格式：26-01-13_PM_18.00-18.02_0"02.m4a
        let v2Pattern = #"(\d{2})-(\d{2})-(\d{2})_[AP]M_(\d{2})\.(\d{2})"#
        if let date = parseWithPattern(v2Pattern, from: fileName, isShortYear: true) {
            return date
        }

        // 尝试匹配更旧格式：录音_2024-12-28_14:02.m4a
        let newPattern = #"(\d{4})-(\d{2})-(\d{2})_(\d{2}):(\d{2})"#
        if let date = parseWithPattern(newPattern, from: fileName) {
            return date
        }

        // 尝试匹配初始格式：录音_2024-12-28_1402.m4a
        let oldPattern = #"(\d{4})-(\d{2})-(\d{2})_(\d{2})(\d{2})"#
        return parseWithPattern(oldPattern, from: fileName)
    }

    private static func parseWithPattern(
        _ pattern: String, from fileName: String, isShortYear: Bool = false
    ) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: fileName, range: NSRange(fileName.startIndex..., in: fileName))
        else {
            return nil
        }

        // 提取各时间组件
        guard let yearRange = Range(match.range(at: 1), in: fileName),
            let monthRange = Range(match.range(at: 2), in: fileName),
            let dayRange = Range(match.range(at: 3), in: fileName),
            let hourRange = Range(match.range(at: 4), in: fileName),
            let minuteRange = Range(match.range(at: 5), in: fileName),
            var year = Int(fileName[yearRange]),
            let month = Int(fileName[monthRange]),
            let day = Int(fileName[dayRange]),
            let hour = Int(fileName[hourRange]),
            let minute = Int(fileName[minuteRange])
        else {
            return nil
        }

        if isShortYear {
            year += 2000
        }

        // 构建日期
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute

        return Calendar.current.date(from: components)
    }

    // MARK: - 时间轴组件
    var year: Int {
        Calendar.current.component(.year, from: recordingDate)
    }

    var month: Int {
        Calendar.current.component(.month, from: recordingDate)
    }

    var day: Int {
        Calendar.current.component(.day, from: recordingDate)
    }

    var hour: Int {
        Calendar.current.component(.hour, from: recordingDate)
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
