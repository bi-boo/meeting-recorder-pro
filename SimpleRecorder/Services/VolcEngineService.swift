//
//  VolcEngineService.swift
//  极简录音 - 火山引擎 API 服务
//

import Foundation

class VolcEngineService {
    static let shared = VolcEngineService()
    
    private let settings = AppSettings.shared
    
    // API 端点
    private let submitURL = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit")!
    private let queryURL = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/query")!
    private let resourceId = "volc.seedasr.auc"
    
    // 轮询配置
    private let pollInterval: TimeInterval = 5
    private let maxPollTime: TimeInterval = 3600
    
    private init() {}
    
    // MARK: - Submit Transcription
    func submitTranscription(audioURL: String, format: String) async throws -> String {
        let requestId = UUID().uuidString.lowercased()
        
        // m4a 实际是 AAC 编码，火山引擎可以当作 mp3 处理
        let audioFormat = getAudioFormat(format)
        
        print("提交转写任务:")
        print("  - Request ID: \(requestId)")
        print("  - Audio URL: \(audioURL)")
        print("  - Format: \(audioFormat)")
        // 根据用户设置构建请求参数
        var requestParams: [String: Any] = [
            "model_name": "bigmodel"
        ]
        
        // 基础功能
        if settings.enableITN { requestParams["enable_itn"] = true }
        if settings.enablePunctuation { requestParams["enable_punc"] = true }
        if settings.enableDDC { requestParams["enable_ddc"] = true }
        if settings.showUtterances { requestParams["show_utterances"] = true }
        
        // 高级功能
        if settings.enableSpeakerInfo { requestParams["enable_speaker_info"] = true }
        if settings.enableEmotionDetection { requestParams["enable_emotion_detection"] = true }
        if settings.enableGenderDetection { requestParams["enable_gender_detection"] = true }
        if settings.showSpeechRate { requestParams["show_speech_rate"] = true }
        
        // 模型版本（如果设置了）
        if !settings.modelVersion.isEmpty {
            requestParams["model_version"] = settings.modelVersion
        }
        
        let payload: [String: Any] = [
            "user": ["uid": "simple-recorder-app"],
            "audio": [
                "format": audioFormat,
                "url": audioURL
            ],
            "request": requestParams
        ]
        
        var request = URLRequest(url: submitURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.volcengineAppId, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(settings.volcengineAccessToken, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(requestId, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        print("  - App ID: \(settings.volcengineAppId)")
        print("  - Resource ID: \(resourceId)")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VolcEngineError.invalidResponse
        }
        
        let statusCode = httpResponse.value(forHTTPHeaderField: "X-Api-Status-Code") ?? ""
        let message = httpResponse.value(forHTTPHeaderField: "X-Api-Message") ?? ""
        
        print("  - Status Code: \(statusCode)")
        print("  - Message: \(message)")
        
        // 打印响应体用于调试
        if let responseStr = String(data: data, encoding: .utf8) {
            print("  - Response: \(responseStr.prefix(500))")
        }
        
        if statusCode == "20000000" {
            print("火山引擎任务提交成功: \(requestId)")
            return requestId
        } else {
            throw VolcEngineError.submitFailed(code: statusCode, message: message)
        }
    }
    
    // MARK: - Wait for Result
    func waitForResult(requestId: String) async throws -> TranscriptionResult {
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < maxPollTime {
            let result = try await queryResult(requestId: requestId)
            
            switch result {
            case .success(let transcription):
                return transcription
            case .processing:
                print("火山引擎处理中... (\(Int(Date().timeIntervalSince(startTime)))秒)")
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            case .error(let error):
                throw error
            }
        }
        
        throw VolcEngineError.timeout
    }
    
    // MARK: - Query Result
    private func queryResult(requestId: String) async throws -> QueryResult {
        var request = URLRequest(url: queryURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.volcengineAppId, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(settings.volcengineAccessToken, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(requestId, forHTTPHeaderField: "X-Api-Request-Id")
        request.httpBody = "{}".data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VolcEngineError.invalidResponse
        }
        
        let statusCode = httpResponse.value(forHTTPHeaderField: "X-Api-Status-Code") ?? ""
        let message = httpResponse.value(forHTTPHeaderField: "X-Api-Message") ?? ""
        
        print("查询结果: statusCode=\(statusCode), message=\(message)")
        
        // 打印响应体用于调试
        if !["20000001", "20000002"].contains(statusCode) {
            if let responseStr = String(data: data, encoding: .utf8) {
                print("  - Response: \(responseStr.prefix(300))")
            }
        }
        
        switch statusCode {
        case "20000000":
            // 成功
            return .success(try parseResult(data: data))
        case "20000001", "20000002":
            // 处理中 / 队列中
            return .processing
        case "20000003":
            // 静音
            throw VolcEngineError.silentAudio
        default:
            // 包含更多错误信息
            let fullMessage = message.isEmpty ? "未知错误" : message
            return .error(VolcEngineError.queryFailed(code: statusCode, message: fullMessage))
        }
    }
    
    // MARK: - Parse Result
    private func parseResult(data: Data) throws -> TranscriptionResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VolcEngineError.parseError
        }
        
        let textResult = json["result"] as? [String: Any]
        let fullText = textResult?["text"] as? String
        
        var utterances: [TranscriptionResult.Utterance]?
        if let uttArray = textResult?["utterances"] as? [[String: Any]] {
            utterances = uttArray.compactMap { utt -> TranscriptionResult.Utterance? in
                guard let text = utt["text"] as? String else { return nil }
                let additions = utt["additions"] as? [String: Any]
                
                return TranscriptionResult.Utterance(
                    text: text,
                    startTime: utt["start_time"] as? Int ?? 0,
                    endTime: utt["end_time"] as? Int ?? 0,
                    speakerId: additions?["speaker_id"] as? String,
                    emotion: additions?["emotion"] as? String
                )
            }
        }
        
        var audioInfo: TranscriptionResult.AudioInfo?
        if let info = json["audio_info"] as? [String: Any], let duration = info["duration"] as? Int {
            audioInfo = TranscriptionResult.AudioInfo(duration: duration)
        }
        
        return TranscriptionResult(text: fullText, utterances: utterances, audioInfo: audioInfo)
    }
    
    // MARK: - Helpers
    private func getAudioFormat(_ ext: String) -> String {
        switch ext.lowercased() {
        case "m4a", "mp3": return "mp3"
        case "wav": return "wav"
        case "ogg": return "ogg"
        default: return "mp3"
        }
    }
    
    private enum QueryResult {
        case success(TranscriptionResult)
        case processing
        case error(Error)
    }
}

// MARK: - Errors
enum VolcEngineError: LocalizedError {
    case invalidResponse
    case submitFailed(code: String, message: String)
    case queryFailed(code: String, message: String)
    case silentAudio
    case timeout
    case parseError
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "无效的服务器响应"
        case .submitFailed(let code, let message):
            return "任务提交失败: \(message) (code: \(code))"
        case .queryFailed(let code, let message):
            return "查询失败: \(message) (code: \(code))"
        case .silentAudio:
            return "音频为静音，无法识别"
        case .timeout:
            return "转写超时，请稍后重试"
        case .parseError:
            return "结果解析失败"
        }
    }
}
