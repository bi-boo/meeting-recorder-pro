//
//  AppSettings.swift
//  极简录音 - 应用设置模型
//

import Foundation

class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    // MARK: - 存储路径设置
    @Published var recordingsPath: URL {
        didSet { savePath(recordingsPath, forKey: "recordingsPath") }
    }
    
    @Published var transcriptionsPath: URL {
        didSet { savePath(transcriptionsPath, forKey: "transcriptionsPath") }
    }
    
    // MARK: - API 配置
    @Published var volcengineAppId: String {
        didSet { UserDefaults.standard.set(volcengineAppId, forKey: "volcengineAppId") }
    }
    
    @Published var volcengineAccessToken: String {
        didSet { UserDefaults.standard.set(volcengineAccessToken, forKey: "volcengineAccessToken") }
    }
    
    @Published var cloudbaseEnvId: String {
        didSet { UserDefaults.standard.set(cloudbaseEnvId, forKey: "cloudbaseEnvId") }
    }
    
    // MARK: - 转写设置（火山引擎 API 参数）
    @Published var enableITN: Bool {  // 文本规范化（数字、日期等转换）
        didSet { UserDefaults.standard.set(enableITN, forKey: "transcription_enableITN") }
    }
    
    @Published var enablePunctuation: Bool {  // 自动添加标点符号
        didSet { UserDefaults.standard.set(enablePunctuation, forKey: "transcription_enablePunctuation") }
    }
    
    @Published var enableDDC: Bool {  // 语义顺滑（去除口语化表达）
        didSet { UserDefaults.standard.set(enableDDC, forKey: "transcription_enableDDC") }
    }
    
    @Published var showUtterances: Bool {  // 分句显示
        didSet { UserDefaults.standard.set(showUtterances, forKey: "transcription_showUtterances") }
    }
    
    @Published var enableSpeakerInfo: Bool {  // 说话人分离
        didSet { UserDefaults.standard.set(enableSpeakerInfo, forKey: "transcription_enableSpeakerInfo") }
    }
    
    @Published var enableEmotionDetection: Bool {  // 情绪检测
        didSet { UserDefaults.standard.set(enableEmotionDetection, forKey: "transcription_enableEmotionDetection") }
    }
    
    @Published var enableGenderDetection: Bool {  // 性别识别
        didSet { UserDefaults.standard.set(enableGenderDetection, forKey: "transcription_enableGenderDetection") }
    }
    
    @Published var showSpeechRate: Bool {  // 语速信息
        didSet { UserDefaults.standard.set(showSpeechRate, forKey: "transcription_showSpeechRate") }
    }
    
    @Published var modelVersion: String {  // 模型版本
        didSet { UserDefaults.standard.set(modelVersion, forKey: "transcription_modelVersion") }
    }
    
    // MARK: - Initialization
    private init() {
        // 默认路径: /Users/用户名/极简录音/录音 和 /Users/用户名/极简录音/转写
        // 与系统的「桌面」「文稿」「图片」等目录同级
        // 注意：不使用 homeDirectoryForCurrentUser，因为沙盒应用会返回容器路径
        let realHomeDirectory = URL(fileURLWithPath: "/Users/\(NSUserName())")
        let defaultRecordingsPath = realHomeDirectory
            .appendingPathComponent("极简录音")
            .appendingPathComponent("录音")
        
        let defaultTranscriptionsPath = realHomeDirectory
            .appendingPathComponent("极简录音")
            .appendingPathComponent("转写")
        
        // 加载路径设置
        if let data = UserDefaults.standard.data(forKey: "recordingsPath"),
           var isStale = Optional(false),
           let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
            self.recordingsPath = url
        } else {
            self.recordingsPath = defaultRecordingsPath
        }
        
        if let data = UserDefaults.standard.data(forKey: "transcriptionsPath"),
           var isStale = Optional(false),
           let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
            self.transcriptionsPath = url
        } else {
            self.transcriptionsPath = defaultTranscriptionsPath
        }
        
        // 加载 API 配置（使用内置默认值确保配置不丢失）
        let defaultAppId = "2505335848"
        let defaultAccessToken = "sHrVzn0mOgUbUF2Dvu-h17H7czytWk6i"
        let defaultEnvId = "thenextq-6g7bemmi5ea4ce29"
        
        let loadedAppId = UserDefaults.standard.string(forKey: "volcengineAppId") ?? defaultAppId
        let loadedAccessToken = UserDefaults.standard.string(forKey: "volcengineAccessToken") ?? defaultAccessToken
        let loadedEnvId = UserDefaults.standard.string(forKey: "cloudbaseEnvId") ?? defaultEnvId
        
        self.volcengineAppId = loadedAppId
        self.volcengineAccessToken = loadedAccessToken
        self.cloudbaseEnvId = loadedEnvId
        
        // 加载转写设置（默认全部启用基础功能）
        self.enableITN = UserDefaults.standard.object(forKey: "transcription_enableITN") as? Bool ?? true
        self.enablePunctuation = UserDefaults.standard.object(forKey: "transcription_enablePunctuation") as? Bool ?? true
        self.enableDDC = UserDefaults.standard.object(forKey: "transcription_enableDDC") as? Bool ?? true
        self.showUtterances = UserDefaults.standard.object(forKey: "transcription_showUtterances") as? Bool ?? true
        self.enableSpeakerInfo = UserDefaults.standard.object(forKey: "transcription_enableSpeakerInfo") as? Bool ?? false
        self.enableEmotionDetection = UserDefaults.standard.object(forKey: "transcription_enableEmotionDetection") as? Bool ?? false
        self.enableGenderDetection = UserDefaults.standard.object(forKey: "transcription_enableGenderDetection") as? Bool ?? false
        self.showSpeechRate = UserDefaults.standard.object(forKey: "transcription_showSpeechRate") as? Bool ?? false
        self.modelVersion = UserDefaults.standard.string(forKey: "transcription_modelVersion") ?? ""
        
        // 所有属性初始化完成后，保存默认值到 UserDefaults
        if UserDefaults.standard.string(forKey: "volcengineAppId") == nil {
            UserDefaults.standard.set(loadedAppId, forKey: "volcengineAppId")
            UserDefaults.standard.set(loadedAccessToken, forKey: "volcengineAccessToken")
            UserDefaults.standard.set(loadedEnvId, forKey: "cloudbaseEnvId")
        }
        
        // 确保目录存在
        try? FileManager.default.createDirectory(at: recordingsPath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: transcriptionsPath, withIntermediateDirectories: true)
    }
    
    // MARK: - Path Persistence
    private func savePath(_ url: URL, forKey key: String) {
        if let bookmarkData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmarkData, forKey: key)
        }
    }
    
    // MARK: - Load Secrets from Config File
    private func loadSecretsFromConfigFile() {
        // 尝试多个可能的路径
        let possiblePaths = [
            // 项目 config 目录（开发时）
            Bundle.main.bundlePath.replacingOccurrences(of: "/SimpleRecorder.app", with: "") + "/config/secrets.json",
            // 用户目录下的配置
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("极简录音/config/secrets.json").path,
            // 当前工作目录
            FileManager.default.currentDirectoryPath + "/config/secrets.json"
        ]
        
        for path in possiblePaths {
            let url = URL(fileURLWithPath: path)
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                
                if let volcengine = json["volcengine"] as? [String: Any] {
                    if let appId = volcengine["app_id"] as? String, volcengineAppId.isEmpty {
                        volcengineAppId = appId
                        // 保存到 UserDefaults
                        UserDefaults.standard.set(appId, forKey: "volcengineAppId")
                    }
                    if let token = volcengine["access_token"] as? String, volcengineAccessToken.isEmpty {
                        volcengineAccessToken = token
                        UserDefaults.standard.set(token, forKey: "volcengineAccessToken")
                    }
                }
                
                if let cloudbase = json["tencent_cloudbase"] as? [String: Any],
                   let envId = cloudbase["env_id"] as? String, cloudbaseEnvId.isEmpty {
                    cloudbaseEnvId = envId
                    UserDefaults.standard.set(envId, forKey: "cloudbaseEnvId")
                }
                
                // 找到并加载成功，退出循环
                if isAPIConfigured {
                    print("成功从 \(path) 加载 API 配置")
                    break
                }
            }
        }
    }
    
    // MARK: - API Configuration Valid
    var isAPIConfigured: Bool {
        !volcengineAppId.isEmpty && !volcengineAccessToken.isEmpty && !cloudbaseEnvId.isEmpty
    }
}

