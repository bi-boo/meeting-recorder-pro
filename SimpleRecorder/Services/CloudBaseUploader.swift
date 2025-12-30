//
//  CloudBaseUploader.swift
//  极简录音 - 腾讯云 CloudBase 上传服务 (原生网络版)
//

import Foundation

class CloudBaseUploader {
    static let shared = CloudBaseUploader()
    
    private let settings = AppSettings.shared
    
    // 上传缓存：文件路径 -> (URL, 上传时间)
    private var uploadCache: [String: (url: String, timestamp: Date)] = [:]
    private let cacheExpiration: TimeInterval = 30 * 60 // 30 分钟
    
    private init() {}
    
    // MARK: - Upload File
    func upload(fileURL: URL) async throws -> String {
        let filePath = fileURL.path
        
        // 1. 检查缓存
        if let cached = uploadCache[filePath],
           Date().timeIntervalSince(cached.timestamp) < cacheExpiration {
            print("✅ 使用缓存的上传链接: \(fileURL.lastPathComponent)")
            return cached.url
        }
        
        // 2. 准备上传
        let safeFileName = fileURL.lastPathComponent
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "(", with: "_")
            .replacingOccurrences(of: ")", with: "_")
        let remotePath = "transcribe/\(safeFileName)"
        
        print("📤 正在上传到腾讯云 CloudBase (原生直传): \(fileURL.lastPathComponent)")
        
        // 3. 获取上传凭证 (GetUploadMetadata)
        let uploadInfo = try await getUploadMetadata(path: remotePath)
        
        // 4. 执行文件直传到 COS
        try await uploadToCOS(fileURL: fileURL, uploadURL: uploadInfo.url, authorization: uploadInfo.authorization, token: uploadInfo.token)
        
        // 5. 获取访问链接（TCB 存储默认链接格式）
        // 注意：TCB 上传接口返回的 url 有时是临时上传地址，访问地址通常需要单独拼接或通过接口获取
        // 这里我们优先使用 TCB 的 download 地址模式
        let downloadURL = try await getDownloadURL(path: remotePath)
        
