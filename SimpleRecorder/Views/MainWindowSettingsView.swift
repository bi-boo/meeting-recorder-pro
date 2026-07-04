import Carbon
import PermissionFlow
import SwiftUI

enum SettingsWindowLayout {
    static let contentTopPadding: CGFloat = 18
    static let aboutTitleTopPadding: CGFloat = 34
}

// MARK: - onChange 兼容封装（macOS 13/14 双版本适配）
private struct AudioSourceChangeModifier: ViewModifier {
    let value: AudioSource
    let action: (AudioSource) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onChange(of: value) { _, newValue in action(newValue) }
        } else {
            content.onChange(of: value, perform: action)
        }
    }
}

extension View {
    func onAudioSourceChange(_ value: AudioSource, perform action: @escaping (AudioSource) -> Void) -> some View {
        modifier(AudioSourceChangeModifier(value: value, action: action))
    }
}

struct MainWindowView: View {
    var body: some View {
        TabView {
            BasicSettingsView()
                .tabItem {
                    Label("基础设置", systemImage: "gear")
                }

            TimerTaskListView()
                .tabItem {
                    Label("定时计划", systemImage: "clock")
                }

            AdvancedSettingsView()
                .tabItem {
                    Label("高级设置", systemImage: "slider.horizontal.3")
                }

            AboutView()
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
        }
        .frame(minWidth: 560, minHeight: 620)  // 稍微增大窗口，给内容更多呼吸空间
    }
}

// MARK: - 核心功能
struct AboutView: View {
    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                Text("会议录音 Pro")
                    .font(.system(size: 30, weight: .semibold))
                    .padding(.top, SettingsWindowLayout.aboutTitleTopPadding)

                Text("专为办公、演讲、会议场景设计")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 18) {
                    FeatureItem(
                        title: "实时保存",
                        subtitle:
                            "录音过程中，文件循环保存。即使电脑突然断电、应用意外崩溃或被强制退出，已录制的内容都不会丢失。"
                    )
                    FeatureItem(
                        title: "屏幕关闭也能录",
                        subtitle:
                            "录音期间系统保持唤醒状态。即使关闭屏幕，录音也能在后台继续进行，适合需要长时间录音的场景。"
                    )
                    FeatureItem(
                        title: "全局快捷键",
                        subtitle: "无论在使用什么应用程序，只需按下预设的快捷键，即可立即开始或结束录音，无需切换窗口。"
                    )
                    FeatureItem(
                        title: "麦克风 + 系统声音同时录制",
                        subtitle: "支持同时录制麦克风和系统声音。戴耳机参加线上会议时，也能完整录下对方发言和你自己的声音。"
                    )
                    FeatureItem(
                        title: "定时录音",
                        subtitle: "支持设置定时计划，到点自动开始录音。不用担心忙碌时忘记开启录音，轻松捕捉每一场重要会议。"
                    )
                }
                .padding(.horizontal, 45)
                .padding(.top, 32)

                AboutMetadataView(versionText: versionText)
                    .padding(.horizontal, 45)
                    .padding(.top, 24)
                    .padding(.bottom, 30)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct FeatureItem: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AboutMetadataView: View {
    let versionText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
                .padding(.bottom, 6)

            AboutInfoRow(title: "版本", value: versionText)
            AboutInfoRow(title: "开源许可", value: "MIT License")
            AboutInfoRow(title: "第三方组件", value: "PermissionFlow、LAME / libmp3lame")
        }
        .font(.system(size: 12))
    }
}

struct AboutInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundColor(.secondary)
                .frame(width: 72, alignment: .leading)

            Text(value)
                .foregroundColor(.primary)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
    }
}

