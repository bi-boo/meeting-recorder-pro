//
//  AudioRecorderManager.swift
//  极简录音 - 录音管理器
//

import Foundation
import AVFoundation
import AppKit

class AudioRecorderManager: NSObject, ObservableObject {
    static let shared = AudioRecorderManager()
    
    @Published var isRecording = false
    @Published var currentRecordingURL: URL?
    @Published var recordingDuration: TimeInterval = 0
    
    private var audioRecorder: AVAudioRecorder?
    private var recordingTimer: Timer?
    
    // 时间提醒相关
    private let maxDuration: TimeInterval = 5 * 60 * 60  // 5 小时
    private let warningStartTime: TimeInterval = 4 * 60 * 60  // 4 小时开始提醒
    private let warningInterval: TimeInterval = 10 * 60  // 每 10 分钟提醒
    private var lastWarningTime: TimeInterval = 0
    
    // 最小磁盘空间要求（500MB）
    private let minimumDiskSpace: Int64 = 500 * 1024 * 1024
    
    // 分段录音相关
    private let segmentDuration: TimeInterval = 60  // 每 60 秒一个片段
    private var tempSegmentDirectory: URL?  // 隐藏的临时目录 (.recording_temp)
    private var segmentURLs: [URL] = []  // 所有片段的路径
    private var currentSegmentIndex: Int = 0
    private var segmentStartTime: TimeInterval = 0  // 当前片段的开始时间
    private var finalRecordingURL: URL?  // 最终合并后的文件路径
    
    // 崩溃恢复相关的 UserDefaults 键
    private let recordingInProgressKey = "recording_in_progress"
    private let recordingFilePathKey = "recording_file_path"
    private let recordingStartTimeKey = "recording_start_time"
    private let tempDirectoryPathKey = "recording_temp_directory"
    
    private override init() {
        super.init()
    }
    
    // MARK: - 崩溃恢复检测
    /// 应用启动时调用，检查是否有上次崩溃遗留的录音片段并自动合并
    func checkForCrashedRecording() {
        print("🔍 检查崩溃恢复状态...")
        
        let inProgress = UserDefaults.standard.bool(forKey: recordingInProgressKey)
        let tempDirPath = UserDefaults.standard.string(forKey: tempDirectoryPathKey)
        let finalFilePath = UserDefaults.standard.string(forKey: recordingFilePathKey)
        
        print("📋 录音进行中标记: \(inProgress)")
        print("📋 临时目录路径: \(tempDirPath ?? "无")")
        print("📋 最终文件路径: \(finalFilePath ?? "无")")
        
        // 清除崩溃标记
        clearRecordingState()
        
        guard inProgress, let tempDirPath = tempDirPath, let finalFilePath = finalFilePath else {
            // 即使没有标记，也检查是否有遗留的临时目录
            cleanupOrphanedTempDirectories()
            print("✅ 无需恢复")
            return
        }
        
        let tempDirURL = URL(fileURLWithPath: tempDirPath)
        let finalFileURL = URL(fileURLWithPath: finalFilePath)
        
        // 检查临时目录是否存在
        guard FileManager.default.fileExists(atPath: tempDirPath) else {
            print("⚠️ 崩溃恢复：临时目录不存在")
            return
        }
        
        // 获取所有片段文件
        let segments = getSegmentFiles(in: tempDirURL)
        
        if segments.isEmpty {
            print("⚠️ 崩溃恢复：没有找到任何片段文件")
            cleanupTempDirectory(tempDirURL)
            return
        }
        
        print("📁 发现 \(segments.count) 个遗留录音片段，开始自动合并...")
        
        // 自动合并片段
        DispatchQueue.global(qos: .userInitiated).async {
            let success = self.mergeSegments(segments, to: finalFileURL)
            
            DispatchQueue.main.async {
                if success {
                    print("✅ 崩溃恢复成功：已合并 \(segments.count) 个片段到 \(finalFileURL.lastPathComponent)")
                    // 清理临时目录
                    self.cleanupTempDirectory(tempDirURL)
                    // 发送通知刷新列表
                    NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
                } else {
                    print("❌ 崩溃恢复失败：无法合并片段")
                    // 保留临时目录供手动处理
                }
            }
        }
    }
    
