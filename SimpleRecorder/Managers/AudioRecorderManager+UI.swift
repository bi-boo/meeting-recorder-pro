//
//  AudioRecorderManager+UI.swift
//  极简录音 - 用户交互层
//
//  职责范围：
//  - 6 种 NSAlert 弹窗（权限、磁盘、目录、引擎、限时、错误）
//  - 磁盘空间检查
//  - 目录写入权限检查
//  - 录音中断的统一处理 + 用户提醒
//  - 时间格式化（时长展示）
//

import AVFoundation
import AppKit
import Foundation

extension AudioRecorderManager {

    // MARK: - 磁盘 & 权限检查

    func checkDiskSpace(at url: URL) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey
            ])
            if let space = values.volumeAvailableCapacityForImportantUsage {
                let spaceMB = Double(space) / (1024 * 1024)
                let isEnough = space >= minimumDiskSpace
                if !isEnough {
                    LogManager.shared.warning(
                        "磁盘空间不足 | 可用: \(String(format: "%.1f", spaceMB))MB, 最小要求: 100MB")
                }
                return isEnough
            }
        } catch {
            LogManager.shared.warning("磁盘空间检查失败 | 错误: \(error.localizedDescription)")
            return true
        }
        return true
    }

    /// 检查目录是否可写（公开方法，用于启动时预检）
    func checkDirectoryWritable(at url: URL) -> Bool {
        let path = url.path
        if FileManager.default.fileExists(atPath: path) {
            return FileManager.default.isWritableFile(atPath: path)
        }
        return FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }

    /// 检查录音目录权限（供应用启动时调用）
    /// - Returns: true 如果目录可写，false 如果不可写（会弹出提示）
    func checkRecordingDirectoryPermission() -> Bool {
        let recordingsPath = AppSettings.shared.recordingsPath
        if !checkDirectoryWritable(at: recordingsPath) {
            showDirectoryPermissionAlert()
            return false
        }
        return true
    }

    func checkTimeWarning() {
        // 已根据用户需求移除提前预警逻辑
    }

    // MARK: - UI Alerts

    func showRecordingLimitReachedAlert(duration: TimeInterval) {
        // 【关键修复】使用非阻塞式通知，避免阻塞主线程，确保后续定时任务能正常触发
        DispatchQueue.main.async { [weak self] in
            self?.notificationController.showRecordingCompletedNotification(duration: duration)
        }
    }

    func showTimeWarningNotification() {
        // 已根据用户需求移除提前预警弹窗
    }

    func showMicrophonePermissionAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "麦克风访问受限"
            alert.informativeText =
                "检测到由于重新构建或签名变更，系统可能未能正确识别本应用的权限。\n\n解决办法：\n1. 请在“系统设置 - 隐私与安全性 - 麦克风”中，手动将“极简录音”的任务开关先关闭再重新开启。\n2. 若列表中没有本应用，请在终端执行 'tccutil reset Microphone com.simplerecorder.app' 后重新运行。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打开设置")
            alert.addButton(withTitle: "我知道了")
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                ) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    func showDiskSpaceAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "磁盘空间不足"
            alert.informativeText = "请至少保留 100MB 可用空间。"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "确定")
            alert.runModal()
        }
    }

    func showDirectoryPermissionAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "目录权限不足"
            alert.informativeText = "当前录音目录不可写，请在设置中更换或修改权限。"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "打开设置")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
            }
        }
    }

    func showRecordingErrorAlert(message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "录音启动失败"
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.addButton(withTitle: "确定")
            alert.runModal()
        }
    }

    func showAudioEngineResumeFailedAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "继续录音失败"
            alert.informativeText = "音频引擎无法恢复。请停止当前录音并重新开始。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "知道了")
            alert.runModal()
        }
    }

    // MARK: - 录音中断处理

    /// 统一的录音中断处理方法
    /// - Parameter reason: 中断原因
    func handleRecordingInterruption(reason: RecordingInterruptionReason) {
        // 防止重复处理
        guard !isHandlingInterruption else {
            LogManager.shared.warning("中断处理正在进行中，忽略重复调用")
            return
        }
        guard isRecording else {
            LogManager.shared.info("非录音状态，忽略中断处理")
            return
        }

        isHandlingInterruption = true
        LogManager.shared.error("录音中断 | 原因: \(reason.localizedDescription)")

        // 紧急保存，完成后再弹提醒（避免在写入未完成时就弹窗）
        saveRecordingImmediately { [weak self] in
            self?.showRecordingInterruptionAlert(reason: reason)
            self?.isHandlingInterruption = false
        }
    }

    /// 显示录音中断提醒弹窗
    /// - Parameter reason: 中断原因
    func showRecordingInterruptionAlert(reason: RecordingInterruptionReason) {
        // 【关键修复】使用非阻塞式通知，避免阻塞主线程，确保后续定时任务能正常触发
        notificationController.showRecordingInterruptedNotification(
            reason: reason.localizedDescription,
            onRestart: { [weak self] in
                guard let self = self else { return }
                LogManager.shared.info("用户选择重新开始录音")
                // 再次确认状态已重置
                if self.recordingState == .idle {
                    self.startRecording()
                } else {
                    LogManager.shared.warning(
                        "状态未完全重置，无法重新录音 | 当前状态: \(self.recordingState)"
                    )
                }
            }
        )
    }

    // MARK: - 时长格式化

    func formatDuration(_ duration: TimeInterval) -> String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
