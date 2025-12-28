//
//  TranscriptionManager.swift
//  极简录音 - 转写服务管理器
//

import Foundation
import UserNotifications

class TranscriptionManager: ObservableObject {
    static let shared = TranscriptionManager()
    
    @Published var activeTranscriptions: Set<String> = []
    @Published var failedTranscriptions: [String: Error] = [:]
    
    private let settings = AppSettings.shared
    
    private init() {}
    
    // MARK: - Transcription
    func transcribe(recording: Recording) {
        guard !activeTranscriptions.contains(recording.id) else { return }
        
        // 清除之前的失败状态
        failedTranscriptions.removeValue(forKey: recording.id)
        
        // 标记为正在转写
        activeTranscriptions.insert(recording.id)
        
        Task {
            do {
                // 1. 上传到腾讯云
                let audioURL = try await CloudBaseUploader.shared.upload(fileURL: recording.url)
                
                // 2. 提交转写任务
                let requestId = try await VolcEngineService.shared.submitTranscription(audioURL: audioURL, format: recording.url.pathExtension)
                
                // 3. 轮询等待结果
                let result = try await VolcEngineService.shared.waitForResult(requestId: requestId)
                
                // 4. 格式化并保存
                let markdown = formatToMarkdown(result: result, recording: recording)
                let outputPath = settings.transcriptionsPath.appendingPathComponent(recording.transcriptionFileName)
                try markdown.write(to: outputPath, atomically: true, encoding: .utf8)
                
                // 5. 删除腾讯云上的临时文件（异步，不阻塞）
                Task {
                    await CloudBaseUploader.shared.deleteByLocalURL(recording.url)
                }
                
                // 完成
                await MainActor.run {
                    activeTranscriptions.remove(recording.id)
                    showSuccessNotification(recording: recording, outputPath: outputPath)
                    
                    // 自动生成总结（如开启）
                    if settings.autoGenerateSummary && settings.isAIConfigured {
                        SummaryManager.shared.generateSummary(for: recording)
                    }
                }
                
            } catch {
                await MainActor.run {
                    activeTranscriptions.remove(recording.id)
                    failedTranscriptions[recording.id] = error
                    showErrorNotification(recording: recording, error: error)
                }
            }
        }
    }
    
    // MARK: - Format Result
    private func formatToMarkdown(result: TranscriptionResult, recording: Recording) -> String {
        var lines: [String] = []
        
        // 标题
        lines.append("# 录音转写文稿\n")
        lines.append("> 文件名：\(recording.fileName)")
        lines.append("> 音频时长：\(recording.formattedDuration)")
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        lines.append("> 转写时间：\(dateFormatter.string(from: Date()))\n")
        lines.append("---\n")
        
        // 内容
        if let utterances = result.utterances, !utterances.isEmpty {
            var currentSpeaker: Int?
            print("📝 [DEBUG] 准备生成 Markdown，Utterances 数量: \(utterances.count)")
            
            for (index, utt) in utterances.enumerated() {
                // 打印每一条的解析数据到控制台，以便排查
                print("  - [\(index)] speaker=\(String(describing: utt.speaker)), gender=\(String(describing: utt.gender)), emotion=\(String(describing: utt.emotion)), speechRate=\(String(describing: utt.speechRate))")
                
                // 说话人显示逻辑：
                // 1. 如果这是第一条内容，由于 currentSpeaker 是 nil，如果 utt.speaker 有值，则会显示标签。
                // 2. 如果 utt.speaker 和 currentSpeaker 不同，则显示新标签。
                if let speaker = utt.speaker {
                    if speaker != currentSpeaker {
                        currentSpeaker = speaker
                        // 生成说话人标签（包含性别信息）
                        let genderText = utt.gender.map { genderLabel($0) } ?? ""
                        lines.append("\n**【说话人 \(speaker)\(genderText)】**\n")
                    }
                } else if currentSpeaker != nil {
                    // 如果当前 speaker 丢失为 nil，标记为未知说话人或重置
                    currentSpeaker = nil
                    lines.append("\n**【未知说话人】**\n")
                }
                
                // 时间戳
                let startStr = formatTime(ms: utt.startTime)
                
                // 附加信息标签
                var tags: [String] = []
                if let emotion = utt.emotion {
                    tags.append(emotionLabel(emotion))
                }
                if let speechRate = utt.speechRate {
                    tags.append("语速 \(String(format: "%.1f", speechRate))")
                }
                
                let tagText = tags.isEmpty ? "" : " [\(tags.joined(separator: " | "))]"
                lines.append("[\(startStr)]\(tagText) \(utt.text)")
            }
        } else if let text = result.text {
            lines.append(text)
        }
        
        return lines.joined(separator: "\n")
    }
    
    private func formatTime(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    private func emotionLabel(_ emotion: String) -> String {
        switch emotion.lowercased() {
        case "angry": return "生气"
        case "happy": return "开心"
        case "sad": return "悲伤"
        case "surprise": return "惊讶"
        default: return "中性"
        }
    }
    
    private func genderLabel(_ gender: String) -> String {
        switch gender.lowercased() {
        case "male": return "男"
        case "female": return "女"
        default: return ""
        }
    }
    
    // MARK: - Notifications
    private func showSuccessNotification(recording: Recording, outputPath: URL) {
        let content = UNMutableNotificationContent()
        content.title = "转写完成"
        content.body = "\(recording.fileName) 已转写完成"
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    private func showErrorNotification(recording: Recording, error: Error) {
        let content = UNMutableNotificationContent()
        content.title = "转写失败"
        content.body = "\(recording.fileName): \(error.localizedDescription)"
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Transcription Result Model
struct TranscriptionResult {
    let text: String?
    let utterances: [Utterance]?
    let audioInfo: AudioInfo?
    
    struct Utterance {
        let text: String
        let startTime: Int
        let endTime: Int
        let speaker: Int?       // 火山引擎返回的是整数类型的 speaker
        let emotion: String?    // 情绪检测
        let gender: String?     // 性别识别
        let speechRate: Double? // 语速（字/秒）
    }
    
    struct AudioInfo {
        let duration: Int
    }
}
