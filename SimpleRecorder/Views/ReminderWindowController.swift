//
//  ReminderWindowController.swift
//  会议录音 Pro - 定时提醒弹窗控制器
//
//  Created by AI Assistant
//

import AppKit
import SwiftUI

// MARK: - 提醒弹窗控制器

/// 定时录音提醒弹窗控制器
class ReminderWindowController: NSObject {
    private struct PendingTimerReminder {
        let task: TimerTask
        let occurrence: TimerTaskOccurrence
        let onIgnore: () -> Void
        let onStartRecording: () -> Void
    }

    private var reminderWindow: NSWindow?
    private var onIgnoreCallback: (() -> Void)?
    private var onStartRecordingCallback: (() -> Void)?
    private var isTimerReminderActive = false
    private var activeTimerReminderOccurrence: TimerTaskOccurrence?
    private var pendingTimerReminders: [PendingTimerReminder] = []

    /// 显示提醒弹窗
    func showReminder(
        for task: TimerTask,
        onIgnore: @escaping () -> Void,
        onStartRecording: @escaping () -> Void
    ) {
        guard let occurrence = TimerTaskOccurrence(task: task) else {
            LogManager.shared.warning("定时提醒缺少计划时间，已跳过 | ID: \(task.id)")
            return
        }
        guard activeTimerReminderOccurrence != occurrence,
            !pendingTimerReminders.contains(where: { $0.occurrence == occurrence })
        else {
            LogManager.shared.info("相同定时提醒已经显示或排队，忽略重复请求 | ID: \(task.id)")
            return
        }

        let pendingReminder = PendingTimerReminder(
            task: task,
            occurrence: occurrence,
            onIgnore: onIgnore,
            onStartRecording: onStartRecording
        )

        guard !isTimerReminderActive else {
            pendingTimerReminders.append(pendingReminder)
            LogManager.shared.info(
                "定时提醒正在显示，新任务已排队 | 任务: \(task.timeDisplay) | 队列: \(pendingTimerReminders.count)"
            )
            return
        }

        presentTimerReminder(pendingReminder)
    }

    private func presentTimerReminder(_ pendingReminder: PendingTimerReminder) {
        let task = pendingReminder.task
        dismissReminder()

        self.onIgnoreCallback = pendingReminder.onIgnore
        self.onStartRecordingCallback = pendingReminder.onStartRecording
        self.isTimerReminderActive = true
        self.activeTimerReminderOccurrence = pendingReminder.occurrence

        // 创建弹窗视图
        let reminderView = ReminderView(
            task: task,
            onIgnore: { [weak self] in
                self?.handleIgnore()
            },
            onStartRecording: { [weak self] in
                self?.handleStartRecording()
            }
        )

        // 创建 NSWindow
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 165),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.contentView = NSHostingView(rootView: reminderView)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 定位到屏幕右上角
        positionWindowTopRight(window)

