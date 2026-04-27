//
//  SimpleRecorderApp.swift
//  会议录音 Pro - Mac 菜单栏录音应用
//
//  Created by AI Assistant
//

import AVFoundation
import PermissionFlow
import SwiftUI

@main
struct SimpleRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 纯菜单栏应用 (LSUIElement=true)，Settings 场景不会自动创建任何窗口
        // 设置窗口由 AppDelegate.showMainWindow() 手动管理
        Settings {
            EmptyView()
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var recordingManager = AudioRecorderManager.shared
    private var hotKeyManager = HotKeyManager.shared
    private var animationTimer: Timer?
    private var lastToggleTime: Date = .distantPast  // 用于防抖
    private var lastTimeString: String = ""

    // 动态获取当前配置的图标
    private func getStatusImage() -> NSImage? {
        let symbolName = AppSettings.shared.iconStyle.symbolName
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "会议录音 Pro")
        image?.isTemplate = true
        return image
    }

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

        // 【关键修复】应用启动时强制触发麦克风权限弹窗
        // Ad-hoc 签名的应用有时 AVCaptureDevice.requestAccess 不会弹窗
        // 通过实际访问 AVAudioEngine 的 inputNode 来强制触发系统权限检查
        triggerMicrophonePermissionCheck()

        // 【注意】系统音频权限采用按需请求策略
        // 仅当用户在录制来源中选择"系统声音"或"同时录制"时才触发权限申请
        // 用户首次启动应用时不再自动弹出权限请求

        // 【新增】启动时检查录音目录权限，尽早发现问题
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let _ = AudioRecorderManager.shared.checkRecordingDirectoryPermission()
        }

        // 启动定时任务调度器
        TimerTaskManager.shared.startScheduler()

        // 延迟检查中断状态（确保 UI 完全加载）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.recordingManager.resetStatusAfterInterruption()
        }
    }

    /// 强制触发麦克风权限检查
    /// 通过实际访问音频硬件来让系统弹出权限申请窗口
    private func triggerMicrophonePermissionCheck() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        LogManager.shared.info("启动时权限预检 | 当前状态: \(status.rawValue)")

        if status == .notDetermined {
            // 方法1：尝试访问 AVAudioEngine 的 inputNode
            // 这会触发系统级别的权限检查
            DispatchQueue.global(qos: .userInitiated).async {
                let tempEngine = AVAudioEngine()
                // 访问 inputNode 会触发系统权限弹窗
                let _ = tempEngine.inputNode.inputFormat(forBus: 0)

                DispatchQueue.main.async {
                    let newStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                    LogManager.shared.info("权限触发完成 | 新状态: \(newStatus.rawValue)")
                }
            }
        }
    }

    /// 退出前检查是否正在录音，确保保存（异步，不阻塞主线程）
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 停止定时任务调度器
        TimerTaskManager.shared.stopScheduler()

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
                LogManager.shared.info("应用退出 | 正在保存录音...")
                // 异步保存，保存完成后通知系统继续退出（不阻塞主线程）
                recordingManager.saveRecordingImmediately {
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            } else {
                return .terminateCancel
            }
        }

        return .terminateNow
    }

    // MARK: - Status Item Setup
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = getStatusImage()
        }

        setupMenu()
    }

    private func setupMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false  // 必须禁用，否则手动设置的 isEnabled 会被覆盖

        // 录音控制
        let isRecording = recordingManager.isRecording
        let isPaused = recordingManager.isPaused

        let recordItem = NSMenuItem(
            title: isRecording ? "结束录音" : "开始录音",
            action: #selector(toggleRecording),
            keyEquivalent: ""
        )
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
            title: isPaused ? "继续录音" : "暂停录音",
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        if let hotKey = HotKeyManager.shared.pauseHotKey {
            pauseItem.keyEquivalent = hotKey.keyEquivalent
            pauseItem.keyEquivalentModifierMask = hotKey.modifierMask
        } else {
            pauseItem.keyEquivalent = "4"
            pauseItem.keyEquivalentModifierMask = [.command, .option, .control]
        }
        pauseItem.target = self
        pauseItem.isEnabled = isRecording  // 录音时启用
        menu.addItem(pauseItem)

        menu.addItem(NSMenuItem.separator())

        // 录音来源标题
        let sourceHeader = NSMenuItem(title: "录音来源", action: nil, keyEquivalent: "")
        sourceHeader.isEnabled = false
        menu.addItem(sourceHeader)

        // 录制来源选项
        let isCurrentlyRecording = recordingManager.isRecording
        for source in AudioSource.allCases {
            let item = NSMenuItem(
                title: source.displayName, action: #selector(selectAudioSource(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = source.rawValue
            item.state = AppSettings.shared.audioSource == source ? .on : .off
            // 【边界逻辑】录音时禁用录制来源切换，避免用户困惑
            item.isEnabled = !isCurrentlyRecording
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
            // 【边界逻辑】录音时禁用麦克风切换；仅系统声音模式下也禁用
            item.isEnabled = !isCurrentlyRecording && settings.audioSource != .systemAudio
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
        let quitItem = NSMenuItem(
            title: "退出会议录音 Pro", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func selectAudioSource(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
            let source = AudioSource(rawValue: rawValue)
        else { return }

        // 选择需要屏幕录制权限的音源时,如果未授权,触发 PermissionFlow 拖拽授权动画
        if source != .microphone && !AppSettings.hasScreenCapturePermission {
            LogManager.shared.info("从菜单栏触发屏幕录制权限引导 | 目标音源: \(source.displayName)")

            // 计算菜单栏图标在屏幕坐标系下的位置,作为动画飞行起点
            let sourceFrame: CGRect = {
                guard let button = statusItem.button,
                    let buttonWindow = button.window
                else {
                    return CGRect(
                        x: NSEvent.mouseLocation.x - 16,
                        y: NSEvent.mouseLocation.y - 16,
                        width: 32, height: 32)
                }
                let buttonFrameInWindow = button.convert(button.bounds, to: nil)
                return buttonWindow.convertToScreen(buttonFrameInWindow)
            }()

            // PermissionFlow API 是 @MainActor isolated,而 @objc selector 默认不是,
            // 用 Task { @MainActor in ... } 切到 MainActor 上调用。
            // 使用默认 configuration——不请求 Accessibility 权限。
            // PermissionFlow 内部在无 AX 时会回退到 Window Server polling,
            // 悬浮窗仍能跟踪系统设置窗口,只是响应速度略慢——录音 app 没必要为此让用户授权「控制电脑」。
            Task { @MainActor in
                PermissionFlow.makeController().authorize(
                    pane: .screenRecording,
                    suggestedAppURLs: [Bundle.main.bundleURL],
                    sourceFrameInScreen: sourceFrame
                )
            }
            return
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
            LogManager.shared.info("用户点击结束录音")
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
        if let button = statusItem.button {
            button.alphaValue = 1.0  // 录音状态下强制恢复完全不透明
            button.image = getStatusImage()

            // 根据设置决定是否显示录制时长
            if AppSettings.shared.showDurationWhenRecording {
                let elapsed = Int(recordingManager.recordingDuration)
                let totalMinutes = elapsed / 60
                let seconds = elapsed % 60

                let timeString = String(format: "%02d:%02d", totalMinutes, seconds)

                // 【性能优化】如果时间字符串没变，不做任何 UI 操作
                guard timeString != lastTimeString else { return }
                lastTimeString = timeString

                button.title = " \(timeString)"
                button.imagePosition = .imageLeading
            } else {
                // 不显示时长，仅显示图标
                button.title = ""
                button.imagePosition = .imageOnly
            }
        }
    }

    private func stopRecordingTimer() {
        animationTimer?.invalidate()
        animationTimer = nil

        updateIdleIcon()
    }

    private func updateIdleIcon() {
        if let button = statusItem.button {
            button.image = getStatusImage()
            button.title = ""
            button.imagePosition = .imageOnly

            // 如果启用了空闲时变暗，设置更低的透明度
            if AppSettings.shared.dimIconWhenIdle {
                button.alphaValue = 0.35  // 更淡的透明度
            } else {
                button.alphaValue = 1.0
            }
        }
    }

    private func updateStatusBarPaused() {
        if let button = statusItem.button {
            button.alphaValue = 1.0  // 录音状态下恢复完全不透明
            button.image = getStatusImage()  // 统一图标样式
            button.imagePosition = .imageLeading

            if AppSettings.shared.showDurationWhenRecording {
                button.title = " 已暂停"
            } else {
                // 即使不显示时长，也需标注暂停状态，避免与空闲状态混淆
                button.title = " ‖"
            }
        }
    }

    @objc private func handleIconStyleChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lastTimeString = ""  // 强制刷新计时器，以更新图标
            if self.recordingManager.isRecording {
                if self.recordingManager.isPaused {
                    self.updateStatusBarPaused()
                } else {
                    self.updateStatusBarTimer()
                }
            } else {
                self.updateIdleIcon()
            }
        }
    }

    private func updateMenuRecordingState(isRecording: Bool, isPaused: Bool) {
        // 直接刷新整个菜单，setupMenu 会处理所有项的启用/禁用和标题状态
        setupMenu()
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
    static let scheduleSettingsChanged = Notification.Name("scheduleSettingsChanged")
}
