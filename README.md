# 会议录音 Pro

> 专为会议场景设计的 macOS 录音工具，支持定时录音、麦克风 + 系统声音同时录制，断电也不丢失录音。

本项目计划开源并通过独立 DMG 分发，不提交 Mac App Store。发布与签名策略见 [独立分发说明](docs/distribution.md)。

## 交付标准

本项目不靠无限审查判断稳定性，统一按 [稳定交付标准](docs/stable-delivery-standard.md) 执行。功能范围见 [功能清单](docs/feature-list.md)，测试入口见 [测试用例与流程](docs/test-cases.md)，发版前检查见 [发布检查清单](docs/release-checklist.md)。

## 功能特点

- **实时保存**：录音文件循环写入，断电/崩溃不丢失已录内容
- **屏幕关闭也能录**：录音期间自动保持系统唤醒，合盖不中断
- **全局快捷键**：任意界面下一键开始/结束/暂停录音
- **麦克风 + 系统声音**：同时捕获本机麦克风和系统声音，线上会议两端声音一次录齐
- **定时录音**：支持每天/每周定时计划，到点自动开始，不再手动开录
- **轻量常驻**：纯菜单栏应用，不占 Dock，支持 M4A / MP3 输出格式

## 系统要求

- macOS 13.0 (Ventura) 或更高版本
- 当前预编译 DMG 面向 Apple Silicon (`arm64`)
- 录制系统声音需要授予「屏幕录制」权限

## 开发

### 环境

- Xcode 15+
- Swift 5.9+

### 构建

```bash
# 直接用 Xcode 打开工程文件
open SimpleRecorder.xcodeproj

# 生成本地 DMG
./build_dmg.sh
```

没有 Developer ID 证书时，打包脚本会使用 ad-hoc 签名，只适合本机验证。公开分发版本应使用 Developer ID 签名并完成 notarization。

### 回归测试

任何改动提交或打包前，都必须按 [回归测试流程](docs/qa-regression.md) 跑完整功能验证。优先执行一键自动化：

```bash
scripts/run_full_qa.sh
```

自动化会打包 Release 产物，覆盖设置回读、麦克风录音、暂停继续、连续录音、MP3 输出、系统声音、混合音源和定时自动录音，并输出 `qa-runs/*/report.md`。剩余强交互或系统授权场景按回归测试流程人工补测。

### 敏感配置

项目不包含任何 API Key、凭证或敏感配置文件。如需扩展相关功能，请在本地创建 `config/secrets.json`（已加入 `.gitignore`，不会被提交）。

## 项目结构

```
SimpleRecorder/
├── SimpleRecorderApp.swift          # 入口 + 菜单栏
├── MP3Encoder.swift                 # MP3 输出入口（LAME 分块转码 + 原生兜底）
├── Models/
│   ├── AppSettingsCore.swift        # 全局设置（UserDefaults）
│   └── TimerTask.swift              # 定时任务数据模型
├── Managers/
│   ├── AudioRecorderManagerCore.swift       # 录音状态机 + 生命周期 API
│   ├── AudioRecorderManagerEngine.swift     # 音频引擎配置
│   ├── AudioRecorderManagerSystemAudio.swift # 系统音频采集
│   ├── AudioRecorderManagerWriter.swift     # 音频写入与文件管理
│   ├── AudioRecorderManagerDevice.swift     # 设备监听与激活
│   ├── AudioRecorderManagerUI.swift         # 弹窗与交互
│   ├── HotKeyManager.swift          # 全局快捷键
│   ├── TimerTaskManagerCore.swift   # 定时任务调度
│   └── LogManager.swift             # 运行日志
├── Views/
│   ├── MainWindowSettingsView.swift # 设置窗口（TabView）
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

本项目使用 [MIT License](LICENSE)。第三方组件和 LAME 许可声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
