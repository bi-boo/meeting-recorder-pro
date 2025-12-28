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
            
            // 存储路径设置
            StorageSettingsView()
                .tabItem {
                    Label("存储路径", systemImage: "folder")
                }
                .tag(1)
            
            // 转写设置
            TranscriptionSettingsView()
                .tabItem {
                    Label("转写设置", systemImage: "text.badge.checkmark")
                }
                .tag(2)
            
            // API 配置
            APISettingsView()
                .tabItem {
                    Label("API 配置", systemImage: "key")
                }
                .tag(3)
        }
        .frame(minWidth: 680, minHeight: 520)
    }
}

// MARK: - 存储路径设置
struct StorageSettingsView: View {
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
                            Button("打开") {
                                NSWorkspace.shared.open(settings.recordingsPath)
                            }
                            .buttonStyle(.bordered)
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
                            Button("打开") {
                                NSWorkspace.shared.open(settings.transcriptionsPath)
                            }
                            .buttonStyle(.bordered)
                            Button("选择...") {
                                selectFolder(for: \.transcriptionsPath)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                Spacer()
            }
            .padding(20)
        }
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

// MARK: - 转写设置
struct TranscriptionSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 基础功能
                GroupBox("基础功能") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $settings.enableITN) {
                            VStack(alignment: .leading) {
                                Text("文本规范化 (ITN)")
                                    .font(.headline)
                                Text("将数字、日期等转换为规范格式，如「二零二五年」→「2025年」")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Divider()
                        
                        Toggle(isOn: $settings.enablePunctuation) {
                            VStack(alignment: .leading) {
                                Text("自动标点")
                                    .font(.headline)
                                Text("自动添加逗号、句号等标点符号")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Divider()
                        
                        Toggle(isOn: $settings.enableDDC) {
                            VStack(alignment: .leading) {
                                Text("语义顺滑")
                                    .font(.headline)
                                Text("去除「嗯」「啊」等口语化表达，使文本更通顺")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Divider()
                        
                        Toggle(isOn: $settings.showUtterances) {
                            VStack(alignment: .leading) {
                                Text("分句显示")
                                    .font(.headline)
                                Text("按语句分段显示，便于阅读")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                // 高级功能
                GroupBox("高级功能") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $settings.enableSpeakerInfo) {
                            VStack(alignment: .leading) {
                                Text("说话人分离")
                                    .font(.headline)
                                Text("区分不同说话人，适合会议记录等场景")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Divider()
                        
                        Toggle(isOn: $settings.enableEmotionDetection) {
                            VStack(alignment: .leading) {
                                Text("情绪检测")
                                    .font(.headline)
                                Text("识别说话人的情绪状态")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Divider()
                        
                        Toggle(isOn: $settings.enableGenderDetection) {
                            VStack(alignment: .leading) {
                                Text("性别识别")
                                    .font(.headline)
                                Text("识别说话人性别")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Divider()
                        
                        Toggle(isOn: $settings.showSpeechRate) {
                            VStack(alignment: .leading) {
                                Text("语速信息")
                                    .font(.headline)
                                Text("显示说话语速")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                // 提示
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                    Text("高级功能可能增加处理时间，建议根据需要选择")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(20)
        }
    }
}

// MARK: - API 配置
struct APISettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 火山引擎配置
                GroupBox("火山引擎（语音转写）") {
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
                        
                        Text("用于将录音转换为文字，需要先在火山引擎控制台创建应用并获取密钥")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                // 腾讯云配置
                GroupBox("腾讯云 CloudBase（文件上传）") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Env ID")
                                .frame(width: 100, alignment: .leading)
                            TextField("请输入 Env ID", text: $settings.cloudbaseEnvId)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        Text("用于临时存储音频文件供火山引擎访问")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                // API 状态
                GroupBox("状态") {
                    HStack {
                        if settings.isAPIConfigured {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("API 配置完成，可以使用转写功能")
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("请填写完整的 API 配置以使用转写功能")
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                
                Spacer()
            }
            .padding(20)
        }
    }
}

#Preview {
    MainWindowView()
        .frame(width: 700, height: 550)
}
