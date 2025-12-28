//
//  MainWindowView.swift
//  极简录音 - 主窗口视图（录音列表 + 设置）
//

import SwiftUI

struct MainWindowView: View {
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // 录音列表标签
            RecordingsListView()
                .tabItem {
                    Label("录音列表", systemImage: "list.bullet")
                }
                .tag(0)
            
            // 设置标签
            SettingsContentView()
                .tabItem {
                    Label("设置", systemImage: "gear")
                }
                .tag(1)
        }
        .frame(minWidth: 650, minHeight: 500)
    }
}

// MARK: - Settings Content View (不含 TabView 的设置内容)
struct SettingsContentView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var hotKeyManager = HotKeyManager.shared
    @State private var isRecordingShortcut = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 快捷键设置
                GroupBox("快捷键") {
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
                    .padding(.vertical, 4)
                }
                
                // 存储路径设置
                GroupBox("存储路径") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("录音保存位置")
                                    .font(.headline)
                                Text(settings.recordingsPath.path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button("选择...") {
                                selectFolder(for: \.recordingsPath)
                            }
                        }
                        
                        Divider()
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("转写文件保存位置")
                                    .font(.headline)
                                Text(settings.transcriptionsPath.path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button("选择...") {
                                selectFolder(for: \.transcriptionsPath)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                // API 配置
                GroupBox("火山引擎配置") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("APP ID")
                                .frame(width: 100, alignment: .leading)
                            TextField("请输入 APP ID", text: $settings.volcengineAppId)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        HStack {
                            Text("Access Token")
                                .frame(width: 100, alignment: .leading)
                            SecureField("请输入 Access Token", text: $settings.volcengineAccessToken)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                GroupBox("腾讯云配置") {
                    HStack {
                        Text("CloudBase Env ID")
                            .frame(width: 120, alignment: .leading)
                        TextField("请输入 Env ID", text: $settings.cloudbaseEnvId)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.vertical, 4)
                }
                
                // API 状态
                HStack {
                    if settings.isAPIConfigured {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("API 配置完成，可以使用转写功能")
                            .foregroundColor(.secondary)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("请填写完整的 API 配置以使用转写功能")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.top, 8)
                
                Spacer()
            }
            .padding(20)
        }
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

#Preview {
    MainWindowView()
        .frame(width: 700, height: 550)
}
