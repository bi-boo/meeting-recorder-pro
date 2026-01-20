# [2026-01-20 16:08]
- **用户需求/反馈**: 1. 应用进入屏幕共享状态但录音未开始，屏幕录制权限被占用；2. 麦克风录音模式无法启动，提示格式不匹配错误。
- **技术逻辑变更**: 
    - **录音启动失败资源泄漏修复**: 在 `startMicrophoneRecording()` 和 `startSystemAudioRecording()` 的 `catch` 块中增加轻量级资源清理逻辑，确保录音启动失败时正确释放已创建的 `SCStream`、`AssetWriter`、`recordingMixer` 等资源，避免屏幕录制权限被占用。
    - **音频引擎重置机制**: 新增 `prepareAudioEngineForNewRecording()` 辅助函数，在每次录音启动前完全重置音频引擎（停止引擎、移除 tap、detach 所有节点、调用 `reset()`、清空缓冲队列），确保从干净状态开始。
    - **音频格式匹配修复**: 修改 `setupMicrophoneOnlyRecording()` 使用 `inputNode.inputFormat(forBus: 0)` 获取硬件实际输入格式（而非 `outputFormat`），并将该格式传递给 `setupRecordingMixer()` 确保整条链路（inputNode → recordingMixer → mainMixerNode）采样率统一，解决"Format mismatch"错误。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `docs/changelog.md`
- **变更原因**: 解决录音启动时的资源泄漏和音频格式不匹配问题，确保应用在各种场景下都能正常启动录音。