    /// 清理孤立的临时目录（没有对应标记的）
    private func cleanupOrphanedTempDirectories() {
        let recordingsPath = AppSettings.shared.recordingsPath
        let tempDirName = ".recording_temp"
        let tempDirURL = recordingsPath.appendingPathComponent(tempDirName)
        
        if FileManager.default.fileExists(atPath: tempDirURL.path) {
            // 检查是否有片段文件
            let segments = getSegmentFiles(in: tempDirURL)
            if segments.isEmpty {
                cleanupTempDirectory(tempDirURL)
            } else {
                print("⚠️ 发现孤立的临时目录，包含 \(segments.count) 个片段，尝试恢复...")
                // 使用时间戳生成恢复文件名
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd_HH:mm"
                let fileName = "录音_恢复_\(dateFormatter.string(from: Date())).m4a"
                let recoveredURL = recordingsPath.appendingPathComponent(fileName)
                
                DispatchQueue.global(qos: .userInitiated).async {
                    let success = self.mergeSegments(segments, to: recoveredURL)
                    DispatchQueue.main.async {
                        if success {
                            print("✅ 孤立片段恢复成功")
                            self.cleanupTempDirectory(tempDirURL)
                            NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - 片段管理辅助方法
    
    /// 获取临时目录中的所有片段文件，按名称排序
    private func getSegmentFiles(in directory: URL) -> [URL] {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            
            // 筛选 m4a 文件并按名称排序
            let segments = contents
                .filter { $0.pathExtension.lowercased() == "m4a" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            
            // 过滤掉太小的文件（可能是损坏的最后一个片段）
            let validSegments = segments.filter { url in
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? Int64 {
                    return size > 1024  // 大于 1KB
                }
                return false
            }
            
            return validSegments
        } catch {
            print("❌ 无法读取临时目录: \(error.localizedDescription)")
            return []
        }
    }
    
    /// 使用 ffmpeg 合并多个音频片段
    private func mergeSegments(_ segments: [URL], to outputURL: URL) -> Bool {
        guard !segments.isEmpty else { return false }
        
        // 如果只有一个片段，直接复制
        if segments.count == 1 {
            do {
                // 如果目标文件已存在，先删除
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    try FileManager.default.removeItem(at: outputURL)
                }
                try FileManager.default.copyItem(at: segments[0], to: outputURL)
                return true
            } catch {
                print("❌ 复制片段失败: \(error.localizedDescription)")
                return false
            }
        }
        
        // 查找 ffmpeg
        let ffmpegPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        var ffmpegPath: String? = nil
        for path in ffmpegPaths {
            if FileManager.default.fileExists(atPath: path) {
                ffmpegPath = path
                break
            }
        }
        
        guard let ffmpeg = ffmpegPath else {
            print("❌ 未找到 ffmpeg，无法合并片段")
            return false
        }
        
        // 创建 concat 列表文件
        let tempDir = segments[0].deletingLastPathComponent()
        let listFileURL = tempDir.appendingPathComponent("concat_list.txt")
        
        var listContent = ""
        for segment in segments {
            // ffmpeg concat 需要转义单引号
            let escapedPath = segment.path.replacingOccurrences(of: "'", with: "'\\''")
            listContent += "file '\(escapedPath)'\n"
        }
        
        do {
            try listContent.write(to: listFileURL, atomically: true, encoding: .utf8)
        } catch {
            print("❌ 无法创建 concat 列表文件: \(error.localizedDescription)")
            return false
        }
        
        print("🔧 使用 ffmpeg 合并 \(segments.count) 个片段...")
        
        // 使用 ffmpeg concat demuxer 合并（不需要重新编码）
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-f", "concat",
            "-safe", "0",
            "-i", listFileURL.path,
            "-c", "copy",
            "-y",
            outputURL.path
        ]
        
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            // 删除列表文件
            try? FileManager.default.removeItem(at: listFileURL)
            
            if process.terminationStatus == 0 {
                print("✅ 片段合并成功: \(outputURL.lastPathComponent)")
                return true
            } else {
                let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "未知错误"
                print("❌ ffmpeg 合并失败: \(errorMessage)")
                return false
            }
        } catch {
            print("❌ 无法运行 ffmpeg: \(error.localizedDescription)")
            return false
        }
    }
    
    /// 清理临时目录
    private func cleanupTempDirectory(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
            print("🧹 已清理临时目录: \(directory.lastPathComponent)")
        } catch {
            print("⚠️ 清理临时目录失败: \(error.localizedDescription)")
        }
    }
    
    // MARK: - 录音状态持久化
    private func saveRecordingState(tempDir: String, finalFile: String) {
        print("💾 保存录音状态...")
        UserDefaults.standard.set(true, forKey: recordingInProgressKey)
        UserDefaults.standard.set(tempDir, forKey: tempDirectoryPathKey)
        UserDefaults.standard.set(finalFile, forKey: recordingFilePathKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: recordingStartTimeKey)
        UserDefaults.standard.synchronize()
        print("✅ 录音状态已保存")
    }
    
    private func clearRecordingState() {
        print("🧹 清除录音状态")
        UserDefaults.standard.set(false, forKey: recordingInProgressKey)
        UserDefaults.standard.removeObject(forKey: tempDirectoryPathKey)
        UserDefaults.standard.removeObject(forKey: recordingFilePathKey)
        UserDefaults.standard.removeObject(forKey: recordingStartTimeKey)
        UserDefaults.standard.synchronize()
        print("✅ 录音状态已清除")
    }
    
    // MARK: - Recording Control
    func startRecording() {
        // 检查麦克风权限
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async {
                        self?.beginRecording()
                    }
                }
            }
        case .denied, .restricted:
            print("麦克风权限被拒绝")
            showMicrophonePermissionAlert()
        @unknown default:
            break
        }
    }
    
    private func beginRecording() {
        let recordingsPath = AppSettings.shared.recordingsPath
        
        // 检查磁盘空间
        if !checkDiskSpace(at: recordingsPath) {
            showDiskSpaceAlert()
            return
        }
        
        // 检查目录可写性
        if !checkDirectoryWritable(at: recordingsPath) {
            showDirectoryPermissionAlert()
            return
        }
        
        // 确保录音目录存在
        do {
            try FileManager.default.createDirectory(at: recordingsPath, withIntermediateDirectories: true)
        } catch {
            print("创建录音目录失败: \(error.localizedDescription)")
            showDirectoryPermissionAlert()
            return
        }
        
        // 创建隐藏的临时目录
        let tempDirName = ".recording_temp"
        let tempDir = recordingsPath.appendingPathComponent(tempDirName)
        
        do {
            // 如果临时目录已存在，先清理
            if FileManager.default.fileExists(atPath: tempDir.path) {
                try FileManager.default.removeItem(at: tempDir)
            }
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            print("创建临时目录失败: \(error.localizedDescription)")
            showDirectoryPermissionAlert()
            return
        }
        
        tempSegmentDirectory = tempDir
        segmentURLs = []
        currentSegmentIndex = 0
        
        // 生成最终文件名（精确到分钟）
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH:mm"
        let fileName = "录音_\(dateFormatter.string(from: Date())).m4a"
        let finalFileURL = recordingsPath.appendingPathComponent(fileName)
        finalRecordingURL = finalFileURL
        
        // 保存录音状态（用于崩溃恢复）
        saveRecordingState(tempDir: tempDir.path, finalFile: finalFileURL.path)
        
        // 开始第一个片段的录音
        if !startNewSegment() {
            return
        }
        
        isRecording = true
        recordingDuration = 0
        lastWarningTime = 0
        segmentStartTime = 0
        
        // 开始计时
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.recordingDuration += 1
            
            // 检查是否需要切换片段
            let timeInCurrentSegment = self.recordingDuration - self.segmentStartTime
            if timeInCurrentSegment >= self.segmentDuration {
                self.rotateSegment()
            }
            
            // 检查时间提醒
            self.checkTimeWarning()
            
            // 超过 5 小时自动停止
            if self.recordingDuration >= self.maxDuration {
                print("⏱️ 录音已达 5 小时上限，自动保存")
                self.showMaxDurationAlert()
                self.stopRecording()
            }
        }
        
        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
        print("🎙️ 开始分段录音，临时目录: \(tempDir.path)")
    }
    
    /// 开始一个新的录音片段
    private func startNewSegment() -> Bool {
        guard let tempDir = tempSegmentDirectory else { return false }
        
        let segmentFileName = String(format: "segment_%04d.m4a", currentSegmentIndex)
        let segmentURL = tempDir.appendingPathComponent(segmentFileName)
        
        // 录音设置
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: segmentURL, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()
            
            segmentURLs.append(segmentURL)
            currentRecordingURL = segmentURL
            
            print("📼 开始录制片段 \(currentSegmentIndex): \(segmentFileName)")
            return true
            
        } catch {
            print("❌ 录音片段启动失败: \(error.localizedDescription)")
            showRecordingErrorAlert(message: error.localizedDescription)
            return false
        }
    }
    
    /// 切换到新的录音片段
    private func rotateSegment() {
        print("🔄 切换录音片段...")
        
        // 停止当前片段
        audioRecorder?.stop()
        audioRecorder = nil
        
        // 更新片段索引和时间
        currentSegmentIndex += 1
        segmentStartTime = recordingDuration
        
        // 开始新片段
        if !startNewSegment() {
            // 如果新片段启动失败，尝试停止录音并合并已有片段
            print("⚠️ 新片段启动失败，尝试保存已有录音...")
            stopRecording()
        }
    }
    
    func stopRecording() {
        // 停止当前片段
        audioRecorder?.stop()
        audioRecorder = nil
        
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        isRecording = false
        lastWarningTime = 0
        
        print("⏹️ 停止录音，开始合并 \(segmentURLs.count) 个片段...")
        
        // 合并所有片段
        guard let finalURL = finalRecordingURL, let tempDir = tempSegmentDirectory else {
            clearRecordingState()
            currentRecordingURL = nil
            return
        }
        
        // 获取有效的片段（排除可能损坏的最后一个未完成片段）
        let validSegments = getSegmentFiles(in: tempDir)
        
        if validSegments.isEmpty {
            print("⚠️ 没有有效的录音片段")
            cleanupTempDirectory(tempDir)
            clearRecordingState()
            currentRecordingURL = nil
            NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
            return
        }
        
        // 合并片段
        let success = mergeSegments(validSegments, to: finalURL)
        
        if success {
            print("✅ 录音已保存: \(finalURL.path)")
            // 清理临时目录
            cleanupTempDirectory(tempDir)
            // 打开录音文件所在文件夹并选中文件
            NSWorkspace.shared.activateFileViewerSelecting([finalURL])
        } else {
            print("❌ 合并失败，保留临时文件")
            // 合并失败时保留临时目录供手动处理
        }
        
        // 清除录音状态
        clearRecordingState()
        
        // 重置状态
        segmentURLs = []
        currentSegmentIndex = 0
        tempSegmentDirectory = nil
        finalRecordingURL = nil
        currentRecordingURL = nil
        
        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
    }
    
    /// 立即保存当前录音（供退出时调用），不打开 Finder
    func saveRecordingImmediately() {
        guard isRecording else { return }
        
        // 停止当前片段
        audioRecorder?.stop()
        audioRecorder = nil
        
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        isRecording = false
        lastWarningTime = 0
        
        print("🚨 紧急保存录音，合并 \(segmentURLs.count) 个片段...")
        
        // 合并所有片段
        if let finalURL = finalRecordingURL, let tempDir = tempSegmentDirectory {
            let validSegments = getSegmentFiles(in: tempDir)
            
            if !validSegments.isEmpty {
                let success = mergeSegments(validSegments, to: finalURL)
                if success {
                    print("✅ 录音已紧急保存: \(finalURL.path)")
                    cleanupTempDirectory(tempDir)
                } else {
                    print("⚠️ 紧急保存时合并失败，保留临时文件")
                }
            }
        }
        
        // 清除录音状态
        clearRecordingState()
        
        // 重置状态
        segmentURLs = []
        currentSegmentIndex = 0
        tempSegmentDirectory = nil
        finalRecordingURL = nil
        currentRecordingURL = nil
    }
    
    // MARK: - Disk Space Check
    private func checkDiskSpace(at url: URL) -> Bool {
        do {
            let resourceValues = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let availableSpace = resourceValues.volumeAvailableCapacityForImportantUsage {
                return availableSpace >= minimumDiskSpace
            }
            // 如果无法获取，尝试获取父目录
            let parentURL = url.deletingLastPathComponent()
            let parentValues = try parentURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let availableSpace = parentValues.volumeAvailableCapacityForImportantUsage {
                return availableSpace >= minimumDiskSpace
            }
        } catch {
            print("无法检查磁盘空间: \(error.localizedDescription)")
        }
        // 无法检查时默认允许
        return true
    }
    
    // MARK: - Directory Permission Check
    private func checkDirectoryWritable(at url: URL) -> Bool {
        // 如果目录已存在，检查是否可写
        if FileManager.default.fileExists(atPath: url.path) {
            return FileManager.default.isWritableFile(atPath: url.path)
        }
        // 如果目录不存在，检查父目录是否可写
        let parentURL = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parentURL.path) {
            return FileManager.default.isWritableFile(atPath: parentURL.path)
        }
        // 继续往上找
        let grandParentURL = parentURL.deletingLastPathComponent()
        return FileManager.default.isWritableFile(atPath: grandParentURL.path)
    }
    
    // MARK: - Time Warning
    private func checkTimeWarning() {
        guard recordingDuration >= warningStartTime else { return }
        
        // 计算距离上次提醒的时间
        let timeSinceLastWarning = recordingDuration - lastWarningTime
        
        // 刚到 4 小时，或者距离上次提醒已过 10 分钟
        if lastWarningTime == 0 || timeSinceLastWarning >= warningInterval {
            lastWarningTime = recordingDuration
            showTimeWarningNotification()
        }
    }
    
    private func showTimeWarningNotification() {
        let remainingMinutes = Int((maxDuration - recordingDuration) / 60)
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "录音时间提醒"
            alert.informativeText = "当前录音已超过 4 小时，距离 5 小时上限还剩 \(remainingMinutes) 分钟。\n\n到达上限后将自动保存。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "知道了")
            alert.runModal()
        }
    }
    
    // MARK: - Alerts
    private func showMicrophonePermissionAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "需要麦克风权限"
            alert.informativeText = "请在系统设置中允许极简录音访问麦克风"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "取消")
            
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
    
    private func showDiskSpaceAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "磁盘空间不足"
            alert.informativeText = "录音需要至少 500MB 可用空间，请清理磁盘后重试。"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "确定")
            alert.runModal()
        }
    }
    
    private func showDirectoryPermissionAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "无法写入录音目录"
            alert.informativeText = "录音目录不可写，请检查目录权限或在设置中更换录音存储路径。"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "打开设置")
            alert.addButton(withTitle: "取消")
            
            if alert.runModal() == .alertFirstButtonReturn {
                // 发送通知打开设置窗口
                NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
            }
        }
    }
    
    private func showRecordingErrorAlert(message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "录音启动失败"
            alert.informativeText = "错误信息：\(message)"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "确定")
            alert.runModal()
        }
    }
    
    private func showMaxDurationAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "录音已自动保存"
            alert.informativeText = "录音已达到 5 小时上限，已自动保存。如需继续录音，请重新开始。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "确定")
            alert.runModal()
        }
    }
    
    // MARK: - Helpers
    func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - AVAudioRecorderDelegate
extension AudioRecorderManager: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("录音未成功完成")
        }
    }
    
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            print("录音编码错误: \(error.localizedDescription)")
        }
    }
}