        // 显示弹窗（带动画）
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }

        self.reminderWindow = window

        // 【PRD 强制要求】按用户设置的提醒时间动态失效
        let timeoutSeconds = TimerReminderPresentationPolicy.timeout(for: task)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
            [weak self, weak window] in
            // 只有当窗口仍然是当前显示的那个窗口时才关闭
            if let self = self, self.reminderWindow === window {
                LogManager.shared.info("定时提醒弹窗到达预设提醒时间（\(task.reminderMinutes)min），自动失效")
                let callback = self.consumeTimerReminderIgnoreCallback()
                callback?()
                self.dismissReminder()
                self.showNextQueuedTimerReminder()
            }
        }

        LogManager.shared.info("显示定时提醒弹窗 | 任务: \(task.timeDisplay)")
    }

    /// 关闭弹窗
    func dismissReminder() {
        guard let window = reminderWindow else { return }

        // 【关键修复】在动画开始前立即清除引用
        // 防止动画期间新弹窗创建后，旧动画的 completionHandler 错误地清除新弹窗的引用
        reminderWindow = nil

        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            },
            completionHandler: {
                window.orderOut(nil)
            })
    }

    /// 定位窗口到右上角
    private func positionWindowTopRight(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let windowFrame = window.frame

        let x = screenFrame.maxX - windowFrame.width - 20
        let y = screenFrame.maxY - windowFrame.height - 20

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func handleIgnore() {
        let callback = consumeTimerReminderIgnoreCallback()
        callback?()
        dismissReminder()
        showNextQueuedTimerReminder()
    }

    private func handleStartRecording() {
        let callback = consumeTimerReminderStartCallback()
        callback?()
        dismissReminder()
        showNextQueuedTimerReminder()
    }

    /// 显示自动录音通知（5秒后自动消失）
    func showAutoStartNotification(for task: TimerTask) {
        guard !isTimerReminderActive else {
            LogManager.shared.info("定时提醒显示中，跳过非必要的自动录音通知 | 任务: \(task.timeDisplay)")
            return
        }
        dismissReminder()

        // 创建通知视图
        let notificationView = AutoStartNotificationView(task: task)

        // 创建 NSWindow
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 110),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.contentView = NSHostingView(rootView: notificationView)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 定位到屏幕右上角
        positionWindowTopRight(window)

        // 显示弹窗（带动画）
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }

        self.reminderWindow = window

        LogManager.shared.info("显示自动录音通知 | 任务: \(task.timeDisplay)")

        // 5秒后自动消失
        // 【修复】添加窗口实例检查，确保只关闭当前这个窗口，避免被后续弹窗干扰
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak window] in
            if let self = self, self.reminderWindow === window {
                self.dismissReminder()
            }
        }
    }

    /// 显示录音完成通知（非阻塞，10秒后自动消失）
    /// - Parameter duration: 录音时长（秒）
    func showRecordingCompletedNotification(duration: TimeInterval) {
        guard !isTimerReminderActive else {
            LogManager.shared.info("定时提醒显示中，跳过录音完成通知")
            return
        }
        dismissReminder()

        // 创建通知视图
        let notificationView = RecordingCompletedView(
            duration: duration,
            onDismiss: { [weak self] in
                self?.dismissReminder()
            })

        // 创建 NSWindow
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 150),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.contentView = NSHostingView(rootView: notificationView)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 定位到屏幕右上角
        positionWindowTopRight(window)

        // 显示弹窗（带动画）
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }

        self.reminderWindow = window

        let minutes = Int(duration / 60)
        let seconds = Int(duration) % 60
        LogManager.shared.info("显示录音完成通知（非阻塞）| 时长: \(minutes)分\(seconds)秒")

        // 10秒后自动消失
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak window] in
            if let self = self, self.reminderWindow === window {
                self.dismissReminder()
            }
        }
    }

    /// 显示录音中断通知（非阻塞，带重新录音按钮）
    /// - Parameters:
    ///   - reason: 中断原因描述
    ///   - onRestart: 用户点击"再次开始录音"时的回调
    func showRecordingInterruptedNotification(reason: String, onRestart: @escaping () -> Void) {
        guard !isTimerReminderActive else {
            LogManager.shared.info("定时提醒显示中，跳过录音中断通知 | 原因: \(reason)")
            return
        }

        // 记录回调
        self.onStartRecordingCallback = onRestart
        self.isTimerReminderActive = false

        // 如果已有弹窗，先关闭
        dismissReminder()

        // 创建通知视图
        let notificationView = RecordingInterruptedView(
            reason: reason,
            onRestart: { [weak self] in
                self?.dismissReminder()
                // 延迟 2 秒，等待系统音频路由完全稳定后再启动
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self?.onStartRecordingCallback?()
                    self?.onStartRecordingCallback = nil
                }
            },
            onDismiss: { [weak self] in
                self?.dismissReminder()
                self?.onStartRecordingCallback = nil
            }
        )

        // 创建 NSWindow
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 170),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.contentView = NSHostingView(rootView: notificationView)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 定位到屏幕右上角
        positionWindowTopRight(window)

        // 显示弹窗（带动画）
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }

        self.reminderWindow = window

        LogManager.shared.info("显示录音中断通知（非阻塞）| 原因: \(reason)")

        // 2分钟后自动消失（给用户足够时间决定）
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self, weak window] in
            if let self = self, self.reminderWindow === window {
                self.dismissReminder()
                self.onStartRecordingCallback = nil
            }
        }
    }

    private func showNextQueuedTimerReminder() {
        guard !isTimerReminderActive, !pendingTimerReminders.isEmpty else { return }
        let nextReminder = pendingTimerReminders.removeFirst()
        presentTimerReminder(nextReminder)
    }

    private func consumeTimerReminderIgnoreCallback() -> (() -> Void)? {
        guard isTimerReminderActive else { return nil }

        let callback = onIgnoreCallback
        onIgnoreCallback = nil
        onStartRecordingCallback = nil
        isTimerReminderActive = false
        activeTimerReminderOccurrence = nil
        return callback
    }

    private func consumeTimerReminderStartCallback() -> (() -> Void)? {
        guard isTimerReminderActive else { return nil }

        let callback = onStartRecordingCallback
        onIgnoreCallback = nil
        onStartRecordingCallback = nil
        isTimerReminderActive = false
        activeTimerReminderOccurrence = nil
        return callback
    }
}

