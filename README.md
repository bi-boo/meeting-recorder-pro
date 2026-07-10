# 会议录音 Pro

> macOS 菜单栏录音工具，面向会议、访谈和长时间语音记录。支持麦克风、系统声音、麦克风 + 系统声音混合录制，也支持定时录音和 MP3 输出。

本项目开源，通过独立 DMG 分发，不提交 Mac App Store。发布与签名策略见 [独立分发说明](docs/distribution.md)。

## 下载与安装

1. 打开 [GitHub Releases](https://github.com/bi-boo/meeting-recorder-pro/releases)。
2. 下载最新的 `MeetingRecorderPro_YYYYMMDD.dmg`。
3. 打开 DMG，把 `会议录音 Pro.app` 拖到 `Applications`。
4. 首次录音时授予麦克风权限；录制系统声音时，还需要授予屏幕与系统音频录制权限。

开发或测试包可能没有完成 notarization，macOS 拦截时需要在系统设置中手动放行；正式公开包应使用 Developer ID 签名并完成公证。

## 主要功能

- **实时保存**：录音文件循环写入，断电/崩溃不丢失已录内容
- **屏幕关闭也能录**：录音期间自动保持系统唤醒，合盖不中断
- **全局快捷键**：任意界面下一键开始/结束/暂停录音
- **麦克风 + 系统声音**：同时捕获本机麦克风和系统声音，线上会议两端声音一次录齐
- **定时录音**：支持每天/每周定时计划，到点自动开始，不再手动开录
- **轻量常驻**：纯菜单栏应用，不占 Dock，支持 M4A / MP3 输出格式
- **自动更新**：菜单栏默认显示当前版本；后台发现新版本后显示“下载并安装 x.y.z...”，由用户主动安装

## 自动更新

会议录音 Pro 使用 Sparkle 2 做独立分发更新，不维护额外服务器。

- 更新源：GitHub Releases 中的 `appcast.xml`
- 检查频率：每天一次
- 默认状态：菜单栏显示 `当前版本 x.y.z`
- 发现更新：同一菜单项显示 `下载并安装 x.y.z...`
- 安装过程：同一菜单项显示下载、准备安装和安装重启状态
- 录音保护：录音中禁用检查和安装更新，避免重启影响录音保存

详细机制见 [自动更新说明](docs/auto-update.md)。

## 系统要求

- macOS 13.0 (Ventura) 或更高版本
- 当前预编译 DMG 面向 Apple Silicon (`arm64`)
- 录制系统声音需要授予「屏幕录制」权限

## 隐私说明

- 不需要账号登录
- 不上传录音文件
- 不收集遥测、联系人、日历、位置或设备标识
- 仅访问 GitHub Releases 检查更新
- 录音文件只保存在用户选择的本地目录

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

没有 Developer ID 证书时，打包脚本会使用 ad-hoc 签名，只适合本机验证。

正式发布包使用严格模式：

```bash
RELEASE=1 ./build_dmg.sh
```

正式发布并同步 GitHub Releases 自动更新源：

```bash
RELEASE=1 PUBLISH_GITHUB_RELEASE=1 ./build_dmg.sh
```

### 回归测试

提交或打包前按 [回归测试流程](docs/qa-regression.md) 做验证。优先执行一键自动化：

```bash
scripts/run_full_qa.sh
```

自动化会同时构建不含 QA 入口的公开 Release 产物，以及只在本机测试时启用 `QA_AUTOMATION` 的 QA App。录音文件必须可解码、达到最小时长且不是静音，结果写入 `qa-runs/*/report.md`。

### 项目文档

- [功能清单](docs/feature-list.md)
- [稳定交付标准](docs/stable-delivery-standard.md)
- [测试用例与流程](docs/test-cases.md)
- [发布检查清单](docs/release-checklist.md)
- [独立分发说明](docs/distribution.md)
- [技术架构](docs/architecture.md)

### 敏感配置

项目不包含 API Key、凭证或敏感配置文件。Sparkle 更新私钥应保存在本机忽略文件，例如 `config/sparkle_ed25519_private.pem`，不能提交到 Git、Release、日志或文档。

## 项目结构

```
SimpleRecorder/
├── SimpleRecorderApp.swift          # 入口 + 菜单栏
├── MP3Encoder.swift                 # MP3 输出入口（LAME 分块转码 + 原生兜底）
├── NativeMP3Encoder.swift           # 原生 MP3 兜底编码
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
├── Services/
│   └── QAAutomationRunner.swift     # 仅 QA_AUTOMATION 构建启用
├── Views/
│   ├── MainWindowSettingsView.swift # 设置窗口（TabView）
│   ├── TimerTaskViews.swift         # 定时计划列表 & 编辑 Sheet
│   └── ReminderWindowController.swift  # 浮动通知弹窗
├── Resources/
│   ├── Assets.xcassets
│   └── LogoConcepts/
└── ThirdParty/
    └── lame/                        # MP3 转码依赖
```

## License

本项目使用 [MIT License](LICENSE)。第三方组件声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，LAME 源码获取和重链接方法见 [LAME 源码与重链接说明](docs/lame-relinking.md)。
