//
//  AudioRecorderManagerUI.swift
//  会议录音 Pro - 用户交互层
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
                        "磁盘空间不足 | 可用: \(String(format: "%.1f", spaceMB))MB, 最小要求: \(minimumDiskSpaceText)")
                }
                return isEnough
            }
        } catch {
            LogManager.shared.warning("磁盘空间检查失败 | 错误: \(error.localizedDescription)")
            return true
        }
        return true
    }

    var minimumDiskSpaceText: String {
        let mb = Double(minimumDiskSpace) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.1fGB", mb / 1024)
        }
        return "\(Int(ceil(mb)))MB"
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
                "检测到由于重新构建或签名变更，系统可能未能正确识别本应用的权限。\n\n解决办法：\n1. 请在“系统设置 - 隐私与安全性 - 麦克风”中，手动将“会议录音 Pro”的开关先关闭再重新开启。\n2. 若列表中没有本应用，请在终端执行 'tccutil reset Microphone com.meetingrecorderpro.app' 后重新运行。"
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
            alert.informativeText = "请至少保留 \(self.minimumDiskSpaceText) 可用空间。"
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

    /// 录音没有开始时用右上角非阻塞通知告知原因，不用模态框卡住主线程。
    func showRecordingStartFailedNotification(message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.notificationController.showRecordingStartFailedNotification(message: message)
        }
    }

    func showRecordingSaveFailedAlert(message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "录音文件保存失败"
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.addButton(withTitle: "知道了")
            alert.runModal()
        }
    }

    func showMP3ConversionFailedAlert(m4aURL: URL) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "MP3 转换失败"
            alert.informativeText =
                "录音没有丢失，已保留为可播放的 M4A 文件：\n\(m4aURL.lastPathComponent)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "知道了")
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

    /// 统一的录音中断处理：保存当前段，然后自动开始新一段录音。
    /// 用户主动停止（含到达时长上限）不经过这里，所以不会被自动续录。
    /// - Parameter reason: 中断原因
    func handleRecordingInterruption(reason: RecordingInterruptionReason) {
        // 防止重复处理
        guard !isHandlingInterruption else {
            LogManager.shared.warning("中断处理正在进行中，忽略重复调用")
            return
        }
        // 正在停止说明用户已经主动结束，这时的设备或引擎变化不需要保存，也不能续录。
        guard recordingState == .recording || recordingState == .paused else {
            LogManager.shared.info("非录音状态，忽略中断处理 | 当前状态: \(recordingState)")
            return
        }

        isHandlingInterruption = true
        LogManager.shared.error("录音中断 | 原因: \(reason.localizedDescription) | 保存后将自动开始新一段录音")

        saveInterruptedRecording { [weak self] in
            guard let self = self else { return }
            self.isHandlingInterruption = false
            self.scheduleAutomaticRestart(after: reason, attempt: 1)
        }
    }

    /// 中断保存完成后按策略延迟重启录音。设备路由刚变化时立即启动容易再次失败，
    /// 所以先等待，再逐次拉长间隔；用尽次数后回退为需要用户点击的中断提示。
    func scheduleAutomaticRestart(after reason: RecordingInterruptionReason, attempt: Int) {
        pendingAutomaticRestartWorkItem?.cancel()
        automaticRestartGeneration += 1
        let generation = automaticRestartGeneration

        guard let delay = RecordingAutomaticRestartPolicy.delay(forAttempt: attempt) else {
            LogManager.shared.error(
                "自动续录多次失败，等待用户手动重新开始 | 原因: \(reason.localizedDescription)")
            showRecordingInterruptionAlert(reason: reason)
            return
        }

        LogManager.shared.info(
            "将在 \(Int(delay)) 秒后自动开始新一段录音 | 第 \(attempt) 次尝试")
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.automaticRestartGeneration == generation else { return }
            self.pendingAutomaticRestartWorkItem = nil

            guard self.recordingState == .idle, !self.isRecoveringInterruptedRecording else {
                LogManager.shared.info(
                    "自动续录已取消，录音状态已被其他操作改变 | 当前状态: \(self.recordingState)")
                return
            }
            guard self.startRecording() else {
                LogManager.shared.warning("自动续录启动请求被拒绝 | 第 \(attempt) 次尝试")
                self.scheduleAutomaticRestart(after: reason, attempt: attempt + 1)
                return
            }
            self.confirmAutomaticRestart(
                after: reason,
                attempt: attempt,
                generation: generation,
                remainingAttempts: TimerRecordingStartConfirmationPolicy.maxAttempts
            )
        }
        pendingAutomaticRestartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// 启动是异步的（权限、系统声音、稳定门禁），只有真正进入 recording 才算续录成功。
    private func confirmAutomaticRestart(
        after reason: RecordingInterruptionReason,
        attempt: Int,
        generation: Int,
        remainingAttempts: Int
    ) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + TimerRecordingStartConfirmationPolicy.retryInterval
        ) { [weak self] in
            guard let self = self, self.automaticRestartGeneration == generation else { return }

            let observation: TimerRecordingStartObservation
            switch self.recordingState {
            case .idle: observation = .idle
            case .starting: observation = .starting
            case .recording, .paused, .stopping: observation = .recording
            }

            switch TimerRecordingStartConfirmationPolicy.decision(
                for: observation, remainingAttempts: remainingAttempts
            ) {
            case .confirmed:
                LogManager.shared.info("中断后已自动开始新一段录音 | 原因: \(reason.localizedDescription)")
                self.notificationController.showRecordingRestartedNotification(
                    reason: reason.localizedDescription,
                    onStop: { [weak self] in
                        LogManager.shared.info("用户在自动续录提示中选择停止录音")
                        self?.stopRecording()
                    }
                )
            case .wait:
                self.confirmAutomaticRestart(
                    after: reason,
                    attempt: attempt,
                    generation: generation,
                    remainingAttempts: remainingAttempts - 1
                )
            case .failed:
                LogManager.shared.warning("自动续录未能进入录音状态 | 第 \(attempt) 次尝试")
                self.scheduleAutomaticRestart(after: reason, attempt: attempt + 1)
            }
        }
    }

    /// 退出应用或用户主动保存时调用，让仍在等待的自动续录失效。
    func cancelPendingAutomaticRestart() {
        automaticRestartGeneration += 1
        pendingAutomaticRestartWorkItem?.cancel()
        pendingAutomaticRestartWorkItem = nil
    }

    /// 自动续录用尽次数后，显示需要用户点击的中断提示
    /// - Parameter reason: 中断原因
    func showRecordingInterruptionAlert(reason: RecordingInterruptionReason) {
        // 非阻塞式通知，避免阻塞主线程，确保后续定时任务能正常触发
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
