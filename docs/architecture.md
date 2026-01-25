# 会议录音 Pro - 技术架构文档

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

### H3 录音中断检测机制
- **设备监听**：通过 Core Audio `AudioObjectAddPropertyListenerBlock` 监听 `kAudioHardwarePropertyDefaultInputDevice` 和 `kAudioHardwarePropertyDevices`
- **引擎监听**：监听 `.AVAudioEngineConfigurationChange` 通知检测音频配置变更
- **系统音频监听**：实现 `SCStreamDelegate.stream(_:didStopWithError:)` 捕获 SCStream 错误
- **定时检查**：每 30 秒检查磁盘空间、实时检查 AssetWriter 状态
- **中断枚举**：`RecordingInterruptionReason` 定义 6 种场景（设备移除/设备变更/引擎配置/系统音频错误/磁盘不足/写入失败）
- **统一处理**：`handleRecordingInterruption()` 紧急保存 + 弹窗提醒 + 支持重新录音

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
- **图标样式**：支持 `microphone` / `circle_dot` / `waveform` 三种样式切换
- **显示控制**：控制录音期间是否显示计时，以及闲置时是否变暗
- **定时配置**：全局控制提醒模式（提前提醒/自动录音）及提醒提前量（1-10 分钟）
- **开机自启动**：使用 `SMAppService` (macOS 13.0+) 注册登录项

---

# H1 日志模块

## H2 LogManager
日志管理器，采用单例模式 (`shared`)。

- **5 级日志**：debug / info / warning / error / critical
- **文件路径**：`~/会议录音 Pro/.日志/MeetingRecorderPro_YYYY-MM-DD.log`
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

# H1 打包工程化

## H2 build_dmg.sh
自动化打包与分发脚本，执行清理、编译、签名及镜像打包的全流程。

### H3 签名规约
- **环境安全**：自动加载 `.env` 环境变量中的 `DEVELOPER_ID_CERT` 证书
- **多级签名**：依次处理 `.app` 二进制和生成的 `.dmg` 文件
- **隔离清理**：强制执行 `xattr -cr` 移除 `com.apple.quarantine` 属性，确保下载后双击即可运行
- **运行时选项**：指定 `--options runtime` 启用 Hardened Runtime，满足系统安全性要求

---

# H1 定 shortcut 计划 (Timer Tasks)

## H2 TimerTask
定时任务数据模型，实现 `Codable` 协议。

- **字段**：id、enabled、daysOfWeek、hour、minute、repeatType、actionType、reminderMinutes、nextTriggerTime、lastTriggerTime
- **循环类型**：none（单次/不循环） / daily（每天） / weekly（每周）
- **时间计算**：自动计算 `nextTriggerTime`，支持星期多选。

## H2 TimerTaskManager
定时任务调度管理器，采用单例模式 (`shared`)。

- **CRUD 操作**：支持任务的增删改查及冲突检测（同一时间点仅允许一个计划）。
- **持久化**：使用 `UserDefaults` 存储 JSON 编码的任务列表。
- **调度器**：30 秒轮询定时器，检查是否需触发提醒或自动录音。
- **睡眠控制 (增强)**：
    - 集成 `IOKit` 电源管理 API。
    - **原理**：监听设置变更及任务列表状态，若存在**已启用**的任务且开启了“有定时计划时禁止系统睡眠”，则启动 `kIOPMAssertionTypeNoIdleSleep` 电源断言，防止计划因系统休眠而漏触发。
- **防重复触发**：使用 `triggeredTaskIDs` 集合记录已触发任务。
- **通知系统**：监听 `NSSystemClockDidChange`、`NSWorkspace.didWakeNotification` 以及 `scheduleSettingsChanged` 通知。

## H2 ReminderWindowController
提醒弹窗控制器，管理右上角浮窗。

- **逻辑表现**：根据 `actionType` 表现为“提前提醒”或“自动录音”反馈。预览标签集成在计划列表的 `TimerTaskRow` 中。

---

# H1 视图层

## H2 MainWindowView / AboutView
设置窗口的主视图。

- **关于我们**：采用极简纯文字排版，移除品牌 Logo 展示。
- **快捷键设置**：支持录音、暂停两个关键动作的响应式设置。

## H2 TimerTaskListView / TimerTaskEditView
定时计划设置视图。

- **列表排序**：通过 `sortedTasks` 计算属性，实现基于 0-24 小时绝对时间的自动排序显示。
- **编辑逻辑**：新增计划时，`repeatType` 默认为 `.none`，`actionType` 默认为 `.autoStart`。
- **系统控制**：集成“开机自启动”和“睡眠控制”开关组。

## 关键决策

- **电源断言双保险**：在针对“录音中”设置断言的基础上，新增针对“活跃定时计划”的独立断言，确保 Mac 在作为后台任务中心时的稳定性。
- **UI 扁平化**：移除 About 页 Logo 及精简 TimerTask 列表的标签层级（提醒方式与循环描述合并显示），遵循更加纯粹的功能主义原则。
- **时间冲突拦截**：在数据源头（TimerTaskEditView）拦截同时间点的重复设置，维持调度器的确定性。

## 当前状态
- [x] 2026-01-25: **定时计划架构增强**：实现在线/离线任务的系统休眠保护逻辑；优化任务排序与冲突检测算法。
- [x] 2026-01-24: **打包规约与安全对齐**：完善自动化签名脚本与 TCC 权限预触发机制。
- [x] 2026-01-20: 新增 `LameEncoder`；新增暂停/继续机制；新增录音引擎预备机制。
- [x] 2026-01-14: 架构重构，移除流处理流水线。
- [x] 2026-01-13: 实现多音频源架构。
- [x] 2026-01-12: 初始化架构文档。
