//
//  SettingsView.swift
//  极简录音 - 设置视图
//

import SwiftUI
import Carbon

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var hotKeyManager = HotKeyManager.shared
    @State private var isRecordingShortcut = false
    
    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("通用", systemImage: "gear")
                }
            
            apiTab
                .tabItem {
                    Label("API 配置", systemImage: "key")
                }
        }
        .frame(width: 500, height: 400)
        .padding()
    }
    
    // MARK: - General Tab
    private var generalTab: some View {
        Form {
            Section("快捷键") {
                HStack {
                    Text("录音快捷键")
                    Spacer()
                    ShortcutRecorderView(
                        isRecording: $isRecordingShortcut,
                        currentHotKey: hotKeyManager.currentHotKey
                    ) { config in
                        hotKeyManager.saveHotKey(config)
                    }
                }
            }
            
            Section("存储路径") {
                HStack {
                    Text("录音保存位置")
                    Spacer()
                    Text(settings.recordingsPath.path)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("选择...") {
                        selectFolder(for: \.recordingsPath)
                    }
                }
                
                HStack {
                    Text("转写文件保存位置")
                    Spacer()
                    Text(settings.transcriptionsPath.path)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("选择...") {
                        selectFolder(for: \.transcriptionsPath)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - API Tab
    private var apiTab: some View {
        Form {
            Section("火山引擎配置") {
                TextField("APP ID", text: $settings.volcengineAppId)
                SecureField("Access Token", text: $settings.volcengineAccessToken)
            }
            
            Section("腾讯云配置") {
                TextField("CloudBase Env ID", text: $settings.cloudbaseEnvId)
            }
            
            Section {
                HStack {
                    if settings.isAPIConfigured {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("API 配置完成")
                            .foregroundColor(.secondary)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("请填写完整的 API 配置")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - Folder Selection
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

// MARK: - Shortcut Recorder View
struct ShortcutRecorderView: View {
    @Binding var isRecording: Bool
    let currentHotKey: HotKeyManager.HotKeyConfiguration?
    let onHotKeyRecorded: (HotKeyManager.HotKeyConfiguration) -> Void
    
    var body: some View {
        Button(action: { isRecording.toggle() }) {
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
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if isRecording {
                    recordHotKey(from: event)
                    isRecording = false
                    return nil
                }
                return event
            }
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
    }
}

#Preview {
    SettingsView()
}
