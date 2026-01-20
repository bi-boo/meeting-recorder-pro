// MARK: - Shortcut Recorder View
import Carbon
import SwiftUI

struct MainWindowView: View {
    var body: some View {
        TabView {
            AboutView()
                .tabItem {
                    Label("关于我们", systemImage: "info.circle")
                }

            BasicSettingsView()
                .tabItem {
                    Label("基础设置", systemImage: "gear")
                }

            AdvancedSettingsView()
                .tabItem {
                    Label("高级设置", systemImage: "slider.horizontal.3")
                }
        }
        .frame(minWidth: 520, minHeight: 580)
    }
}

// MARK: - 关于我们
struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 应用名称
                Text("极简录音")
                    .font(.system(size: 28, weight: .medium))
                    .padding(.top, 30)

                Text("专为会议录制设计")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)

                // 版本号
                Text("版本 1.0.0")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.top, 8)

                // 特性列表
                VStack(alignment: .leading, spacing: 20) {
                    FeatureItem(
                        title: "实时保存",
                        subtitle: "采用流式写入技术，录音过程中持续保存。即使断电、崩溃或意外退出，已录制的内容完整保留。"
                    )
                    FeatureItem(
                        title: "防止休眠",
                        subtitle: "录音期间自动阻止系统进入睡眠。适合长时间会议录制，无需手动调整电源设置。"
                    )
                    FeatureItem(
                        title: "全局快捷键",
                        subtitle: "无论在使用什么应用，按下快捷键即可立即开始或停止录音，无需切换窗口。"
                    )
                    FeatureItem(
                        title: "双向录音",
                        subtitle: "支持同时录制麦克风和系统内部声音。戴耳机线上会议时，对方的声音和你的发言都会被完整录下。"
                    )
                }
                .padding(.horizontal, 30)
                .padding(.top, 30)
                .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct FeatureItem: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    var body: some View {
        Form {
            Section("快捷键") {
                HStack {
                    Text("开始/停止录音")
                    Spacer()
                    ShortcutRecorderView(
                        isRecording: $isRecordingShortcut,
                        currentHotKey: hotKeyManager.recordHotKey,
                        conflictKey: hotKeyManager.pauseHotKey
                    ) { config in
                        hotKeyManager.saveRecordHotKey(config)
                    }
                }

                HStack {
                    Text("暂停/继续录音")
                    Spacer()
                    ShortcutRecorderView(
                        isRecording: $isRecordingPauseShortcut,
                        currentHotKey: hotKeyManager.pauseHotKey,
                        conflictKey: hotKeyManager.recordHotKey
                    ) { config in
                        hotKeyManager.savePauseHotKey(config)
                    }
                }
            }

            Section("录制来源") {
                Picker("录制来源", selection: $settings.audioSource) {
                    ForEach(AudioSource.allCases, id: \.self) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .disabled(recordingManager.isRecording)  // 【边界逻辑】录音时禁用
                .onChange(of: settings.audioSource) { newValue in
                    if newValue != .microphone {
                        AppSettings.requestScreenCapturePermission()
                        if !AppSettings.hasScreenCapturePermission {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                AppSettings.openScreenCaptureSettings()
                            }
                            DispatchQueue.main.async {
                                settings.audioSource = .microphone
                            }
                        }
                    }
                }

                if settings.audioSource != .systemAudio {
                    Picker("麦克风设备", selection: $settings.selectedDeviceID) {
                        ForEach(settings.availableInputDevices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .disabled(recordingManager.isRecording)  // 【边界逻辑】录音时禁用
                    .onAppear {
                        settings.refreshInputDevices()
                    }
                }

                // 【边界逻辑】录音中提示
                if recordingManager.isRecording {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                        Text("录音中，设置将在下次录音时生效")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }

                // 权限提示
                if !AppSettings.isSystemAudioSupported {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.orange)
                        Text("系统声音录制需要 macOS 13.0 或更高版本")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                } else if !AppSettings.hasScreenCapturePermission
                    && settings.audioSource != .microphone
                {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield")
                            .foregroundColor(.orange)
                        Text("录制系统声音需要授予「屏幕录制」权限")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("前往设置") {
                            AppSettings.openScreenCaptureSettings()
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                    .padding(.top, 4)
                }
            }

            Section("存储位置") {
                HStack {
                    Text("录音保存至")
                    Spacer()
                    Button("在 Finder 中打开") {
                        NSWorkspace.shared.open(settings.recordingsPath)
                    }
                    Button("更改...") {
                        selectFolder(for: \.recordingsPath)
                    }
                }
                Text(settings.recordingsPath.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .formStyle(.grouped)
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

    var body: some View {
        Form {
            Section("录音") {
                HStack {
                    Text("单次录音时长上限")
                    Spacer()
                    HStack(spacing: 5) {
                        Picker("", selection: $settings.maxDurationHours) {
                            ForEach(0...9, id: \.self) { hour in
                                Text("\(hour) 小时").tag(hour)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 80)

                        Picker("", selection: $settings.maxDurationMinutes) {
                            ForEach([0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55], id: \.self) {
                                minute in
                                Text("\(minute) 分钟").tag(minute)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 80)
                    }
                }

                Picker("保存格式", selection: $settings.outputFormat) {
                    ForEach(OutputFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }

                // 格式说明
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("M4A：体积小、音质好，适合 Apple 设备")
                        Text("MP3：兼容性最广，便于分享到其他平台")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(.top, 2)
            }

            Section("行为") {
                Toggle(isOn: $settings.openFolderAfterRecording) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("录音完成后打开文件夹")
                        Text("自动在 Finder 中显示录音文件")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Toggle(isOn: $settings.dimIconWhenIdle) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("空闲时菜单栏图标变暗")
                        Text("不录音时降低图标亮度，减少视觉干扰")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Toggle("开机时自动启动", isOn: $settings.launchAtLogin)
            }

            Section("诊断") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("运行日志")
                        Text("用于排查录音故障")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("查看日志") {
                        NSWorkspace.shared.open(LogManager.shared.getLogDirectory())
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 快捷键录制组件
struct ShortcutRecorderView: View {
    @Binding var isRecording: Bool
    let currentHotKey: HotKeyManager.HotKeyConfiguration?
    var conflictKey: HotKeyManager.HotKeyConfiguration? = nil
    let onHotKeyRecorded: (HotKeyManager.HotKeyConfiguration) -> Void
    @State private var eventMonitor: Any?
    @State private var showConflictAlert = false

    var body: some View {
        Button(action: {
            isRecording.toggle()
            if isRecording {
                startMonitoring()
            } else {
                stopMonitoring()
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
                Text("点击设置")
                    .foregroundColor(.secondary)
                    .frame(minWidth: 120)
            }
        }
        .buttonStyle(.bordered)
        .onDisappear {
            stopMonitoring()
        }
        .alert("快捷键冲突", isPresented: $showConflictAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("该快捷键已被其他功能使用，请选择不同的快捷键。")
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

#Preview {
    MainWindowView()
        .frame(width: 600, height: 500)
}
