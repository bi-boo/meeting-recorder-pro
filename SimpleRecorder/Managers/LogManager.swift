//
//  LogManager.swift
//  会议录音 Pro - 日志管理器
//
//  功能：记录应用运行日志到本地文件，便于排查问题
//

import Foundation

// MARK: - 日志级别
enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
    case critical = "CRITICAL"

    var emoji: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        case .critical: return "🚨"
        }
    }
}

// MARK: - 日志管理器
class LogManager {
    static let shared = LogManager()

    /// 日志文件保留天数
    private let retentionDays = 7

    /// 日志目录
    private lazy var logDirectory: URL = {
        let realHomeDirectory = URL(fileURLWithPath: "/Users/\(NSUserName())")
        let logDir =
            realHomeDirectory
            .appendingPathComponent("会议录音 Pro")
            .appendingPathComponent(".日志")

        // 确保目录存在
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        return logDir
    }()

    /// 当前日志文件路径
    private var currentLogFile: URL {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let fileName = "MeetingRecorderPro_\(dateFormatter.string(from: Date())).log"
        return logDirectory.appendingPathComponent(fileName)
    }

    /// 文件写入句柄
    private var fileHandle: FileHandle?

    /// 当前打开的日志文件日期
    private var currentFileDate: String = ""

    /// 写入队列（串行，确保线程安全）
    private let writeQueue = DispatchQueue(label: "com.meetingrecorderpro.log", qos: .utility)

    /// 时间戳格式化器
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private init() {
        // 启动时清理旧日志
        cleanupOldLogs()

        // 记录启动日志
        log(.info, "日志系统初始化完成 | 日志目录: \(logDirectory.path)")
    }

    deinit {
        fileHandle?.closeFile()
    }

    // MARK: - 公开接口

    /// 记录日志
    func log(
        _ level: LogLevel, _ message: String, file: String = #file, function: String = #function,
        line: Int = #line
    ) {
        let now = Date()
        let fileName = (file as NSString).lastPathComponent

        // 异步处理所有逻辑，避免阻塞调用者线程（特别是音频回调线程）
        writeQueue.async { [weak self] in
            guard let self = self else { return }
            let timestamp = self.timestampFormatter.string(from: now)

            // 格式：[时间戳] [级别] 消息 | 文件:行号
            let logLine = "[\(timestamp)] [\(level.rawValue)] \(message) | \(fileName):\(line)\n"

            // 仅在 DEBUG 模式下输出到控制台
            #if DEBUG
                print("\(level.emoji) \(logLine)", terminator: "")
            #endif

            self.writeToFile(logLine)
        }
    }

    /// 记录调试信息
    func debug(
        _ message: String, file: String = #file, function: String = #function, line: Int = #line
    ) {
        log(.debug, message, file: file, function: function, line: line)
    }

    /// 记录普通信息
    func info(
        _ message: String, file: String = #file, function: String = #function, line: Int = #line
    ) {
        log(.info, message, file: file, function: function, line: line)
    }

    /// 记录警告
    func warning(
        _ message: String, file: String = #file, function: String = #function, line: Int = #line
    ) {
        log(.warning, message, file: file, function: function, line: line)
    }

    /// 记录错误
    func error(
        _ message: String, file: String = #file, function: String = #function, line: Int = #line
    ) {
        log(.error, message, file: file, function: function, line: line)
    }

    /// 记录严重错误
    func critical(
        _ message: String, file: String = #file, function: String = #function, line: Int = #line
    ) {
        log(.critical, message, file: file, function: function, line: line)
    }

    /// 获取日志目录路径
    func getLogDirectory() -> URL {
        return logDirectory
    }

    // MARK: - 私有方法

    /// 写入文件
    private func writeToFile(_ content: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        // 如果日期变了，重新打开文件
        if today != currentFileDate {
            fileHandle?.closeFile()
            fileHandle = nil
            currentFileDate = today
        }

        // 确保文件句柄可用
        if fileHandle == nil {
            let filePath = currentLogFile.path

            // 如果文件不存在则创建
            if !FileManager.default.fileExists(atPath: filePath) {
                FileManager.default.createFile(atPath: filePath, contents: nil)
            }

            fileHandle = FileHandle(forWritingAtPath: filePath)
            fileHandle?.seekToEndOfFile()
        }

        // 写入（不再调用 synchronizeFile，避免阻塞 IO）
        // 系统会自动在适当时机刷新缓冲区
        if let data = content.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    /// 清理旧日志文件
    private func cleanupOldLogs() {
        let fileManager = FileManager.default

        guard
            let files = try? fileManager.contentsOfDirectory(
                at: logDirectory, includingPropertiesForKeys: [.creationDateKey])
        else {
            return
        }

        let calendar = Calendar.current
        let cutoffDate = calendar.date(byAdding: .day, value: -retentionDays, to: Date())!

        for file in files {
            guard file.pathExtension == "log" else { continue }

            if let attributes = try? fileManager.attributesOfItem(atPath: file.path),
                let creationDate = attributes[.creationDate] as? Date,
                creationDate < cutoffDate
            {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