# [2026-01-19 22:47]
- **用户需求/反馈**: 应用运行时遇到故障时无法查看日志，需要实时记录操作和状态以便排查问题
- **技术逻辑变更**: 
    - 新增 `LogManager.swift`：日志管理器（5 级日志、文件存储、7 天轮转、崩溃安全写入）
    - 在 `AudioRecorderManager.swift` 添加录音全流程日志埋点
    - 在 `SimpleRecorderApp.swift` 添加应用生命周期和用户操作日志
    - 在 `HotKeyManager.swift` 添加快捷键注册和变更日志
    - 在 `MainWindowView.swift` 添加"打开日志文件夹"按钮
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/LogManager.swift` [NEW]
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `SimpleRecorder/SimpleRecorderApp.swift`
    - `SimpleRecorder/Managers/HotKeyManager.swift`
    - `SimpleRecorder/Views/MainWindowView.swift`
- **变更原因**: 便于排查录音故障（崩溃、中断、无声音等），日志存储于 `~/极简录音/日志/` 目录

# [2026-01-19 22:36]
- **用户需求/反馈**: 根据项目规则重新梳理项目文档
- **技术逻辑变更**: 
    - 重构 `prd.md`：规范化"目标与背景"、"核心功能"、"用户流程"、"当前状态"四大板块结构
    - 重构 `architecture.md`：规范化"系统架构概述"、"模块说明"（含 H1-H3 层级）、"关键决策"、"当前状态"结构
    - 更新 `changelog.md`：添加本次梳理记录
- **涉及文件清单**: 
    - `docs/prd.md`
    - `docs/architecture.md`
    - `docs/changelog.md`
- **变更原因**: 确保项目文档符合全局规范，保持文档与代码状态同步

# [2026-01-14 02:10]
- **用户需求/反馈**: 优化文件命名格式,在日期后增加星期简写,使用双空格间距,去除 AM/PM 标记,时长由 `X min` 改为 `Xmin`。期望格式:录音中 `2026.01.14  Mon  18.59 - ing`,录音后 `2026.01.14  Mon  18.59 - 13min`。
- **技术逻辑变更**: 
    - 修改 `generateInitialFileName()`:使用 `DateFormatter` 的 `"E"` 格式生成三字母星期缩写(Mon/Tue/Wed等),调整为双空格分隔,移除上下午字段。
    - 修改 `renameToFinalFormat()`:同步时间格式调整,时长从 `"\(minutes) min"` 改为 `"\(minutes)min"`,简化基础文件名拼接逻辑。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `docs/prd.md`
    - `docs/architecture.md`
    - `docs/changelog.md`
- **变更原因**: 提升文件名可读性与审美一致性,增加星期信息便于用户按日期检索录音文件。

# [2026-01-14 01:58]
- **用户需求/反馈**: 修复修复后依然时长不足（10秒）以及再次启动录音时应用崩溃的问题。
- **技术逻辑变更**: 
    - **修复拷贝崩溃**: 发现在 Swift 中对 `AVAudioPCMBuffer` 调用 `.copy()` 会触发内存异常或 Nil，现已补齐自定义的 `deepCopy()` 内存深拷贝方法。
    - **彻底消除丢帧**: 重写 `processAudioBuffer` 逻辑，移除超时丢帧机制。利用 `writingQueue` 的串行特性，确保即使硬盘响应慢，所有音频帧也会被排队等待写入，绝不主动抛弃。
    - **安全实例捕获**: 在异步闭包中捕获当前 `AssetWriter` 实例，防止录音启停瞬间操作到被置空的旧对象。
    - **修正语法**: 修复了上一版修改遗留的函数嵌套错误。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `SimpleRecorder.dmg`
- **变更原因**: 从内存管理和时序同步层面彻底根治录音异常。

# [2026-01-14 01:49]
- **用户需求/反馈**: 录音 1 分钟但文件仅有 17 秒，存在严重丢帧与时长缩减问题。
- **技术逻辑变更**: 
    - 引入专用 `writingQueue` (串行队列) 负责异步音频写入，彻底分离录制与存储线程。
    - 在写入前对 `AVAudioPCMBuffer` 执行深拷贝，解决异步操作中的内存复用冲突。
    - 将系统音频缓冲队列上限从 30 提升至 200，增强抗负载波动能力。
    - 优化 `AssetWriter` 忙碌检查逻辑，增加微秒级重试机制。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `SimpleRecorder.dmg`
- **变更原因**: 解决高负载场景下因硬盘 IO 压力导致的音频帧强行丢弃，确保录制时长与物理时间严格一致。

# [2026-01-14 01:40]
- **用户需求/反馈**: 1. 明确标注麦克风输入并支持切换不同设备；2. 优化权限引导，确保应用自动出现在屏幕录制列表中；3. 优化权限提示文案。
- **技术逻辑变更**: 
    - 修改 `AppSettings` 接入 `AVCaptureDevice` 列举系统内所有音频输入。
    - 在 `AudioRecorderManager` 中通过 `AudioUnitSetProperty` 动态切换 `AVAudioEngine` 的硬件输入设备。
    - 引入 `CGRequestScreenCaptureAccess` 触发原生权限提示。
    - 优化 `MainWindowView` 中的文字表述并增加设备选择器。
- **涉及文件清单**: 
    - `SimpleRecorder/Models/AppSettings.swift`
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `SimpleRecorder/Views/MainWindowView.swift`
    - `SimpleRecorder.dmg`
- **变更原因**: 提升音频输入的灵活性，并降低用户开启权限的认知门槛。

# [2026-01-14 01:32]
- **用户需求/反馈**: 解决每次打包后系统权限（如屏幕录制）需要重新授权的问题。
- **技术逻辑变更**: 
    - 修改项目配置 `DEVELOPMENT_TEAM` 为 `UZ285BC956`。
    - 切换为“离线手签”模式：构建时禁用 Xcode 自动签名，构建后使用 `codesign` 显式应用开发证书。
    - 对最终生成的 `SimpleRecorder.dmg` 执行同步签名。
- **涉及文件清单**: 
    - `SimpleRecorder.xcodeproj/project.pbxproj`
    - `SimpleRecorder.dmg`
- **变更原因**: 固定应用的代码签名标识符（CDHash），使 macOS TCC 安全策略将其视为同一受信任应用，从而持久化存储权限授权。

# [2026-01-14 01:28]
- **用户需求/反馈**: 1. 移除音频源前面的 Emoji；2. 选择系统音频相关选项时，若无权限则自动跳转系统权限设置。
- **技术逻辑变更**: 
    - 修改 `AudioSource.displayName` 移除图标。
    - 在 `AppSettings` 中通过 `CGPreflightScreenCaptureAccess` 实现权限预检逻辑。
    - 在 `MainWindowView` 中通过 `onChange` 监听选择器，未授权时执行回滚并跳转 `x-apple.systempreferences`。
- **涉及文件清单**: 
    - `SimpleRecorder/Models/AppSettings.swift`
    - `SimpleRecorder/Views/MainWindowView.swift`
    - `docs/changelog.md`
    - `SimpleRecorder.dmg`
- **变更原因**: 优化系统的权限引导体验，符合极简设计规范。

# [2026-01-14 01:26]
- **用户需求/反馈**: 请求打一个新包。
- **技术逻辑变更**: 无（纯打包发布）。
- **涉及文件清单**: 
    - `SimpleRecorder.dmg`
- **变更原因**: 发布包含“高频启停稳定性增强”及“提醒逻辑优化”的最新完整版本。

# [2026-01-14 01:10]
- **用户需求/反馈**: 用户反馈频繁启停录音会导致应用无响应。
- **技术逻辑变更**: 
    - 引入基于 `Date` 的硬计时逻辑，解决主线程阻塞导致的计时漂移。
    - 实施 `isTransitioning` 状态锁，拦截正在进行的资源重置期间的新指令。
    - 在 `AppDelegate` 中增加 800ms 输入频率限制（Throttling）。
- **涉及文件清单**: 
    - `SimpleRecorder/SimpleRecorderApp.swift`
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `docs/prd.md`
    - `docs/changelog.md`
- **变更原因**: 修复高频启停导致的竞态条件和死锁问题。

# [2026-01-14 00:55]
- **用户需求/反馈**: 希望移除录音接近上限时的预警弹窗，但在录音结束后有时长反馈。
- **技术逻辑变更**: 
    - 彻底移除 `AudioRecorderManager` 中的 80% 阈值预警逻辑。
    - 新增录音成功结束后的 UI 回调，告知用户最终录制时长。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `docs/prd.md`
    - `docs/architecture.md`
- **变更原因**: 减少录音过程中的干扰，优化用户反馈闭环。

# [2026-01-14 00:45]
- **变更内容**: 发布新的 DMG 安装包
- **原因**: 用户需要分发最新的修复版本。
- **影响**: 
    - 构建并打包生成 `SimpleRecorder.dmg`。

# [2026-01-14 00:30]
- **用户需求/反馈**: 1. 文件名简洁（不需要秒）；2. 冲突解决使用 (1)(2) 序号；3. 录音时长限额支持 1 分钟精度。
- **技术逻辑变更**: 
    - 将文件名格式回退至 `HH.mm`。
    - 实现基于文件系统的循环检测算法，自动增加递增序列后缀。
    - 修改 UI 分钟步进值。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `SimpleRecorder/Views/MainWindowView.swift`
    - `docs/prd.md`
    - `docs/architecture.md`
- **变更原因**: 提升录音管理体验的直观性和灵活性。

# [2026-01-14 00:15]
- **用户需求/反馈**: 用户反馈开启混合录制时声音失真，且文件名偶尔出现四位随机数字。
- **技术逻辑变更**: 
    - 引入 `cachedAudioConverter` 实现转换器持久化，确保音频流连续性。
    - 将文件名内部生成精度提升至秒级，从根源消除重名冲突。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `docs/prd.md`
    - `docs/architecture.md`
- **变更原因**: 解决音频转换时的相位丢失问题及命名冲突。

# [2026-01-14 00:05]
- **用户需求/反馈**: 用户反馈连续多次录音时应用可能随机崩溃。
- **技术逻辑变更**: 
    - 强制在停止录音时执行 `audioEngine.reset()`，清除节点拓扑。
    - 修正 `SCStream` 异步清理时的竞争风险，确保资源彻底释放。
    - 使用局部变量捕获 `AVAssetWriter` 引用，隔离高频操作下的写入实例。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
- **变更原因**: 解决 `AVAudioEngine` 资源释放不彻底导致的系统级崩溃。


## [2026-01-13] - 优化录音命名格式 (用户定制版)
### 变更原因
根据用户最新需求，将录音命名格式调整为更易读的连字符分隔格式，并统一 am/pm 为小写，时长改为 `X min` 形式。

### 修改内容
1.  **启动命名**：格式更新为 `YYYY.MM.DD - am/pm HH.mm - ing.m4a`。
2.  **结束命名**：格式更新为 `YYYY.MM.DD - am/pm HH.mm - X min.m4a`。
3.  **正则解析增强**：在 `Recording.swift` 中新增对新格式的解析支持，确保新旧文件均能正确显示在列表中。
4.  **文档同步**：同步更新 `prd.md` 和 `architecture.md`。

### 影响范围
- `AudioRecorderManager.swift`
- `Recording.swift`
- `docs/prd.md`
- `docs/architecture.md`

## [2026-01-13] - 修复录音时长上限失效问题
### 变更原因
用户反馈设定时长上限（如 10 分钟）后，实际录音超过该时长依然在录。

### 修改内容
1.  **计时逻辑重构**：将 `AudioRecorderManager` 中的计时回调由 `recordingDuration += 1` 修改为 `Date().timeIntervalSince(startDate)`。这种“硬计算”方式消除了主线程阻塞（如用户操作菜单）导致的计时丢失，确保时长统计与现实物理时间保持同步。
2.  **RunLoop 优化**：将计时器移至 `.common` 模式，确保在菜单跟踪等 UI 操作期间计时逻辑依然能高频触发，及时检测时长上限。

### 影响范围
- `AudioRecorderManager.swift`

## [2026-01-13] - 录音命名格式深度自定义 (V2)
### 变更原因
进一步优化录音命名格式，根据用户反馈使用 4 位年份及 `.` 分隔符，并对时长进行 2 位零填充处理，使其更加规范美观。

### 修改内容
1.  **最终命名优化**：格式更新为 `YYYY.MM.DD_AM/PM_HH.mm-HH.mm_HH"MM.m4a`。
2.  **启动命名优化**：开始录音时的临时名也同步调整为 `YYYY.MM.DD_AM/PM_HH.mm.m4a`。
3.  **正则解析增强**：在 `Recording.swift` 中新增对 `YYYY.MM.DD` 格式的解析支持，确保列表显示正确。

