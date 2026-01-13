# 极简录音 - 技术架构文档

## 系统架构概述
本项目是一款基于 macOS 的原生应用，采用 Swift 和 SwiftUI 开发。核心设计理念是“轻量化与高可靠性”。应用采用多云混合流水线架构，实现高效的音频转写与 AI 总结。

## 技术栈
- **UI 框架**：SwiftUI (主视图) + AppKit (菜单栏与生命周期管理)。
- **音频处理**：
    - AVFoundation (AVAudioEngine 采集, AVAssetWriter 写入)。
    - ScreenCaptureKit (macOS 13.0+ 系统音频采集)。
- **后端云服务**：
    - **腾讯云 (CloudBase/COS)**：作为音频中转站。
    - **火山引擎 (Volc Engine ASR)**：大模型 ASR 引擎。
    - **豆包 AI (Ark)**：Doubao-Seed 系列模型进行摘要。
- **存储**：UserDefaults (配置与状态持久化), Keychain (敏感 API Keys)。

## 模块说明

# H1 音频引擎模块
## H2 AudioRecorderManager (fMP4 单文件方案)
- **Fluid Write**：使用 `AVAudioEngine` 的 `installTap` 捕获麦克风 Buffer。
- **Fragmented MP4**：配置 `AVAssetWriter` 的 `movieFragmentInterval`。在这种模式下，音轨信息会被周期性（10s）地写入文件头部的 `moof` 片段，而非仅在结束时写入 `moov`。
- **Idle Sleep Prevention**：集成 `IOKit` 电源管理 API。录音期间通过 `IOPMAssertionCreateWithDescription` 申请 `kIOPMAssertionTypeNoIdleSleep` 断言，确保 CPU 持续运行而允许屏幕关闭。
- **Zero-Merge Recovery**：不再依赖 `ffmpeg` 进行合并。崩溃后，文件本身就是合法的 MP4 流，直接读取即可。
- **Multi-Source Audio**（macOS 13.0+）：
    - 使用 `ScreenCaptureKit` 的 `SCStream` 采集系统音频输出。
    - 通过 `AVAudioMixerNode` 将麦克风和系统音频混合。
    - 支持三种模式：仅麦克风、仅系统音频、混合录制。

# H1 智能服务流水线
## H2 TranscriptionManager
- 编排转写任务：Upload -> Submit -> Poll -> Save。
- 处理 ASR 结果的语义化转换（Markdown 模版填充）。

## H2 AISummaryService
- 集成豆包 API，采用 3 次重试机制及思维链推理 token 管理。
- 实现文稿头部信息剔除算法，仅提取对话正文进行总结。

# H1 数据模型与 UI
## H2 Recording (模型层)
- 实现基于 Regex 的复杂文件名解析逻辑。
- 提供 `RecordingTimelineView` 所需的层级化日期聚合（支持 `YYYY.MM.DD - am/pm HH.mm - X min` 及其历史格式）。

## 关键决策
- **Fragmented MP4 优于分段录音**：消除了文件合并的延迟和 `ffmpeg` 外部依赖，同时保持了同等级别的崩溃可靠性。
- **异步清理机制**：云端临时音频在转写结束后自动标记删除。

## 当前状态
- [x] 2026-01-12: 初始化架构文档。
- [x] 2026-01-13: 补充多云协作架构、分段录音逻辑及 ffmpeg 依赖详情。
- [x] 2026-01-13: **音频录制增强/修复**：完成采样率对齐（48kHz）、系统音频缓冲流控及高精度时间戳修复。
- [x] 2026-01-13: **录音命名优化**：实现基于起止时间与时长的异步重命名流程，统一为 `YYYY.MM.DD - am/pm HH.mm - X min` 格式。
- [x] 2026-01-13: **计时器高可靠性优化**：通过基于 `recordingStartDate` 的绝对时间戳计算时长，并切换至 `.common` 运行循环模式，确保时长上限限额检测在 UI 交互期间不失效。
- [x] 2026-01-14: **高并发稳定性优化**：在 `AudioRecorderManager` 中通过状态转换锁封堵了启停竞态路径，并实施了基于 `engine.reset()` 的彻底资源资源回收策略，保障了长时、多次录制的健壮性。
