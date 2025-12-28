//
//  AISummaryService.swift
//  极简录音 - AI 总结服务（豆包 API）
//

import Foundation

class AISummaryService {
    static let shared = AISummaryService()
    
    private let settings = AppSettings.shared
    
    private init() {}
    
    // MARK: - Generate Summary
    /// 根据转写文件内容生成 30 字以内的总结
    func generateSummary(transcriptionText: String) async throws -> String {
        guard settings.isAIConfigured else {
            throw AISummaryError.notConfigured
        }
        
        // 构建请求 URL（使用硬编码的豆包 API）
        guard let url = URL(string: "\(settings.doubaoApiBaseUrl)/chat/completions") else {
            throw AISummaryError.invalidUrl
        }
        
        // 构建请求体（豆包 API 格式）
        // 注意：doubao-seed 是思维链模型，需要足够的 token 给推理过程
        let requestBody: [String: Any] = [
            "model": settings.doubaoModelName,
            "messages": [
                [
                    "role": "system",
                    "content": "你是会议总结助手。请用30字以内概括用户提供的会议转写内容的主题。只输出总结，不要其他任何内容，不要加引号。"
                ],
                [
                    "role": "user",
                    "content": transcriptionText
                ]
            ],
            "max_completion_tokens": 500  // 需要足够空间给思维链推理
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)
        
        // 构建请求
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.doubaoApiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData
        request.timeoutInterval = 30
        
        // 发送请求（带重试机制，最多 3 次）
        var lastError: Error?
        for attempt in 1...3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                return try parseResponse(data: data, response: response)
            } catch {
                lastError = error
                // 网络错误或超时时重试
                if attempt < 3 {
                    print("⚠️ AI 总结请求失败（尝试 \(attempt)/3），1 秒后重试...")
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 等待 1 秒
                }
            }
        }
        throw lastError ?? AISummaryError.invalidResponse
    }
    
    // MARK: - Parse Response
    private func parseResponse(data: Data, response: URLResponse) throws -> String {
        // 检查响应
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AISummaryError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            // 尝试解析错误信息
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw AISummaryError.apiError(statusCode: httpResponse.statusCode, message: message)
            }
            throw AISummaryError.apiError(statusCode: httpResponse.statusCode, message: "未知错误")
        }
        
        // 解析响应
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AISummaryError.parseError
        }
        
        // 清理并返回总结（去除多余空白和引号）
        let summary = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .init(charactersIn: "\"'"))
        
        return summary
    }
    
    // MARK: - Read Transcription File
    /// 读取转写文件内容（去除 markdown 格式头部）
    func readTranscriptionContent(at url: URL) throws -> String {
        let content = try String(contentsOf: url, encoding: .utf8)
        
        // 去除 markdown 头部（标题、元信息、分隔线）
        // 找到 "---" 分隔线后的实际内容
        if let range = content.range(of: "---\n") {
            let mainContent = String(content[range.upperBound...])
            return mainContent.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Error Types
enum AISummaryError: LocalizedError {
    case notConfigured
    case invalidUrl
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case parseError
    case transcriptionNotFound
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "AI 服务未配置，请在设置中填写 API 密钥"
        case .invalidUrl:
            return "API 地址格式错误"
        case .invalidResponse:
            return "服务器响应格式错误"
        case .apiError(let statusCode, let message):
            return "API 错误 (\(statusCode)): \(message)"
        case .parseError:
            return "无法解析 AI 返回的内容"
        case .transcriptionNotFound:
            return "转写文件不存在"
        }
    }
}