## [2026-01-13] - 录音命名格式深度自定义 (V1)

### 影响范围
- `AudioRecorderManager.swift`
- `Recording.swift`
- `docs/prd.md`

## [2026-01-13] - 音频变速与拉长问题彻底修复
### 变更原因
修复用户反馈的录音声音被明显拉长、变慢、变深沉的问题。

### 修改内容
1.  **动态采样率对齐**：修复了硬编码的时间戳基准。此前强制使用 48000 作为 timescale，但在采样率更高的 Mac（如 MacBook Pro 的 96kHz 模式）上会导致生成的 `presentationTime` 变为实际物理时间的两倍。现已改为使用 `buffer.format.sampleRate` 动态计算。
2.  **物理帧计数时间戳**：全面切换为基于 `totalFramesWritten` 的物理帧计数方案。该方案不依赖易受系统抖动影响的硬件时钟，确保了音频播放速度与现实录制时长 1:1 绝对对齐，消除了变速感。

### 影响范围
- `AudioRecorderManager.swift`
- 确保了在不同硬件规格（44.1k/48k/96k）设备上录音速度的一致性。

## [2026-01-13] - 系统音频高保真修复
### 变更原因
修复用户反馈的系统音频（电脑内声音）失真嘈杂、声音破碎的问题。

