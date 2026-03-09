# 会议录音 Pro

> 专为会议场景设计的 macOS 录音工具，支持定时录音、双声道同时录制，断电也不丢失录音。

## 功能特点

- **实时保存**：录音文件循环写入，断电/崩溃不丢失已录内容
- **屏幕关闭也能录**：录音期间自动保持系统唤醒，合盖不中断
- **全局快捷键**：任意界面下一键开始/结束/暂停录音
- **双声道同时录制**：同时捕获麦克风和系统声音，线上会议两端声音一次录齐
- **定时录音**：支持每天/每周定时计划，到点自动开始，不再手动开录
- **轻量常驻**：纯菜单栏应用，不占 Dock，支持 M4A / MP3 输出格式

## 系统要求

- macOS 13.0 (Ventura) 或更高版本
- 录制系统声音需要授予「屏幕录制」权限

## 开发

### 环境

- Xcode 15+
- Swift 5.9+

### 构建

```bash
# 直接用 Xcode 打开工程文件
open SimpleRecorder.xcodeproj
```

### 敏感配置

项目不包含任何 API Key、凭证或敏感配置文件。如需扩展相关功能，请在本地创建 `config/secrets.json`（已加入 `.gitignore`，不会被提交）。

## 项目结构

```
SimpleRecorder/
├── SimpleRecorderApp.swift          # 入口 + 菜单栏
├── Models/
│   ├── AppSettings.swift            # 全局设置（UserDefaults）
│   └── TimerTask.swift              # 定时任务数据模型
├── Managers/
│   ├── AudioRecorderManager.swift   # 录音核心逻辑
│   ├── HotKeyManager.swift          # 全局快捷键
│   ├── TimerTaskManager.swift       # 定时任务调度
│   └── LogManager.swift             # 运行日志
├── Views/
│   ├── MainWindowView.swift         # 设置窗口（TabView）
│   ├── TimerTaskViews.swift         # 定时计划列表 & 编辑 Sheet
│   └── ReminderWindowController.swift  # 浮动通知弹窗
└── Resources/
    └── Assets.xcassets
```

## 隐私说明

- 不收集任何用户数据
- 不联网，无任何网络请求
- 录音文件仅保存在用户本地指定目录
- 所需权限：麦克风（录音）、屏幕录制（系统声音，用户可选）

## License

Copyright © 2024–2026 Zheng Bao. All rights reserved.
