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
    
    @Published var cloudbaseSecretId: String {
        didSet { UserDefaults.standard.set(cloudbaseSecretId, forKey: "cloudbaseSecretId") }
    }
    
    @Published var cloudbaseSecretKey: String {
        didSet { UserDefaults.standard.set(cloudbaseSecretKey, forKey: "cloudbaseSecretKey") }
    }
    
    // MARK: - AI 总结配置（豆包）
    // 硬编码豆包 API 地址和模型
    let doubaoApiBaseUrl = "https://ark.cn-beijing.volces.com/api/v3"
    let doubaoModelName = "doubao-seed-1-6-251015"
    
    @Published var doubaoApiKey: String {
        didSet { UserDefaults.standard.set(doubaoApiKey, forKey: "doubao_apiKey") }
    }
    
    @Published var autoGenerateSummary: Bool {
        didSet { UserDefaults.standard.set(autoGenerateSummary, forKey: "ai_autoGenerateSummary") }
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
        let loadedSecretId = UserDefaults.standard.string(forKey: "cloudbaseSecretId") ?? ""
        let loadedSecretKey = UserDefaults.standard.string(forKey: "cloudbaseSecretKey") ?? ""
        
        self.volcengineAppId = loadedAppId
        self.volcengineAccessToken = loadedAccessToken
        self.cloudbaseEnvId = loadedEnvId
        self.cloudbaseSecretId = loadedSecretId
        self.cloudbaseSecretKey = loadedSecretKey
        
        // 数据迁移：清理类型不正确的旧数据（之前存储的是 Int 而非 Bool）
        let transcriptionKeys = [
            "transcription_enableITN",
            "transcription_enablePunctuation",
            "transcription_enableDDC",
            "transcription_showUtterances",
            "transcription_enableSpeakerInfo",
            "transcription_enableEmotionDetection",
            "transcription_enableGenderDetection",
            "transcription_showSpeechRate"
        ]
        for key in transcriptionKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                // 如果是 Int 类型（旧格式），删除它
                if value is Int {
                    print("🧹 清理 Int 类型的旧数据: \(key) = \(value)")
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
        
        // 辅助函数：安全读取 Bool，如果 key 不存在则返回默认值
        func loadBool(forKey key: String, defaultValue: Bool) -> Bool {
            if UserDefaults.standard.object(forKey: key) == nil {
                return defaultValue
            }
            return UserDefaults.standard.bool(forKey: key)
        }
        
        // 加载转写设置（使用辅助函数确保默认值生效）
        self.enableITN = loadBool(forKey: "transcription_enableITN", defaultValue: true)
        self.enablePunctuation = loadBool(forKey: "transcription_enablePunctuation", defaultValue: true)
        self.enableDDC = loadBool(forKey: "transcription_enableDDC", defaultValue: true)
        self.showUtterances = loadBool(forKey: "transcription_showUtterances", defaultValue: true)
        self.enableSpeakerInfo = loadBool(forKey: "transcription_enableSpeakerInfo", defaultValue: true)  // 会议场景默认开启
        self.enableEmotionDetection = loadBool(forKey: "transcription_enableEmotionDetection", defaultValue: false)
        self.enableGenderDetection = loadBool(forKey: "transcription_enableGenderDetection", defaultValue: true)
        self.showSpeechRate = loadBool(forKey: "transcription_showSpeechRate", defaultValue: false)
        self.modelVersion = UserDefaults.standard.string(forKey: "transcription_modelVersion") ?? ""  // 不传，使用默认版本
        
        // 加载豆包 API 配置
        self.doubaoApiKey = UserDefaults.standard.string(forKey: "doubao_apiKey") ?? ""
        self.autoGenerateSummary = UserDefaults.standard.object(forKey: "ai_autoGenerateSummary") as? Bool ?? false
        
        // 所有属性初始化完成后，保存默认值到 UserDefaults
        if UserDefaults.standard.string(forKey: "volcengineAppId") == nil {
            UserDefaults.standard.set(loadedAppId, forKey: "volcengineAppId")
            UserDefaults.standard.set(loadedAccessToken, forKey: "volcengineAccessToken")
            UserDefaults.standard.set(loadedEnvId, forKey: "cloudbaseEnvId")
            UserDefaults.standard.set(loadedSecretId, forKey: "cloudbaseSecretId")
            UserDefaults.standard.set(loadedSecretKey, forKey: "cloudbaseSecretKey")
        }
        
        // 确保目录存在
        try? FileManager.default.createDirectory(at: recordingsPath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: transcriptionsPath, withIntermediateDirectories: true)
        
        // 调试：打印初始化后的值
        print("🔧 AppSettings 初始化完成:")
        print("  - enableSpeakerInfo: \(self.enableSpeakerInfo)")
        print("  - enableEmotionDetection: \(self.enableEmotionDetection)")
        print("  - enableGenderDetection: \(self.enableGenderDetection)")
        print("  - showSpeechRate: \(self.showSpeechRate)")
        print("  - modelVersion: \(self.modelVersion)")
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
                    
                    if let secretId = cloudbase["secret_id"] as? String {
                        cloudbaseSecretId = secretId
                        UserDefaults.standard.set(secretId, forKey: "cloudbaseSecretId")
                    }
                    if let secretKey = cloudbase["secret_key"] as? String {
                        cloudbaseSecretKey = secretKey
                        UserDefaults.standard.set(secretKey, forKey: "cloudbaseSecretKey")
                    }
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
        !volcengineAppId.isEmpty && !volcengineAccessToken.isEmpty && !cloudbaseEnvId.isEmpty && !cloudbaseSecretId.isEmpty && !cloudbaseSecretKey.isEmpty
    }
    
    // MARK: - AI Configuration Valid（豆包）
    var isAIConfigured: Bool {
        !doubaoApiKey.isEmpty
    }
}

