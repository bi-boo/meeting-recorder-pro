//
//  AppSettings.swift
//  极简录音 - 应用设置模型
//

import Foundation

class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    // MARK: - Published Properties
    @Published var recordingsPath: URL {
        didSet { savePath(recordingsPath, forKey: "recordingsPath") }
    }
    
    @Published var transcriptionsPath: URL {
        didSet { savePath(transcriptionsPath, forKey: "transcriptionsPath") }
    }
    
    @Published var volcengineAppId: String {
        didSet { UserDefaults.standard.set(volcengineAppId, forKey: "volcengineAppId") }
    }
    
    @Published var volcengineAccessToken: String {
        didSet { UserDefaults.standard.set(volcengineAccessToken, forKey: "volcengineAccessToken") }
    }
    
    @Published var cloudbaseEnvId: String {
        didSet { UserDefaults.standard.set(cloudbaseEnvId, forKey: "cloudbaseEnvId") }
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
        
        self.volcengineAppId = UserDefaults.standard.string(forKey: "volcengineAppId") ?? defaultAppId
        self.volcengineAccessToken = UserDefaults.standard.string(forKey: "volcengineAccessToken") ?? defaultAccessToken
        self.cloudbaseEnvId = UserDefaults.standard.string(forKey: "cloudbaseEnvId") ?? defaultEnvId
        
        // 如果使用了默认值，保存到 UserDefaults
        if UserDefaults.standard.string(forKey: "volcengineAppId") == nil {
            UserDefaults.standard.set(volcengineAppId, forKey: "volcengineAppId")
            UserDefaults.standard.set(volcengineAccessToken, forKey: "volcengineAccessToken")
            UserDefaults.standard.set(cloudbaseEnvId, forKey: "cloudbaseEnvId")
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

