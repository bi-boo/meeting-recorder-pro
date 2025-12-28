//
//  SummaryManager.swift
//  极简录音 - 总结状态管理器
//

import Foundation
import UserNotifications

class SummaryManager: ObservableObject {
    static let shared = SummaryManager()
    
    // MARK: - Published Properties
    @Published var activeSummaries: Set<String> = []  // 正在生成中的录音 ID
    @Published var failedSummaries: [String: Error] = [:]  // 失败的录音 ID -> 错误
    @Published private(set) var summaries: [String: SummaryEntry] = [:]  // 录音文件名 -> 总结内容
    
    private let settings = AppSettings.shared
    private let summaryService = AISummaryService.shared
    
    // 总结存储文件路径
    private var summariesFilePath: URL {
        let realHomeDirectory = URL(fileURLWithPath: "/Users/\(NSUserName())")
        return realHomeDirectory
            .appendingPathComponent("极简录音")
            .appendingPathComponent("summaries.json")
    }
    
    private init() {
        loadSummaries()
    }
    
    // MARK: - Public Methods
    
    /// 获取录音的总结
    func getSummary(for recordingFileName: String) -> String? {
        return summaries[recordingFileName]?.summary
    }
    
    /// 生成总结
    func generateSummary(for recording: Recording) {
        guard !activeSummaries.contains(recording.id) else { return }
        
        // 检查是否已有转写文件
        let transcriptionPath = settings.transcriptionsPath.appendingPathComponent(recording.transcriptionFileName)
        guard FileManager.default.fileExists(atPath: transcriptionPath.path) else {
            failedSummaries[recording.id] = AISummaryError.transcriptionNotFound
            return
        }
        
        // 清除之前的失败状态
        failedSummaries.removeValue(forKey: recording.id)
        
        // 标记为正在生成
        activeSummaries.insert(recording.id)
        
        Task {
            do {
                // 1. 读取转写文件内容
                let transcriptionText = try summaryService.readTranscriptionContent(at: transcriptionPath)
                
                // 2. 调用 AI 生成总结
                let summary = try await summaryService.generateSummary(transcriptionText: transcriptionText)
                
                // 3. 保存总结
                await MainActor.run {
                    self.summaries[recording.fileName] = SummaryEntry(
                        summary: summary,
                        generatedAt: Date()
                    )
                    self.activeSummaries.remove(recording.id)
                    self.saveSummaries()
                    self.showSuccessNotification(recording: recording, summary: summary)
                }
                
            } catch {
                await MainActor.run {
                    self.activeSummaries.remove(recording.id)
                    self.failedSummaries[recording.id] = error
                    self.showErrorNotification(recording: recording, error: error)
                }
            }
        }
    }
    
    // MARK: - Persistence
    
    private func loadSummaries() {
        guard FileManager.default.fileExists(atPath: summariesFilePath.path) else { return }
        
        do {
            let data = try Data(contentsOf: summariesFilePath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            summaries = try decoder.decode([String: SummaryEntry].self, from: data)
        } catch {
            print("加载总结缓存失败: \(error)")
        }
    }
    
    private func saveSummaries() {
        do {
            // 确保目录存在
            let directory = summariesFilePath.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(summaries)
            try data.write(to: summariesFilePath)
        } catch {
            print("保存总结缓存失败: \(error)")
        }
    }
    
    // MARK: - Notifications
    
    private func showSuccessNotification(recording: Recording, summary: String) {
        let content = UNMutableNotificationContent()
        content.title = "总结生成完成"
        content.body = "\(recording.fileName): \(summary)"
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    private func showErrorNotification(recording: Recording, error: Error) {
        let content = UNMutableNotificationContent()
        content.title = "总结生成失败"
        content.body = "\(recording.fileName): \(error.localizedDescription)"
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Summary Entry Model
struct SummaryEntry: Codable {
    let summary: String
    let generatedAt: Date
}
