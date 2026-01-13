# 极简录音 - 技术架构文档

## 系统架构概述
本项目是一款基于 macOS 的原生应用，采用 Swift 和 SwiftUI 开发。核心设计理念是“轻量化与高可靠性”。应用采用纯本地音频采集与流式存储架构，不依赖任何云服务，确保用户隐私与极致的性能。

## 技术栈
- **UI 框架**：SwiftUI (主视图) + AppKit (菜单栏与生命周期管理)。
- **音频处理**：
    - AVFoundation (AVAudioEngine 采集, AVAssetWriter 写入)。
    - ScreenCaptureKit (macOS 13.0+ 系统音频采集)。
- **存储**：UserDefaults (配置与状态持久化)。

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

# H1 数据模型与 UI
## H2 Recording (模型层)
- 提供基础的文件命名与路径管理。
- 封装录音元数据（开始时间、时长等）。

## 关键决策
- **Fragmented MP4 优于分段录音**：消除了文件合并的延迟和 `ffmpeg` 外部依赖，同时保持了同等级别的崩溃可靠性。
- **完全本地化**：废除所有云端上传与转写逻辑，极致保护用户数据隐私，同时提升响应速度。

## 当前状态
- [x] 2026-01-12: 初始化架构文档。
- [x] 2026-01-13: 补充多云协作架构（已标记废弃）。
- [x] 2026-01-14: **精简化架构重构**：移除流水线相关服务，回归纯本地音频引擎。
- [x] 2026-01-14: **音频转换优化**：引入 `AVAudioConverter` 缓存机制，确保采样转换的音频连续性，解决失真问题。
- [x] 2026-01-14: **命名机制优化**：实现基于文件系统检测的序号递增冲突解决方法。
- [x] 2026-01-14: **UI 同步架构增强**：引入基于 `NotificationCenter` 的快捷键变更广播机制，实现菜单栏 UI 的实时刷新，解耦快捷键修改与显示逻辑。
- [x] 2026-01-14: **命名规则优化**:重构 `generateInitialFileName()` 和 `renameToFinalFormat()`,引入星期缩写(`DateFormatter` 的 `"E"` 格式),调整为双空格分隔,移除上下午标记,时长格式简化为 `Xmin`。