// MARK: - 提醒弹窗视图

struct ReminderView: View {
    let task: TimerTask
    let onIgnore: () -> Void
    let onStartRecording: () -> Void

    private var ignoreButtonTitle: String {
        task.repeatType == .none ? "取消" : "跳过这次"
    }

    var body: some View {
        VStack(spacing: 10) {
            // 图标
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 24))
                .foregroundColor(.secondary)

            // 主标题
            Text("开始录音了吗？")
                .font(.system(size: 14, weight: .semibold))

            // 副标题 - 计划时间
            Text("定时计划：\(task.timeDisplay)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            // 按钮区域
            HStack(spacing: 12) {
                Button(action: onIgnore) {
                    Text(ignoreButtonTitle)
                        .frame(width: 80)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button(action: onStartRecording) {
                    Text("开始录音")
                        .frame(width: 90)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - 自动录音通知视图

struct AutoStartNotificationView: View {
    let task: TimerTask

    var body: some View {
        VStack(spacing: 10) {
            // 图标
            Image(systemName: "record.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(.green)

            // 主标题
            Text("录音已开始")
                .font(.system(size: 14, weight: .semibold))

            // 副标题 - 计划时间
            Text("定时计划 \(task.timeDisplay) 已触发")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - 录音完成通知视图（非阻塞）

struct RecordingCompletedView: View {
    let duration: TimeInterval
    let onDismiss: () -> Void

    private var durationText: String {
        let minutes = Int(duration / 60)
        let seconds = Int(duration) % 60
        return minutes > 0 ? "\(minutes) 分钟 \(seconds) 秒" : "\(seconds) 秒"
    }

    var body: some View {
        VStack(spacing: 10) {
            // 图标
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(.green)

            // 主标题
            Text("录音完成")
                .font(.system(size: 14, weight: .semibold))

            // 副标题 - 录音时长
            Text("录音时长：\(durationText)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            // 按钮区域
            HStack(spacing: 12) {
                Button(action: onDismiss) {
                    Text("知道了")
                        .frame(width: 80)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button(action: {
                    NSWorkspace.shared.open(AppSettings.shared.recordingsPath)
                    onDismiss()
                }) {
                    Text("在 Finder 中显示")
                        .frame(width: 100)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - 录音中断通知视图（非阻塞）

struct RecordingInterruptedView: View {
    let reason: String
    let onRestart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            // 图标
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundColor(.orange)

            // 主标题
            Text("录音已中断")
                .font(.system(size: 14, weight: .semibold))

            // 副标题 - 中断原因
            Text("已自动保存录音。原因：\(reason)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            // 按钮区域
            HStack(spacing: 12) {
                Button(action: onDismiss) {
                    Text("知道了")
                        .frame(width: 80)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button(action: onRestart) {
                    Text("再次录音")
                        .frame(width: 90)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - 预览

#if DEBUG
    struct ReminderView_Previews: PreviewProvider {
        static var previews: some View {
            ReminderView(
                task: TimerTask(
                    enabled: true,
                    daysOfWeek: [1, 3, 5],
                    hour: 9,
                    minute: 30,
                    repeatType: .weekly
                ),
                onIgnore: {},
                onStartRecording: {}
            )
            .padding(40)
            .background(Color.gray.opacity(0.3))
        }
    }
#endif
