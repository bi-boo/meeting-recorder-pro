//
//  SimpleRecorderApp.swift
//  极简录音 - Mac 菜单栏录音应用
//
//  Created by AI Assistant
//

import SwiftUI

@main
struct SimpleRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 纯菜单栏应用，使用 WindowGroup 但不显示主窗口
        WindowGroup {
            EmptyView()
                .frame(width: 0, height: 0)
                .hidden()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 0, height: 0)
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var recordingManager = AudioRecorderManager.shared
    private var hotKeyManager = HotKeyManager.shared
    private var animationTimer: Timer?
    private var recordingStartTime: Date?
    private var lastToggleTime: Date = .distantPast  // 用于防抖

    // 保持窗口引用，防止被释放
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupHotKey()

        // 隐藏默认的空窗口
        DispatchQueue.main.async {
            for window in NSApp.windows {
                if window.title.isEmpty || window.contentView is NSHostingView<EmptyView> {
                    window.close()
                }
            }
        }

        // 监听录音状态变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recordingStateChanged),
            name: .recordingStateChanged,
            object: nil
        )

        // 监听打开设置窗口的通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showMainWindow),
            name: .openSettingsWindow,
            object: nil
        )

        // 监听快捷键变更通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHotKeyChanged),
            name: .hotKeyChanged,
            object: nil
        )

        // 延迟检查中断状态（确保 UI 完全加载）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.recordingManager.resetStatusAfterInterruption()
        }
    }

    /// 退出前检查是否正在录音，确保保存
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 如果正在录音，先保存
        if recordingManager.isRecording {
            // 弹出确认对话框
            let alert = NSAlert()
            alert.messageText = "正在录音中"
            alert.informativeText = "退出应用将自动保存当前录音。确定要退出吗？"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "保存并退出")
            alert.addButton(withTitle: "取消")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                // 用户确认退出，先保存录音
                recordingManager.saveRecordingImmediately()
                return .terminateNow
            } else {
                // 用户取消退出
                return .terminateCancel
            }
        }

        return .terminateNow
    }

    // MARK: - Status Item Setup
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "极简录音")
            button.image?.isTemplate = true
        }

        setupMenu()
    }

    private func setupMenu() {
        let menu = NSMenu()

        // 录音控制
        let recordItem = NSMenuItem(
            title: "开始录音", action: #selector(toggleRecording), keyEquivalent: "")
        if let hotKey = HotKeyManager.shared.currentHotKey {
            recordItem.keyEquivalent = hotKey.keyEquivalent
            recordItem.keyEquivalentModifierMask = hotKey.modifierMask
        } else {
            // 后备方案
            recordItem.keyEquivalent = "r"
            recordItem.keyEquivalentModifierMask = [.command, .shift]
        }
        recordItem.target = self
        menu.addItem(recordItem)

        menu.addItem(NSMenuItem.separator())

        // 打开主窗口（仅包含设置）
        let settingsItem = NSMenuItem(
            title: "设置...", action: #selector(showMainWindow), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // 退出
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Actions
    @objc func toggleRecording() {
        let now = Date()
        let interval = now.timeIntervalSince(lastToggleTime)

        // 防抖：限制操作间隔不少于 800ms
        if interval < 0.8 {
            print("⏳ 操作太快，已忽略 (间隔: \(String(format: "%.2f", interval))s)")
            return
        }
        lastToggleTime = now

        if recordingManager.isRecording {
            recordingManager.stopRecording()
        } else {
            recordingManager.startRecording()
        }
        updateMenuRecordingState(isRecording: recordingManager.isRecording)
    }

    @objc private func showMainWindow() {
        // 如果主窗口已存在，直接显示
        if let window = mainWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 450),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.contentView = NSHostingView(rootView: MainWindowView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        mainWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func handleHotKeyChanged() {
        DispatchQueue.main.async { [weak self] in
            // 重新设置菜单以更新显示的快捷键
            self?.setupMenu()
            // 重新应用当前的录音状态（防止 title 被重置为“开始录音”）
            if let recording = self?.recordingManager.isRecording {
                self?.updateMenuRecordingState(isRecording: recording)
            }
        }
    }

    // MARK: - Recording State Animation
    @objc private func recordingStateChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if self.recordingManager.isRecording {
                self.startRecordingTimer()
                self.updateMenuRecordingState(isRecording: true)
            } else {
                self.stopRecordingTimer()
                self.updateMenuRecordingState(isRecording: false)
            }
        }
    }

    private func startRecordingTimer() {
        animationTimer?.invalidate()
        recordingStartTime = Date()

        // 每秒更新一次计时器
        updateStatusBarTimer()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] _ in
            self?.updateStatusBarTimer()
        }
    }

    private func updateStatusBarTimer() {
        guard let startTime = recordingStartTime else { return }
        let elapsed = Int(Date().timeIntervalSince(startTime))

        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60

        let timeString: String
        if hours > 0 {
            timeString = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            timeString = String(format: "%02d:%02d", minutes, seconds)
        }

        if let button = statusItem.button {
            // 使用麦克风图标 + 时间文字
            let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "录音中")
            image?.isTemplate = true
            button.image = image
            button.title = " \(timeString)"
            button.imagePosition = .imageLeading
        }
    }

    private func stopRecordingTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
        recordingStartTime = nil

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "极简录音")
            button.image?.isTemplate = true
            button.title = ""
        }
    }

    private func updateMenuRecordingState(isRecording: Bool) {
        if let menu = statusItem.menu, let recordItem = menu.items.first {
            recordItem.title = isRecording ? "停止录音" : "开始录音"
        }
    }

    // MARK: - Hot Key Setup
    private func setupHotKey() {
        hotKeyManager.onHotKeyPressed = { [weak self] in
            DispatchQueue.main.async {
                self?.toggleRecording()
            }
        }
        hotKeyManager.registerHotKey()
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let recordingStateChanged = Notification.Name("recordingStateChanged")
    static let openSettingsWindow = Notification.Name("openSettingsWindow")
    static let hotKeyChanged = Notification.Name("hotKeyChanged")
}
