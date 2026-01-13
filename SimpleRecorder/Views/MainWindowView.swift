// MARK: - Shortcut Recorder View
import Carbon
import SwiftUI

struct MainWindowView: View {
    var body: some View {
        GeneralSettingsView()
            .frame(minWidth: 500, minHeight: 400)
    }
}

// MARK: - 通用设置
struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var hotKeyManager = HotKeyManager.shared
    @State private var isRecordingShortcut = false

    var body: some View {
        Form {
            Section("快捷键") {
                HStack {
                    Text("开始/停止录音")
                    Spacer()
                    ShortcutRecorderView(
                        isRecording: $isRecordingShortcut,
                        currentHotKey: hotKeyManager.currentHotKey
                    ) { config in
                        hotKeyManager.saveHotKey(config)
                    }
                }
            }

            Section("录音选项") {
                Picker("音频源", selection: $settings.audioSource) {
                    ForEach(AudioSource.allCases, id: \.self) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .onChange(of: settings.audioSource) { newValue in
                    if newValue != .microphone {
                        // 1. 先触发系统原生权限申请提示（确保 APP 出现在列表中）
                        AppSettings.requestScreenCapturePermission()

                        if !AppSettings.hasScreenCapturePermission {
                            print("⚠️ 未获得屏幕录制权限，引导跳转设置...")
                            // 2. 稍作延迟后再打开设置页面，给系统弹窗留出时间
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                AppSettings.openScreenCaptureSettings()
                            }
                            // 回滚到仅麦克风
                            DispatchQueue.main.async {
                                settings.audioSource = .microphone
                            }
                        }
                    }
                }

                if settings.audioSource != .systemAudio {
                    Picker("输入设备", selection: $settings.selectedDeviceID) {
                        ForEach(settings.availableInputDevices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .onAppear {
                        settings.refreshInputDevices()
                    }
                }

                if !AppSettings.isSystemAudioSupported {
                    Text("系统音频录制需要 macOS 13.0 及以上版本")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else if !AppSettings.hasScreenCapturePermission {
                    Text("需要打开“录屏与系统录音”权限，以获取系统内的音频内容")
                        .font(.caption)
                        .foregroundColor(.blue)
                }

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
                            ForEach(0...59, id: \.self) { minute in
                                Text("\(minute) 分钟").tag(minute)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 80)
                    }
                }
            }

            Section("存储位置") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("录音保存至")
                        Spacer()
                        HStack {
                            Button("在 Finder 中打开") {
                                NSWorkspace.shared.open(settings.recordingsPath)
                            }
                            Button("更改...") {
                                selectFolder(for: \.recordingsPath)
                            }
                        }
                    }
                    Text(settings.recordingsPath.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
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

struct ShortcutRecorderView: View {
    @Binding var isRecording: Bool
    let currentHotKey: HotKeyManager.HotKeyConfiguration?
    let onHotKeyRecorded: (HotKeyManager.HotKeyConfiguration) -> Void
    @State private var eventMonitor: Any?

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
    }

    private func startMonitoring() {
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
    }

    private func recordHotKey(from event: NSEvent) {
        var modifiers: UInt32 = 0

        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }

        // 必须有修饰键
        guard modifiers != 0 else { return }

        let config = HotKeyManager.HotKeyConfiguration(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers
        )

        onHotKeyRecorded(config)
        // 确保立即生效
        HotKeyManager.shared.registerHotKey()
    }
}

#Preview {
    MainWindowView()
        .frame(width: 600, height: 500)
}