// MARK: - 基础设置
struct BasicSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var hotKeyManager = HotKeyManager.shared
    @ObservedObject private var recordingManager = AudioRecorderManager.shared
    @State private var isRecordingShortcut = false
    @State private var isRecordingPauseShortcut = false

    private var isRecordingBusy: Bool {
        recordingManager.recordingState != .idle
    }

    private var recordingBusyMessage: String {
        switch recordingManager.recordingState {
        case .starting:
            return "录音正在启动，设置将在下次录音时生效"
        case .stopping:
            return "录音正在保存，设置将在下次录音时生效"
        default:
            return "正在录音中，设置将在下次录音时生效"
        }
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 16) {
                    HStack {
                        Text("开始/结束录音")
                        Spacer()
                        ShortcutRecorderView(
                            isRecording: $isRecordingShortcut,
                            currentHotKey: hotKeyManager.recordHotKey,
                            conflictKey: hotKeyManager.pauseHotKey,
                            conflictKeyName: "暂停/继续录音",
                            onBeginRecording: {
                                isRecordingPauseShortcut = false
                            },
                            onHotKeyRecorded: { config in
                                hotKeyManager.saveRecordHotKey(config)
                            }
                        )
                    }

                    HStack {
                        Text("暂停/继续录音")
                        Spacer()
                        ShortcutRecorderView(
                            isRecording: $isRecordingPauseShortcut,
                            currentHotKey: hotKeyManager.pauseHotKey,
                            conflictKey: hotKeyManager.recordHotKey,
                            conflictKeyName: "开始/结束录音",
                            onBeginRecording: {
                                isRecordingShortcut = false
                            },
                            onHotKeyRecorded: { config in
                                hotKeyManager.savePauseHotKey(config)
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("全局快捷键").padding(.bottom, 4)
            }

            Section {
                VStack(spacing: 14) {
                    Picker("录音来源", selection: $settings.audioSource) {
                        ForEach(AudioSource.allCases, id: \.self) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .disabled(isRecordingBusy)
                    .onAudioSourceChange(settings.audioSource) { newValue in
                        if newValue != .microphone && !AppSettings.hasScreenCapturePermission {
                            LogManager.shared.info(
                                "从主窗口触发屏幕录制权限引导 | 目标音源: \(newValue.displayName)")
                            // 命令式触发 PermissionFlow：自动打开系统设置 + 飞行动画 + 拖拽授权悬浮窗
                            // 用默认 configuration——不主动请求 Accessibility 权限,
                            // PermissionFlow 内部在无 AX 时会回退到 Window Server polling,悬浮窗仍可跟踪。
                            let mouse = NSEvent.mouseLocation
                            let sourceFrame = CGRect(
                                x: mouse.x - 16, y: mouse.y - 16, width: 32, height: 32)
                            PermissionFlow.makeController().authorize(
                                pane: .screenRecording,
                                suggestedAppURLs: [Bundle.main.bundleURL],
                                sourceFrameInScreen: sourceFrame
                            )
                            DispatchQueue.main.async {
                                settings.audioSource = .microphone
                            }
                        }
                    }

                    if settings.audioSource != .systemAudio {
                        Picker("麦克风设备", selection: $settings.selectedDeviceID) {
                            ForEach(settings.availableInputDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .disabled(isRecordingBusy)
                        .onAppear {
                            settings.refreshInputDevices()
                        }
                    }

                    // 【边界逻辑】录音中提示
                    if isRecordingBusy {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.blue)
                            Text(recordingBusyMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }

                    // 权限提示
                    if !AppSettings.isSystemAudioSupported {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.orange)
                            Text("录音系统声音需要 macOS 13 或更新版本")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("录音来源").padding(.bottom, 4)
            }

            Section {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("录音保存至")
                        Spacer()
                        HStack(spacing: 8) {
                            Button("在 Finder 中打开") {
                                NSWorkspace.shared.open(settings.recordingsPath)
                            }
                            Button("更改位置...") {
                                selectFolder(for: \.recordingsPath)
                            }
                        }
                    }

                    Text(settings.recordingsPath.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(6)

                    Toggle("录音完成后自动打开文件夹", isOn: $settings.openFolderAfterRecording)
                        .tint(.green)
                }
                .padding(.vertical, 4)
            } header: {
                Text("存储位置").padding(.bottom, 4)
            }
        }
        .formStyle(.grouped)
        .padding(.top, SettingsWindowLayout.contentTopPadding)
    }

    private func selectFolder(for keyPath: ReferenceWritableKeyPath<AppSettings, URL>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"

        if panel.runModal() == .OK, let url = panel.url {
            settings[keyPath: keyPath] = url
        }
    }
}

// MARK: - 高级设置
struct AdvancedSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    private var maxDurationMinuteOptions: [Int] {
        let allOptions = [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55]
        return settings.maxDurationHours == 0 ? Array(allOptions.dropFirst()) : allOptions
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 16) {
                    HStack {
                        Text("单次录音最长时长")
                        Spacer()
                        HStack(spacing: 10) {
                            Picker("", selection: $settings.maxDurationHours) {
                                ForEach(0...9, id: \.self) { hour in
                                    Text("\(hour) 小时").tag(hour)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 85)

                            Picker("", selection: $settings.maxDurationMinutes) {
                                ForEach(maxDurationMinuteOptions, id: \.self) { minute in
                                    Text("\(minute) 分钟").tag(minute)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 85)
                        }
                    }

                    Picker("保存格式", selection: $settings.outputFormat) {
                        ForEach(OutputFormat.availableCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("录音控制").padding(.bottom, 4)
            } footer: {
                // 格式说明移至外部 footer，更符合 macOS 原生规范
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("M4A")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 0.5)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(2)
                        Text("体积小、音质优，Apple 设备首选")
                    }
                    HStack(spacing: 6) {
                        if MP3Encoder.isEncodingAvailable {
                            Text("MP3")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 3)
                                .padding(.vertical, 0.5)
                                .background(Color.secondary.opacity(0.12))
                                .cornerRadius(2)
                            Text("兼容性极佳，适合跨平台自由分享")
                        } else {
                            Text("MP3")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 3)
                                .padding(.vertical, 0.5)
                                .background(Color.secondary.opacity(0.12))
                                .cornerRadius(2)
                            Text("MP3 编码器不可用，暂以 M4A 保存")
                        }
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.top, 6)
            }

            Section {
                VStack(spacing: 16) {
                    Picker("图标样式", selection: $settings.iconStyle) {
                        ForEach(IconStyle.allCases, id: \.self) { style in
                            Label(style.displayName, systemImage: style.symbolName)
                                .tag(style)
                        }
                    }

                    Toggle("录音时显示已录时长", isOn: $settings.showDurationWhenRecording)
                        .tint(.green)

                    Toggle("未录音时图标变暗", isOn: $settings.dimIconWhenIdle)
                        .tint(.green)
                }
                .padding(.vertical, 4)
            } header: {
                Text("菜单栏").padding(.bottom, 4)
            }

            Section {
                Button("打开日志文件夹") {
                    let logDir = LogManager.shared.getLogDirectory()
                    NSWorkspace.shared.open(logDir)
                }
                .padding(.vertical, 4)
            } header: {
                Text("诊断日志").padding(.bottom, 4)
            }
        }
        .formStyle(.grouped)
        .padding(.top, SettingsWindowLayout.contentTopPadding)
    }
}

