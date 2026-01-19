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
    private var lastToggleTime: Date = .distantPast  // 用于防抖

    // 保持窗口引用，防止被释放
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 记录应用启动日志
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let appVersion =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        LogManager.shared.info("应用启动 | 版本: \(appVersion), 系统: macOS \(osVersion)")

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

        // 监听图标样式变化通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIconStyleChanged),
            name: .iconStyleChanged,
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
                LogManager.shared.info("应用退出 | 录音已紧急保存")
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
        if let hotKey = HotKeyManager.shared.recordHotKey {
            recordItem.keyEquivalent = hotKey.keyEquivalent
            recordItem.keyEquivalentModifierMask = hotKey.modifierMask
        } else {
            recordItem.keyEquivalent = "5"
            recordItem.keyEquivalentModifierMask = [.command, .option, .control]
        }
        recordItem.target = self
        menu.addItem(recordItem)

        // 暂停/继续控制
        let pauseItem = NSMenuItem(
            title: "暂停录音", action: #selector(togglePause), keyEquivalent: "")
        if let hotKey = HotKeyManager.shared.pauseHotKey {
            pauseItem.keyEquivalent = hotKey.keyEquivalent
            pauseItem.keyEquivalentModifierMask = hotKey.modifierMask
        } else {
            pauseItem.keyEquivalent = "4"
            pauseItem.keyEquivalentModifierMask = [.command, .option, .control]
        }
        pauseItem.target = self
        pauseItem.isEnabled = false  // 初始禁用，录音时启用
        menu.addItem(pauseItem)

        menu.addItem(NSMenuItem.separator())

        // 录制来源标题
        let sourceHeader = NSMenuItem(title: "录制来源", action: nil, keyEquivalent: "")
        sourceHeader.isEnabled = false
        menu.addItem(sourceHeader)

        // 录制来源选项
        for source in AudioSource.allCases {
            let item = NSMenuItem(
                title: source.displayName, action: #selector(selectAudioSource(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = source.rawValue
            item.state = AppSettings.shared.audioSource == source ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // 麦克风设备标题
        let micHeader = NSMenuItem(title: "麦克风设备", action: nil, keyEquivalent: "")
        micHeader.isEnabled = false
        menu.addItem(micHeader)

        // 麦克风设备选项
        let settings = AppSettings.shared
        settings.refreshInputDevices()
        for device in settings.availableInputDevices {
            let item = NSMenuItem(
                title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.id
            item.state = device.id == settings.selectedDeviceID ? .on : .off
            // 仅系统声音模式下禁用麦克风选择
            item.isEnabled = settings.audioSource != .systemAudio
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // 打开主窗口（仅包含设置）
        let settingsItem = NSMenuItem(
            title: "设置...", action: #selector(showMainWindow), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // 退出
        let quitItem = NSMenuItem(title: "退出极简录音", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func selectAudioSource(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
            let source = AudioSource(rawValue: rawValue)
        else { return }

        // 如果选择需要系统音频权限的选项，先检查权限
        if source != .microphone {
            if !AppSettings.hasScreenCapturePermission {
                AppSettings.requestScreenCapturePermission()
                AppSettings.openScreenCaptureSettings()
                return
            }
        }

        AppSettings.shared.audioSource = source

        // 刷新菜单以更新选中状态
        setupMenu()

        LogManager.shared.info("录制来源已切换 | 来源: \(source.displayName)")
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let deviceID = sender.representedObject as? String else { return }
        AppSettings.shared.selectedDeviceID = deviceID

        // 刷新菜单以更新选中状态
        setupMenu()

        LogManager.shared.info("麦克风已切换 | 设备ID: \(deviceID)")
    }

    // MARK: - Actions
    @objc func toggleRecording() {
        let now = Date()
        let interval = now.timeIntervalSince(lastToggleTime)

        // 防抖：限制操作间隔不少于 800ms
        if interval < 0.8 {
            LogManager.shared.debug("操作太快，已忽略 | 间隔: \(String(format: "%.2f", interval))s")
            return
        }
        lastToggleTime = now

        if recordingManager.isRecording {
            LogManager.shared.info("用户点击停止录音")
            recordingManager.stopRecording()
        } else {
            LogManager.shared.info("用户点击开始录音")
            recordingManager.startRecording()
        }
        updateMenuRecordingState(
            isRecording: recordingManager.isRecording, isPaused: recordingManager.isPaused)
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
            if let recording = self?.recordingManager.isRecording,
                let paused = self?.recordingManager.isPaused
            {
                self?.updateMenuRecordingState(isRecording: recording, isPaused: paused)
            }
        }
    }

    // MARK: - Recording State Animation
    @objc private func recordingStateChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if self.recordingManager.isRecording {
                if self.recordingManager.isPaused {
                    // 暂停状态
                    self.animationTimer?.invalidate()
                    self.animationTimer = nil
                    self.updateStatusBarPaused()
                    self.updateMenuRecordingState(isRecording: true, isPaused: true)
                } else {
                    // 录音中
                    self.startRecordingTimer()
                    self.updateMenuRecordingState(isRecording: true, isPaused: false)
                }
            } else {
                self.stopRecordingTimer()
                self.updateMenuRecordingState(isRecording: false, isPaused: false)
            }
        }
    }

    private func startRecordingTimer() {
        animationTimer?.invalidate()

        // 每秒更新一次计时器
        updateStatusBarTimer()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] _ in
            self?.updateStatusBarTimer()
        }
    }

    private func updateStatusBarTimer() {
        let elapsed = Int(recordingManager.recordingDuration)

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

        updateIdleIcon()
    }

    private func updateIdleIcon() {
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "极简录音")
            image?.isTemplate = true
            button.image = image
            button.title = ""

            // 如果启用了空闲时变暗，设置透明度
            if AppSettings.shared.dimIconWhenIdle {
                button.alphaValue = 0.5
            } else {
                button.alphaValue = 1.0
            }
        }
    }

    private func updateStatusBarPaused() {
        if let button = statusItem.button {
            button.alphaValue = 1.0  // 录音状态下恢复完全不透明
            let image = NSImage(
                systemSymbolName: "pause.circle.fill", accessibilityDescription: "已暂停")
            image?.isTemplate = true
            button.image = image
            button.title = " 已暂停"
            button.imagePosition = .imageLeading
        }
    }

    @objc private func handleIconStyleChanged() {
        // 如果不在录音，更新空闲图标透明度
        if !recordingManager.isRecording {
            updateIdleIcon()
        }
    }

    private func updateMenuRecordingState(isRecording: Bool, isPaused: Bool) {
        if let menu = statusItem.menu {
            // 更新录音菜单项
            if let recordItem = menu.items.first {
                recordItem.title = isRecording ? "停止录音" : "开始录音"
            }
            // 更新暂停菜单项（如果存在）
            if menu.items.count > 1 {
                let pauseItem = menu.items[1]
                if pauseItem.action == #selector(togglePause) {
                    pauseItem.isEnabled = isRecording
                    pauseItem.title = isPaused ? "继续录音" : "暂停录音"
                }
            }
        }
    }

    @objc func togglePause() {
        recordingManager.togglePause()
    }

    // MARK: - Hot Key Setup
    private func setupHotKey() {
        hotKeyManager.onRecordHotKeyPressed = { [weak self] in
            LogManager.shared.debug("录音快捷键触发")
            DispatchQueue.main.async {
                self?.toggleRecording()
            }
        }

        hotKeyManager.onPauseHotKeyPressed = { [weak self] in
            LogManager.shared.debug("暂停快捷键触发")
            DispatchQueue.main.async {
                self?.togglePause()
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
    static let iconStyleChanged = Notification.Name("iconStyleChanged")
}
