//
//  ReminderWindowController.swift
//  极简录音 - 定时提醒弹窗控制器
//
//  Created by AI Assistant
//

import AppKit
import SwiftUI

// MARK: - 提醒弹窗控制器

/// 定时录音提醒弹窗控制器
class ReminderWindowController: NSObject {
    private var reminderWindow: NSWindow?
    private var onIgnoreCallback: (() -> Void)?
    private var onStartRecordingCallback: (() -> Void)?

    /// 显示提醒弹窗
    func showReminder(
        for task: TimerTask,
        onIgnore: @escaping () -> Void,
        onStartRecording: @escaping () -> Void
    ) {
        self.onIgnoreCallback = onIgnore
        self.onStartRecordingCallback = onStartRecording

        // 如果已有弹窗，先关闭
        dismissReminder()

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
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 130),
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

        LogManager.shared.info("显示定时提醒弹窗 | 任务: \(task.timeDisplay)")
    }

    /// 关闭弹窗
    func dismissReminder() {
        guard let window = reminderWindow else { return }

        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                window.orderOut(nil)
                self?.reminderWindow = nil
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
        onIgnoreCallback?()
        dismissReminder()
    }

    private func handleStartRecording() {
        onStartRecordingCallback?()
        dismissReminder()
    }

    /// 显示自动录音通知（5秒后自动消失）
    func showAutoStartNotification(for task: TimerTask) {
        // 如果已有弹窗，先关闭
        dismissReminder()

        // 创建通知视图
        let notificationView = AutoStartNotificationView(task: task)

        // 创建 NSWindow
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 80),
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.dismissReminder()
        }
    }
}

// MARK: - 提醒弹窗视图

struct ReminderView: View {
    let task: TimerTask
    let onIgnore: () -> Void
    let onStartRecording: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            // 主标题
            Text("是否启动录音")
                .font(.system(size: 14, weight: .semibold))

            // 副标题 - 计划时间
            Text("计划时间 \(task.timeDisplay)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            // 按钮区域
            HStack(spacing: 12) {
                Button(action: onIgnore) {
                    Text("忽略")
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
                .tint(.red)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(width: 260)
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
            // 主标题
            Text("录音已开始")
                .font(.system(size: 14, weight: .semibold))

            // 副标题 - 计划时间
            Text("计划时间 \(task.timeDisplay)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(width: 260)
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