// MARK: - 快捷键录制组件
struct ShortcutRecorderView: View {
    @Binding var isRecording: Bool
    let currentHotKey: HotKeyManager.HotKeyConfiguration?
    var conflictKey: HotKeyManager.HotKeyConfiguration? = nil
    var conflictKeyName: String = "其他功能"
    var onBeginRecording: () -> Void = {}
    let onHotKeyRecorded: (HotKeyManager.HotKeyConfiguration) -> Void
    @State private var eventMonitor: Any?
    @State private var showConflictAlert = false

    var body: some View {
        Button(action: {
            if isRecording {
                isRecording = false
                stopMonitoring()
            } else {
                onBeginRecording()
                isRecording = true
                startMonitoring()
            }
        }) {
            if isRecording {
                Text("按下快捷键...")
                    .foregroundColor(.accentColor)
                    .frame(minWidth: 120)
            } else if let hotKey = currentHotKey {
                Text(hotKey.displayString)
                    .frame(minWidth: 120)
            } else {
                Text("未设置")
                    .foregroundColor(.secondary)
                    .frame(minWidth: 120)
            }
        }
        .buttonStyle(.bordered)
        .onChange(of: isRecording) { newValue in
            if !newValue {
                stopMonitoring()
            }
        }
        .onDisappear {
            stopMonitoring()
        }
        .alert("快捷键冲突", isPresented: $showConflictAlert) {
            Button("重新设置", role: .cancel) {}
        } message: {
            Text("此快捷键已用于「\(conflictKeyName)」，请换一个组合键。")
        }
    }

    private func startMonitoring() {
        HotKeyManager.shared.unregisterHotKey()

        stopMonitoring()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            recordHotKey(from: event)
            isRecording = false
            stopMonitoring()
            return nil
        }
    }

    private func stopMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        HotKeyManager.shared.registerHotKey()
    }

    private func recordHotKey(from event: NSEvent) {
        var modifiers: UInt32 = 0

        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }

        guard modifiers != 0 else { return }

        let config = HotKeyManager.HotKeyConfiguration(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers
        )

        if let conflict = conflictKey, conflict == config {
            showConflictAlert = true
            return
        }

        onHotKeyRecorded(config)
        HotKeyManager.shared.registerHotKey()
    }
}

// Preview 仅在 macOS 14+ 可用
#if swift(>=5.9)
    #Preview {
        MainWindowView()
            .frame(width: 560, height: 620)
    }
#endif