        // 缓存并返回
        uploadCache[filePath] = (url: downloadURL, timestamp: Date())
        print("✅ 文件上传成功: \(downloadURL)")
        return downloadURL
    }
    
    // MARK: - API Helpers
    
    private func getUploadMetadata(path: String) async throws -> (url: String, authorization: String, token: String) {
        let timestamp = Int(Date().timeIntervalSince1970)
        let host = "tcb-api.tencentcloudapi.com"
        let action = "GetUploadMetadata"
        let service = "tcb"
        let version = "2018-06-08"
        
        let payload = "{\"EnvId\":\"\(settings.cloudbaseEnvId)\",\"Path\":\"\(path)\"}"
        
        let auth = TencentCloudSignature.generateAuthorization(
            secretId: settings.cloudbaseSecretId,
            secretKey: settings.cloudbaseSecretKey,
            service: service,
            action: action,
            version: version,
            region: "ap-shanghai", // 默认区域，建议与环境匹配
            timestamp: timestamp,
            payload: payload,
            host: host
        )
        
        var request = URLRequest(url: URL(string: "https://\(host)")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(action, forHTTPHeaderField: "X-TC-Action")
        request.setValue(version, forHTTPHeaderField: "X-TC-Version")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.httpBody = payload.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CloudBaseError.uploadFailed("获取上传元数据失败 (HTTP \( (response as? HTTPURLResponse)?.statusCode ?? 0 ))")
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let resp = json?["Response"] as? [String: Any], let error = resp["Error"] as? [String: Any] {
            throw CloudBaseError.uploadFailed("TCB 错误: \(error["Message"] ?? "未知错误")")
        }
        
        guard let resp = json?["Response"] as? [String: Any],
              let url = resp["Url"] as? String,
              let authorization = resp["Authorization"] as? String,
              let token = resp["Token"] as? String else {
            throw CloudBaseError.parseURLFailed
        }
        
        return (url, authorization, token)
    }
    
    private func uploadToCOS(fileURL: URL, uploadURL: String, authorization: String, token: String) async throws {
        var request = URLRequest(url: URL(string: uploadURL)!)
        request.httpMethod = "PUT"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(token, forHTTPHeaderField: "x-cos-security-token")
        
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            if let errorMsg = String(data: data, encoding: .utf8) {
                 print("COS Upload Error: \(errorMsg)")
            }
            throw CloudBaseError.uploadFailed("COS 上传失败 (HTTP \( (response as? HTTPURLResponse)?.statusCode ?? 0 ))")
        }
    }
    
    private func getDownloadURL(path: String) async throws -> String {
        // TCB 获取下载链接接口
        let timestamp = Int(Date().timeIntervalSince1970)
        let host = "tcb-api.tencentcloudapi.com"
        let action = "DescribeDownloadUrls"
        let service = "tcb"
        let version = "2018-06-08"
        
        let payload = "{\"EnvId\":\"\(settings.cloudbaseEnvId)\",\"Paths\":[\"\(path)\"]}"
        
        let auth = TencentCloudSignature.generateAuthorization(
            secretId: settings.cloudbaseSecretId,
            secretKey: settings.cloudbaseSecretKey,
            service: service,
            action: action,
            version: version,
            region: "ap-shanghai",
            timestamp: timestamp,
            payload: payload,
            host: host
        )
        
        var request = URLRequest(url: URL(string: "https://\(host)")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(action, forHTTPHeaderField: "X-TC-Action")
        request.setValue(version, forHTTPHeaderField: "X-TC-Version")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.httpBody = payload.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        guard let resp = json?["Response"] as? [String: Any],
              let urlList = resp["DownloadUrls"] as? [[String: Any]],
              let first = urlList.first,
              let url = first["Url"] as? String else {
            throw CloudBaseError.getURLFailed("获取下载链接失败")
        }
        
        return url
    }
    
    // MARK: - Delete File
    func deleteByLocalURL(_ fileURL: URL) async {
        let safeFileName = fileURL.lastPathComponent
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "(", with: "_")
            .replacingOccurrences(of: ")", with: "_")
        let remotePath = "transcribe/\(safeFileName)"
        
        print("🗑️ 正在删除云端文件 (原生): \(remotePath)")
        
        do {
            let timestamp = Int(Date().timeIntervalSince1970)
            let host = "tcb-api.tencentcloudapi.com"
            let action = "DeleteFile"
            let service = "tcb"
            let version = "2018-06-08"
            
            let payload = "{\"EnvId\":\"\(settings.cloudbaseEnvId)\",\"FileIdList\":[\"cloud://\(settings.cloudbaseEnvId).\(settings.cloudbaseEnvId)/\(remotePath)\"]}"
            
            let auth = TencentCloudSignature.generateAuthorization(
                secretId: settings.cloudbaseSecretId,
                secretKey: settings.cloudbaseSecretKey,
                service: service,
                action: action,
                version: version,
                region: "ap-shanghai",
                timestamp: timestamp,
                payload: payload,
                host: host
            )
            
            var request = URLRequest(url: URL(string: "https://\(host)")!)
            request.httpMethod = "POST"
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue(host, forHTTPHeaderField: "Host")
            request.setValue(action, forHTTPHeaderField: "X-TC-Action")
            request.setValue(version, forHTTPHeaderField: "X-TC-Version")
            request.setValue(String(timestamp), forHTTPHeaderField: "X-TC-Timestamp")
            request.setValue(auth, forHTTPHeaderField: "Authorization")
            request.httpBody = payload.data(using: .utf8)
            
            let _ = try await URLSession.shared.data(for: request)
            print("✅ 云端文件已删除: \(remotePath)")
        } catch {
            print("⚠️ 删除云端文件失败: \(error)")
        }
        
        uploadCache.removeValue(forKey: fileURL.path)
    }
}

// MARK: - Errors
enum CloudBaseError: LocalizedError {
    case uploadFailed(String)
    case getURLFailed(String)
    case parseURLFailed
    
    var errorDescription: String? {
        switch self {
        case .uploadFailed(let msg):
            return "文件上传失败: \(msg)"
        case .getURLFailed(let msg):
            return "获取链接失败: \(msg)"
        case .parseURLFailed:
            return "无法解析文件访问链接"
        }
    }
}