### 修改内容
1.  **修复 Buffer 内存对齐**：重写了 `fillSystemAudioBuffer` 逻辑。之前在合并多个音频缓冲区时，未正确维护目的地址的内存偏移，导致波形数据覆盖错位。
2.  **引入子 Buffer 切片技术**：实现了对剩余音频样本的高精度切片保留逻辑。当 `AVAudioSourceNode` 请求的样本数小于缓冲区剩余数时，精准保留未消耗部分，确保了音频流的绝对连续性，消除了“机械音”和失真。
3.  **强化静音填充**：在数据拷贝前强制执行内存置零，杜绝了低负载下的随机底噪。

### 影响范围
- `AudioRecorderManager.swift`
- 解决了混合录音与系统音频录音的音质瓶颈。

## [2026-01-13] - 音频质量优化
### 变更原因
修复用户反馈的录制杂音、爆音及失真问题。

### 修改内容
1.  **统一采样率**：将全局音频处理采样率从 44.1kHz 提升至 48kHz，对齐 macOS 硬件默认规格，减少重采样误差。
2.  **增强缓冲逻辑**：在 `AudioRecorderManager` 中改进了系统音频的缓冲消费逻辑，引入静音预填补和多缓冲区合并拷贝，解决 Buffer Underflow 导致的爆音。
3.  **高精度时间戳**：优化了 `CMTime` 生成逻辑，通过显式取整确保采样点严格对齐，防止长时间录制的时间轴漂移。
4.  **稳定性日志**：增加了缓冲溢出监控日志，便于后续性能调优。

