# 极简录音 - 技术架构文档

## 系统架构概述

本项目是一款基于 macOS 的原生应用，采用 Swift 和 SwiftUI 开发。核心设计理念是"轻量化与高可靠性"。应用采用纯本地音频采集与流式存储架构，不依赖任何云服务，确保用户隐私与极致的性能。

**技术栈**：
- **UI 框架**：SwiftUI (主视图) + AppKit (菜单栏与生命周期管理)
- **音频处理**：AVFoundation (`AVAudioEngine` 采集, `AVAssetWriter` 写入)
- **系统音频**：ScreenCaptureKit (macOS 13.0+ 系统音频采集)
- **MP3 编码**：LAME (内嵌编码器，M4A 转 MP3)
- **热键管理**：Carbon (全局快捷键注册)
- **存储**：UserDefaults (配置与状态持久化)
- **日志系统**：自研 LogManager (5级日志、文件存储、7天轮转)

## 模块说明

# H1 应用生命周期

## H2 SimpleRecorderApp + AppDelegate
- **入口点**：使用 `@main` 标记的 SwiftUI App 结构体
- **菜单栏管理**：通过 `NSStatusItem` 创建常驻菜单栏图标
- **状态同步**：监听录音状态变化，实时更新菜单栏图标（灰色/红色）和计时显示
- **防抖机制**：800ms 的操作间隔限制，防止高频启停导致的竞态条件

---

# H1 音频引擎模块

## H2 AudioRecorderManager
核心录音管理器，采用单例模式 (`shared`)，负责音频采集、存储和状态管理。

### H3 Fragmented MP4 单文件方案
- **流式写入**：使用 `AVAudioEngine` 的 `installTap` 捕获音频 Buffer
- **分片存储**：配置 `AVAssetWriter` 的 `movieFragmentInterval`，周期性（10s）写入 `moof` 片段
- **零合并恢复**：崩溃后文件本身就是合法的 MP4 流，直接读取即可

### H3 多音频源架构（macOS 13.0+）
- **麦克风采集**：通过 `AVAudioEngine.inputNode` 采集硬件输入
- **系统音频采集**：使用 `ScreenCaptureKit` 的 `SCStream` 采集系统音频输出
- **混音处理**：通过 `AVAudioMixerNode` 将麦克风和系统音频混合
- **无监听设计**：独立 `recordingMixer` 节点不连接输出，杜绝回声

### H3 暂停/继续机制
- **累计时长追踪**：使用 `accumulatedDuration` 累积已录制时长
- **分段计时**：每次暂停时保存当前段时长，继续时从累计值开始
- **引擎状态管理**：暂停时停止引擎，继续时重新启动

### H3 录音引擎预备机制
- **干净状态保证**：每次录音前调用 `prepareAudioEngineForNewRecording()` 完全重置引擎
- **资源清理**：停止引擎、移除 tap、detach 节点、清空缓冲队列
- **格式匹配**：使用 `inputNode.inputFormat(forBus: 0)` 获取硬件实际格式，确保链路采样率统一

### H3 防休眠机制
- 集成 `IOKit` 电源管理 API
- 录音期间通过 `IOPMAssertionCreateWithDescription` 申请 `kIOPMAssertionTypeNoIdleSleep` 断言
- 确保 CPU 持续运行而允许屏幕关闭

---

# H1 快捷键模块

## H2 HotKeyManager
全局快捷键管理器，采用单例模式 (`shared`)。

- **注册机制**：使用 Carbon 的 `RegisterEventHotKey` API
- **配置存储**：快捷键配置序列化后存入 `UserDefaults`
- **默认值**：`Cmd + Shift + R`
- **通知广播**：快捷键变更时通过 `NotificationCenter` 广播，实现菜单栏 UI 实时刷新

---

# H1 配置模块

## H2 AppSettings
应用配置管理器，采用单例模式 (`shared`)，使用 `@Published` 属性包装器实现响应式更新。

- **存储路径**：支持安全书签（Security-Scoped Bookmark）持久化路径权限
- **录音上限**：小时 + 分钟组合设置（0-9 小时，0-59 分钟）
- **音频源**：三种模式（microphone / systemAudio / both）
- **输入设备**：通过 `AVCaptureDevice.DiscoverySession` 枚举可用麦克风
- **输出格式**：M4A / MP3 格式选择
- **录音后动作**：自动打开 Finder 定位文件开关
- **开机自启动**：使用 `SMAppService` (macOS 13.0+) 注册登录项
- **图标样式**：未录音时图标可选变暗

---

# H1 日志模块

## H2 LogManager
日志管理器，采用单例模式 (`shared`)。

- **5 级日志**：debug / info / warning / error / critical
- **文件路径**：`~/极简录音/日志/SimpleRecorder_YYYY-MM-DD.log`
- **7 天轮转**：启动时自动清理过期日志
- **崩溃安全**：使用 `FileHandle.synchronize()` 确保写入

---

# H1 第三方模块

## H2 LameEncoder
MP3 编码器，封装 LAME 库。

- **转换流程**：读取 M4A → PCM 解码 → LAME 编码 → 写入 MP3
- **参数配置**：VBR 模式，质量等级 2（高质量）
- **异步处理**：在 `userInitiated` 队列执行，不阻塞主线程

---

# H1 视图层

## H2 MainWindowView / GeneralSettingsView
设置窗口的主视图，使用 SwiftUI `Form` 构建。

- **快捷键设置**：自定义 `ShortcutRecorderView` 组件捕获按键
- **录音选项**：音频源选择器、输入设备选择器、时长上限选择器
- **存储位置**：路径显示、在 Finder 中打开、更改路径按钮

## 关键决策

- **Fragmented MP4 优于分段录音**：消除了文件合并的延迟和 `ffmpeg` 外部依赖，同时保持同等级别的崩溃可靠性
- **完全本地化**：废除所有云端上传与转写逻辑，极致保护用户数据隐私
- **Carbon 热键 API**：虽然是遗留 API，但在 macOS 上仍是注册系统级全局热键的唯一可靠方式
- **独立混音器节点**：通过不连接输出的 `recordingMixer`，实现无监听录制

## 当前状态
- [x] 2026-01-12: 初始化架构文档
- [x] 2026-01-13: 实现多音频源架构（ScreenCaptureKit + AVAudioMixerNode）
- [x] 2026-01-14: 精简化架构重构，移除流水线相关服务
- [x] 2026-01-14: 引入 `AVAudioConverter` 缓存机制，解决音频转换失真
- [x] 2026-01-14: 引入 `NotificationCenter` 快捷键变更广播机制
- [x] 2026-01-19: 项目梳理，架构文档结构规范化；新增 `LogManager` 日志模块
- [x] 2026-01-20: 新增 `LameEncoder` MP3 编码模块；新增暂停/继续机制；新增录音引擎预备机制；修复启动失败资源泄漏
