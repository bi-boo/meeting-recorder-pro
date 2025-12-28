//
//  CloudBaseUploader.swift
//  极简录音 - 腾讯云 CloudBase 上传服务
//

import Foundation

class CloudBaseUploader {
    static let shared = CloudBaseUploader()
    
    private let settings = AppSettings.shared
    
    // 上传缓存：文件路径 -> (URL, 上传时间)
    // 30分钟内相同文件不重复上传
    private var uploadCache: [String: (url: String, timestamp: Date)] = [:]
    private let cacheExpiration: TimeInterval = 30 * 60 // 30 分钟
    
    private init() {}
    
    // MARK: - Upload File
    func upload(fileURL: URL) async throws -> String {
        let filePath = fileURL.path
        
        // 检查缓存：如果 30 分钟内上传过相同文件，直接返回缓存的 URL
        if let cached = uploadCache[filePath],
           Date().timeIntervalSince(cached.timestamp) < cacheExpiration {
            print("✅ 使用缓存的上传链接: \(fileURL.lastPathComponent)")
            return cached.url
        }
        
        let envId = settings.cloudbaseEnvId
        
        // 生成安全的远程文件名：替换空格和特殊字符为下划线
        let safeFileName = fileURL.lastPathComponent
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "(", with: "_")
            .replacingOccurrences(of: ")", with: "_")
        let remotePath = "transcribe/\(safeFileName)"
        
        print("📤 正在上传到腾讯云 CloudBase: \(fileURL.lastPathComponent) -> \(safeFileName)")
        
        // 使用 tcb CLI 上传
        let uploadResult = try await runCommand(
            "tcb", "storage", "upload",
            fileURL.path, remotePath,
            "-e", envId
        )
        
        if !uploadResult.success {
            throw CloudBaseError.uploadFailed(uploadResult.error)
        }
        
        // 获取临时访问链接
        let urlResult = try await runCommand(
            "tcb", "storage", "url",
            remotePath,
            "-e", envId
        )
        
        if !urlResult.success {
            throw CloudBaseError.getURLFailed(urlResult.error)
        }
        
        // 从输出中提取 URL
        guard let url = extractURL(from: urlResult.output) else {
            throw CloudBaseError.parseURLFailed
        }
        
        // 缓存上传结果
        uploadCache[filePath] = (url: url, timestamp: Date())
        
        print("✅ 文件上传成功: \(url)")
        return url
    }
    
    // MARK: - Delete File
    /// 删除腾讯云上的文件
    func delete(remotePath: String) async {
        let envId = settings.cloudbaseEnvId
        
        print("🗑️ 正在删除云端文件: \(remotePath)")
        
        do {
            let result = try await runCommand(
                "tcb", "storage", "delete",
                remotePath,
                "-e", envId
            )
            
            if result.success {
                print("✅ 云端文件已删除: \(remotePath)")
            } else {
                print("⚠️ 删除云端文件失败: \(result.error)")
            }
        } catch {
            print("⚠️ 删除云端文件出错: \(error)")
        }
    }
    
    /// 根据本地文件 URL 删除对应的云端文件
    func deleteByLocalURL(_ fileURL: URL) async {
        // 使用与上传时相同的安全文件名
        let safeFileName = fileURL.lastPathComponent
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "(", with: "_")
            .replacingOccurrences(of: ")", with: "_")
        let remotePath = "transcribe/\(safeFileName)"
        await delete(remotePath: remotePath)
        
        // 同时清除缓存
        uploadCache.removeValue(forKey: fileURL.path)
    }
    
    // MARK: - Run Command
    private func runCommand(_ arguments: String...) async throws -> CommandResult {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                
                // 尝试多个可能的 tcb 路径
                let possiblePaths = [
                    "/usr/local/bin/tcb",
                    "/opt/homebrew/bin/tcb",
                    "\(NSHomeDirectory())/.npm-global/bin/tcb"
                ]
                
                var foundPath: String?
                for path in possiblePaths {
                    if FileManager.default.fileExists(atPath: path) {
                        foundPath = path
                        break
                    }
                }
                
                guard let tcbPath = foundPath else {
                    continuation.resume(returning: CommandResult(
                        success: false,
                        output: "",
                        error: "tcb CLI 未找到，请先安装: npm install -g @cloudbase/cli"
                    ))
                    return
                }
                
                process.executableURL = URL(fileURLWithPath: tcbPath)
                // 参数不包含 "tcb"，直接使用传入的参数（去掉第一个 "tcb"）
                let args = Array(arguments.dropFirst())
                process.arguments = args
                
                print("执行命令: \(tcbPath) \(args.joined(separator: " "))")
                
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    
                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    let error = String(data: errorData, encoding: .utf8) ?? ""
                    
                    print("命令输出: \(output)")
                    if !error.isEmpty {
                        print("命令错误: \(error)")
                    }
                    
                    let success = process.terminationStatus == 0
                    continuation.resume(returning: CommandResult(
                        success: success,
                        output: output,
                        error: success ? "" : (error.isEmpty ? output : error)
                    ))
                } catch {
                    print("命令执行失败: \(error)")
                    continuation.resume(returning: CommandResult(
                        success: false,
                        output: "",
                        error: error.localizedDescription
                    ))
                }
            }
        }
    }
    
    // MARK: - Extract URL
    private func extractURL(from output: String) -> String? {
        // TCB 输出格式通常是: ✔ File temporary access address: https://...
        let pattern = #"https?://[^\s\r\n]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range, in: output) else {
            return nil
        }
        return String(output[range])
    }
    
    // MARK: - Command Result
    private struct CommandResult {
        let success: Bool
        let output: String
        let error: String
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