### 影响范围
- `AudioRecorderManager.swift`
- 录音文件格式由 44.1k 变为 48k。

# [2026-01-13 10:45]
- **变更内容**: 彻底解决混合录音失效及声音失真问题
- **原因**: 1. 混合模式下由于未显式分配 Bus，系统音频覆盖了麦克风信号；2. 系统音数据拷贝逻辑未适配 Non-interleaved（非交织）格式，导致录音产生嘈杂杂音。
- **影响**: 
    - 混合录音现在能够同时采集清晰的麦克风与系统声音。
    - 修复了数据拷贝深度，录音质感清亮、无失真。

# [2026-01-13 01:30]
- **变更内容**: 深度修复系统音频录制失败及监听回声问题
- **原因**: 之前的架构将录音节点连接到了主混音器，导致声音输出到耳机产生监听效果，且 SCStream 过滤器配置不当导致录制不到声音。
- **影响**: 
    - 引入独立 `recordingMixer` 节点，专门用于录音 tap，不连接任何输出，彻底消除监听效果。
    - 统一音频流向：所有录音源（麦克风、系统音频）均汇聚至 `recordingMixer`。
    - 修正 `SCContentFilter` 逻辑，仅排除当前应用，确保系统音频正常捕获。
    - 修复了 macOS 14+ 权限申请后录音启动逻辑的兼容性问题。

# [2026-01-13 00:51]
- **变更内容**: 新增多音频源选择功能
- **原因**: 满足用户录制会议音频、系统播放声音的需求。
- **影响**: 
    - 使用 `ScreenCaptureKit` (macOS 13.0+) 实现系统音频采集。
    - 支持三种模式：仅麦克风、仅系统音频、同时录制。
    - 设置界面新增音频源选择器。
    - 低版本系统自动降级为麦克风模式。

# [2026-01-13 00:32]
- **变更内容**: 增加录音时防止系统自动休眠逻辑
- **原因**: 确保长时录制过程中，即便无人操作，系统也不会因自动休眠而中断录音进程。
- **影响**: 
    - 录音开启后申请 `NoIdleSleepAssertion`。
    - 允许屏幕正常关闭以节省电力，但核心系统逻辑持续运行。
    - 录音结束或异常保存时自动释放电源断言。


# [2026-01-13 00:25]
- **变更内容**: 支持自定义录音时长上限
- **原因**: 满足用户针对不同会议/访谈场景对自动停止的灵活需求。
- **影响**: 
    - `SettingsView` 增加小时/分钟选择器。
    - `AudioRecorderManager` 实现动态上限监测与提醒。


# [2026-01-13 00:15]
- **变更内容**: 核心录音架构重构 (Fragmented MP4)
- **原因**: 响应用户反馈，废除不健康的“60秒切片”逻辑，参考 Voice Memos 实现单文件高可靠录音。
- **影响**: 
    - 引入 `AVAudioEngine` + `AVAssetWriter` 实现单文件 fMP4 录制。
    - 彻底移除对 `ffmpeg` 的依赖。
    - 实现“零成本”崩溃恢复：崩溃后文件天然可播。

# [2026-01-13 00:05]
- **变更内容**: 深度重构 PRD 与架构文档
- **原因**: 基于现有代码库细节，提供更详尽的需求与技术说明。
- **影响**: 
    - 细化了对分段录音（旧版）、崩溃恢复、ASR、AI 总结等全链路逻辑的文字表述。

# [2026-01-12 23:30]
- **变更内容**: 初始化项目基础文档
- **原因**: 建立符合 Solo 模式规范的项目管理基座。
- **影响**: 
    - 创建了工程化的 `docs/` 目录。
    - 建立了 `prd.md`、`architecture.md` 及初版 `changelog.md`。
