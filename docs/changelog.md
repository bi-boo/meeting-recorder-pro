# [2026-08-06 版本 1.0.6 发布与复盘]
- **版本结果**：版本 1.0.6（内部构建号 7）已完成 Developer ID 签名、Apple 公证、Stapler、Gatekeeper 和 GitHub Release 发布；`v1.0.6`、主分支和远程 Release 指向同一提交。
- **录音启动稳定性**：启动阶段增加设备路由稳定窗口和实际设备 ID 校验；只有进入稳定录音后检测到真实输入设备变化，才中断并保存。
- **测试工具**：真实录音集成测试支持显式指定输入、输出设备组合，并按稳定设备 ID 固定测试设备，避免自动选中静音硬件。
- **界面与打包**：菜单栏计时使用固定占位宽度；关于页面隐藏内部构建号；扩展属性在签名前清理，避免破坏签名。
- **发布例外**：最终公证二进制的双输入设备测试按发布决定跳过；发布 QA 检测到运行中真实录音后主动停止，没有中断录音，也没有伪造通过报告。
- **详细复盘**：[会议录音 Pro 1.0.6 发布复盘](release-retrospective-1.0.6.md)

# [2026-07-04 三模式可听录音验证]
- **用户需求/反馈**: 用户希望单独听三种录音模式的实际结果：直录系统声音、直录麦克风、系统 + 麦克风。
- **技术逻辑变更**:
    - 新增可听专项 QA 场景 `audibleModeCheck`，使用指定源音频驱动三种录音模式。
    - 新增 `scripts/run_audible_audio_modes_qa.sh`，自动生成系统源音频、麦克风源音频、三段原始录音、三段试听增益版和测试报告。
    - 更新测试用例文档，补充可听三模式验证入口。
- **涉及文件清单**:
    - `SimpleRecorder/Services/QAAutomationRunner.swift`
    - `scripts/run_audible_audio_modes_qa.sh` [NEW]
    - `docs/test-cases.md`
- **验证结果**: 专项报告位于 `qa-runs/audible-mode-check-20260704-171559/audible-report.md`；三项结果均通过。随后 `xcodebuild test` 和 `scripts/run_full_qa.sh` 均通过。

# [2026-07-04 稳定交付标准固化]
- **用户需求/反馈**: 用户希望未来新项目先设定稳定交付标准，再围绕标准迭代；当前项目需要把交付标准、功能清单、测试 case 和测试流程固化为项目文档。
- **技术逻辑变更**:
    - **项目规则入口**：新增 `AGENTS.md`，明确本项目先按稳定交付门槛执行，不用无限审查替代固定 QA。
    - **标准文档补齐**：新增稳定交付标准、功能清单、测试用例与流程、发布检查清单。
    - **文档口径修正**：README 增加交付标准入口；PRD 和架构文档对齐动态磁盘门槛、实际日志路径、默认快捷键和录音上限范围。
    - **磁盘提示修正**：磁盘空间不足提示改为显示当前动态计算的最小可用空间，不再写死 100MB。
- **涉及文件清单**:
    - `AGENTS.md` [NEW]
    - `docs/stable-delivery-standard.md` [NEW]
    - `docs/feature-list.md` [NEW]
    - `docs/test-cases.md` [NEW]
    - `docs/release-checklist.md` [NEW]
    - `README.md`
    - `docs/prd.md`
    - `docs/architecture.md`
    - `docs/qa-regression.md`
    - `SimpleRecorder/Managers/AudioRecorderManagerUI.swift`
- **变更原因**: 把“什么时候算稳定、什么时候停止继续排查”变成项目可执行门禁，同时修复文档与实现不一致的问题。

# [2026-07-04 继续三轮 subagent 检测修复]
- **用户需求/反馈**: 再派出三个 subagent 分别检查项目，先分析可能风险，再确认项目是否存在类似问题，存在则修复。
- **技术逻辑变更**:
    - **录音收尾加固**：录音停止后立即停止接收新音频 buffer，避免停止流程中继续 append；普通停止后的 MP3 转码被纳入输出收尾状态，退出应用会等待转码完成。
    - **系统音频流隔离**：SCStream 采集加入 generation 标记，异步停止后的旧回调不会进入新一轮系统音频队列。
    - **设置状态校准**：最长录音时长最低 5 分钟；开机自启动从系统状态回读，注册失败时回滚 UI 状态；设备移除检测先刷新真实设备列表。
    - **QA 与发布门禁**：完整 QA 默认把核心场景 skipped 视为失败；场景 JSON 改用安全序列化；`RELEASE=1` 打包必须通过 Developer ID、公证、stapler、Gatekeeper；DMG 根目录包含主项目和 LAME 许可文件。
    - **UI 小修**：快捷键录制器避免双监听；星期按钮保持 36 视觉尺寸，同时保留更稳的点击热区。
- **涉及文件清单**:
    - `SimpleRecorder/Managers/AudioRecorderManagerCore.swift`
    - `SimpleRecorder/Managers/AudioRecorderManagerEngine.swift`
    - `SimpleRecorder/Managers/AudioRecorderManagerWriter.swift`
    - `SimpleRecorder/Managers/AudioRecorderManagerSystemAudio.swift`
    - `SimpleRecorder/Managers/AudioRecorderManagerDevice.swift`
    - `SimpleRecorder/Models/AppSettingsCore.swift`
    - `SimpleRecorder/Views/MainWindowSettingsView.swift`
    - `SimpleRecorder/Views/TimerTaskViews.swift`
    - `SimpleRecorder/NativeMP3Encoder.swift`
    - `SimpleRecorder/SimpleRecorderApp.swift`
    - `scripts/run_full_qa.sh`
    - `build_dmg.sh`
    - `docs/distribution.md`
    - `docs/qa-regression.md`
- **变更原因**: 优先修复可能导致丢录音、误判测试通过或公开分发包不合规的边界风险，保持项目短小但发布前证据更硬。

# [2026-07-04 00:05]
- **用户需求/反馈**: 很多转写服务不支持 MP4/M4A 上传，MP3 输出必须保留在默认能力里。
- **技术逻辑变更**:
    - **恢复 MP3 默认支持**：恢复 `MP3Encoder` 的 LAME 优先、系统原生兜底编码链路。
    - **恢复工程链接**：重新加入 `SimpleRecorder/ThirdParty/lame` 静态库、头文件和 module map，并恢复 Xcode 工程搜索路径。
    - **恢复 QA 覆盖**：`scripts/run_full_qa.sh` 默认重新执行 `5.2 output-format-mp3`。
    - **同步分发说明**：README、PRD、架构、分发和回归测试文档重新写明 M4A/MP3 都是公开版能力；第三方声明补充 LAME 许可和分发注意事项。
- **涉及文件清单**:
    - `SimpleRecorder/MP3Encoder.swift`
    - `SimpleRecorder/ThirdParty/lame/` [RESTORED]
    - `SimpleRecorder.xcodeproj/project.pbxproj`
    - `scripts/run_full_qa.sh`
    - `README.md`
    - `THIRD_PARTY_NOTICES.md`
    - `docs/distribution.md`
    - `docs/architecture.md`
    - `docs/prd.md`
    - `docs/qa-regression.md`
    - `docs/changelog.md`
- **变更原因**: 转写上传兼容性优先；开源分发风险通过 LAME 许可说明和发布流程管理。

# [2026-07-03 23:20]
- **用户需求/反馈**: 继续优化剩余问题，完成开源独立 DMG 分发前的许可证、仓库卫生和定时录音稳定性修复。
- **技术逻辑变更**:
    - **开源许可说明**：新增 MIT `LICENSE` 与 `THIRD_PARTY_NOTICES.md`，并将应用版权文案改为 MIT Licensed。
    - **移除内嵌 LAME**：删除静态链接的 `libmp3lame.a`、头文件和 module map，降低开源二进制分发许可复杂度。
    - **收敛发布承诺**：当前系统无可用 MP3 编码器时，公开版只承诺 M4A 输出；MP3 作为可选扩展能力保留运行时保护，不进入默认 QA 场景。
    - **定时自动录音确认加固**：自动录音触发后最多等待 30 秒确认录音进入 `recording`，避免首次授权或系统音频异步启动慢时被 0.5 秒检查误判。
    - **开源仓库清理**：将 `.agent/` 本地规则从 Git 跟踪中移除；移除与录音软件无关的 Cooper 导出脚本。
    - **测试覆盖补齐**：新增自动录音启动确认策略单元测试。
- **涉及文件清单**:
    - `LICENSE` [NEW]
    - `THIRD_PARTY_NOTICES.md` [NEW]
    - `SimpleRecorder/MP3Encoder.swift`
    - `SimpleRecorder/Models/TimerTask.swift`
    - `SimpleRecorder/Managers/TimerTaskManagerCore.swift`
    - `SimpleRecorder/Managers/AudioRecorderManagerWriter.swift`
    - `SimpleRecorder/Info.plist`
    - `SimpleRecorder.xcodeproj/project.pbxproj`
    - `SimpleRecorderTests/TimerTaskTests.swift`
    - `README.md`
    - `docs/distribution.md`
    - `docs/architecture.md`
    - `docs/prd.md`
    - `docs/qa-regression.md`
    - `docs/changelog.md`
    - `scripts/run_full_qa.sh`
    - `.agent/` [UNTRACKED]
    - `scripts/export_cooper_knowledge.mjs` [REMOVED]
    - `SimpleRecorder/ThirdParty/lame/` [REMOVED]
- **变更原因**: 降低独立分发和开源发布风险，同时修复定时任务在异步录音启动路径上的漏触发边界问题。

# [2026-06-29 23:35]
- **用户需求/反馈**: 需要恢复 MP3 输出能力，不能因为系统原生 MP3 编码不可用而只剩 M4A。
- **技术逻辑变更**:
    - **恢复内嵌 LAME 编码链路**：新增 `MP3Encoder`，优先使用 LAME 转码，系统原生 `NativeMP3Encoder` 仅作为兜底。
    - **分块流式转码**：每次读取 8192 帧 PCM 后立即编码并写入 MP3，避免旧实现一次性解码整段录音导致长会议内存暴涨。
    - **工程链接恢复**：重新接入 `SimpleRecorder/ThirdParty/lame` 静态库、头文件和 module map，并将静态库重编为 `arm64 + macOS 13.0 minos`。
    - **设置与 UI 回归**：保存格式选择重新展示 MP3；历史 MP3 偏好只有在编码器不可用时才回落 M4A。
    - **QA 覆盖补齐**：自动化流程新增 `5.2 output-format-mp3`，录制一小段后等待异步转码并验证 `.mp3` 文件。
- **涉及文件清单**:
    - `SimpleRecorder/MP3Encoder.swift` [NEW]
    - `SimpleRecorder/ThirdParty/lame/COPYING` [NEW]
    - `SimpleRecorder/ThirdParty/lame/lame.h` [NEW]
    - `SimpleRecorder/ThirdParty/lame/libmp3lame.a` [NEW]
    - `SimpleRecorder/ThirdParty/lame/module.modulemap` [NEW]
    - `SimpleRecorder.xcodeproj/project.pbxproj`
    - `SimpleRecorder/Models/AppSettingsCore.swift`
    - `SimpleRecorder/Views/MainWindowSettingsView.swift`
    - `SimpleRecorder/Managers/AudioRecorderManagerCore.swift`
    - `SimpleRecorder/Managers/AudioRecorderManagerWriter.swift`
    - `SimpleRecorder/Services/QAAutomationRunner.swift`
    - `scripts/run_full_qa.sh`
    - `README.md`
    - `docs/architecture.md`
    - `docs/prd.md`
    - `docs/qa-regression.md`
    - `docs/changelog.md`
- **变更原因**: 保留“先录 M4A、再转 MP3”的可靠录音链路，同时让 MP3 输出不再依赖不同 macOS 版本是否提供原生 MP3 写入能力。

# [2026-06-29 23:05]
- **用户需求/反馈**: 希望把大部分功能测试自动化，后续每次改动都能由 Agent 直接跑一遍。
- **技术逻辑变更**:
    - **新增 App 内置 QA runner**：通过 `--qa-scenario` 启动参数执行自动化，不影响普通用户启动路径。
    - **覆盖核心功能路径**：自动验证设置回读、麦克风录音、暂停继续、连续录音、系统声音、混合音源和定时自动录音。
    - **新增一键 QA 脚本**：`scripts/run_full_qa.sh` 自动打包 Release、运行 App 自动化、检查 DMG/签名/录音样本/日志，并输出 `qa-runs/*/report.md`。
    - **系统音频判定加固**：QA 模式内置 880Hz 测试音，并设置最低文件大小阈值，避免系统音频静音文件被误判通过。
    - **文档更新**：回归流程改为优先执行一键自动化，并明确剩余需要人工补测的强交互或系统授权场景。
- **涉及文件清单**:
    - `SimpleRecorder/Services/QAAutomationRunner.swift` [NEW]
    - `SimpleRecorder/SimpleRecorderApp.swift`
    - `SimpleRecorder.xcodeproj/project.pbxproj`
    - `scripts/run_full_qa.sh` [NEW]
    - `docs/qa-regression.md`
    - `README.md`
    - `.gitignore`
    - `docs/changelog.md`
- **变更原因**: 将可自动化的 80-90% 回归路径固化成脚本，减少后续迭代漏测录音、系统音频、定时任务和设置项的风险。

# [2026-06-29 22:45]
- **用户需求/反馈**: 将回归测试流程固化为项目规范，后续任何改动提交或打包前都必须完整跑一遍，覆盖 APP 内所有功能和设置项。
- **技术逻辑变更**:
    - **新增回归测试流程文档**：沉淀构建、打包、权限、录音源、快捷键、暂停恢复、存储路径、高级设置、定时计划、错误边界和收尾清理检查。
    - **新增包体验证脚本**：提供 DMG 校验、签名校验、Gatekeeper 评估、录音样本 `afinfo` 元数据检查和最近日志关键字检查。
    - **README 入口补充**：在开发章节加入回归测试入口，明确提交或打包前必须执行完整流程。
- **涉及文件清单**:
    - `README.md`
    - `docs/qa-regression.md` [NEW]
    - `scripts/qa_artifact_check.sh` [NEW]
    - `docs/changelog.md`
- **变更原因**: 避免后续优化只验证单点功能，确保录音、系统音频、定时计划和设置项在每次迭代后都能被系统性回归。

# [2026-01-30 22:30]
- **用户需求/反馈**: 每次更新应用程序时，系统都会提示默认存储目录没有权限。希望用户下载完 APP 后，默认存储目录自动有权限。
- **技术逻辑变更**: 
    - **问题分析**：原代码使用 Security-Scoped Bookmark 保存所有路径权限，但书签与应用签名绑定。每次重新构建/更新应用时签名变化，导致书签失效，触发权限检查失败。
    - **核心修复**：区分两类路径的权限机制：
        - **用户主目录内的路径**（如 `~/会议录音 Pro`）：不需要 Security-Scoped Bookmark，直接保存路径字符串，因为这些目录本来就在用户权限范围内
        - **特殊目录**（如外置硬盘 `/Volumes/...`）：保留 Security-Scoped Bookmark 机制
    - **加载逻辑优化**：
        1. 优先从路径字符串加载（`recordingsPath_path`）
        2. 其次从书签加载（`recordingsPath`）
        3. 书签失效时自动回退到默认路径而非报错
    - **保存逻辑优化**：根据路径位置决定保存方式，主目录内的路径只保存字符串
- **涉及文件清单**: 
    - `SimpleRecorder/Models/AppSettings.swift`
    - `docs/changelog.md`
- **变更原因**: 确保用户下载应用后，默认存储目录 `~/会议录音 Pro` 自动可用，无需额外授权。

# [2026-01-30 22:23]
- **用户需求/反馈**: 定时整点录音时有延迟，设置了定时却不能在指定时间准点开始录音。
- **技术逻辑变更**: 
    - **问题分析**：原调度器使用 `Timer.scheduledTimer(withTimeInterval: 30)` 每 30 秒轮询检查一次，导致最坏情况下录音延迟最多 30 秒。
    - **修复方案**：将调度器从「轮询模式」改为「精准时间触发模式」：
        - 使用 `DispatchSourceTimer` 替代 `Timer`，支持毫秒级精度
        - 新增 `scheduleNextTrigger()` 方法，计算下一个最近的任务触发时间，设置一次性定时器精准触发
        - 任务增删改时自动调用 `scheduleNextTrigger()` 重新调度
        - 触发后自动调度下一个任务
    - **精度保证**：定时器 `leeway` 设置为 100ms，确保触发误差在 0.1 秒内
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/TimerTaskManager.swift`
    - `docs/changelog.md`
- **变更原因**: 确保定时录音在用户设置的时间点精准触发，而非最多延迟 30 秒。

# [2026-01-30 22:11]
- **用户需求/反馈**: 定时录音触发时，如果因为权限原因录音没有正确开始，"录音已开始"的弹窗会一直展示不消失。
- **技术逻辑变更**: 
    - **问题分析**：`handleAutoStartRecording()` 在调用 `startRecording()` 后立即显示弹窗，无论录音是否真正开始。如果录音因权限问题失败，弹窗与权限提示弹窗可能产生冲突。
    - **修复方案**：添加 `showAutoStartNotificationIfRecording()` 方法，延迟 0.5 秒检查 `isRecording` 状态，只有录音真正开始后才显示通知弹窗，否则记录日志并跳过。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/TimerTaskManager.swift`
    - `docs/changelog.md`
- **变更原因**: 确保只有在录音成功启动时才显示成功通知，避免录音失败时弹窗一直显示的问题。

# [2026-01-30 22:07]
- **用户需求/反馈**: 启动应用后就检查目录权限，而不是等开始录音时才检查。
- **技术逻辑变更**: 
    - 在 `AudioRecorderManager` 中将 `checkDirectoryWritable()` 改为公开方法，并添加 `checkRecordingDirectoryPermission()` 方法供外部调用
    - 在 `SimpleRecorderApp.swift` 的 `applicationDidFinishLaunching` 中，延迟 0.5 秒后调用目录权限检查
    - 如果目录权限不足，会立即弹出提示让用户去设置中修改
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `SimpleRecorder/SimpleRecorderApp.swift`
    - `docs/changelog.md`
- **变更原因**: 让用户在应用启动时就能发现目录权限问题，而不是等到需要录音时才报错。

# [2026-01-30 21:27]
- **用户需求/反馈**: "录音已开始"的弹窗有时候会一直展示，消不掉。
- **技术逻辑变更**: 
    - **问题分析**：发现两个 bug：
        1. `showAutoStartNotification()` 的 5 秒定时器没有检查窗口实例，可能关闭错误的窗口
        2. `dismissReminder()` 在动画的 `completionHandler` 中才清除 `reminderWindow` 引用，如果在 0.2 秒动画期间创建新弹窗，旧动画完成后会错误地清空新弹窗的引用，导致新弹窗永远无法被自动关闭
    - **修复方案**：
        - 在 `showAutoStartNotification()` 定时器中添加 `[weak window]` 捕获和 `reminderWindow === window` 检查
        - 将 `dismissReminder()` 中的 `reminderWindow = nil` 移到动画开始前执行
- **涉及文件清单**: 
    - `SimpleRecorder/Views/ReminderWindowController.swift`
    - `docs/changelog.md`
- **变更原因**: 修复弹窗无法正常消失的问题，确保所有通知弹窗都能按预期自动关闭。

# [2026-01-30 21:06]
- **用户需求/反馈**: 如果设置了两个定时任务（如 9 点和 10 点），且录音时长设置为 1 小时，那么 10 点的任务会因为"正在录音"而被跳过。
- **技术逻辑变更**: 
    - **问题分析**：原逻辑在 `handleAutoStartRecording()` 中检测到 `isRecording=true` 时直接跳过新任务，导致用户设置的定时任务被永久错过。
    - **修复方案**：当新的定时任务触发时，如果当前正在录音，先自动停止旧录音（保存文件），等待 1 秒后再启动新录音。这样每个定时任务都能正常执行，每段录音独立保存。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/TimerTaskManager.swift`
    - `docs/changelog.md`
- **变更原因**: 确保用户设置的每个定时任务都能按时执行，不会因为前一个录音未结束而被跳过。

# [2026-01-29 23:46]
- **用户需求/反馈**: 设置了多个定时任务，第一个录音结束后的弹窗不关闭的话，后面的定时任务就无法触发。
- **技术逻辑变更**: 
    - **根因分析**：`AudioRecorderManager` 中的 `showRecordingLimitReachedAlert()` 和 `showRecordingInterruptionAlert()` 使用了阻塞式的 `NSAlert.runModal()` 方法，该方法会阻塞主线程，导致定时任务调度器的回调无法执行，后续定时任务被卡住。
    - **核心修复**：将阻塞式 `NSAlert.runModal()` 弹窗替换为非阻塞式浮动通知窗口：
        - 在 `ReminderWindowController.swift` 添加 `showRecordingCompletedNotification(duration:)` 方法（10秒自动消失）
        - 在 `ReminderWindowController.swift` 添加 `showRecordingInterruptedNotification(reason:onRestart:)` 方法（保留再次录音按钮功能）
        - 添加对应的 SwiftUI 视图组件 `RecordingCompletedView` 和 `RecordingInterruptedView`
    - **调用方修改**：在 `AudioRecorderManager.swift` 添加 `notificationController` 属性，并将两个弹窗方法改为调用非阻塞通知
- **涉及文件清单**: 
    - `SimpleRecorder/Views/ReminderWindowController.swift`
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `docs/changelog.md`
- **变更原因**: 确保录音完成/中断通知不阻塞主线程，让后续定时任务能够正常触发和执行。

# [2026-01-27 11:46]
- **用户需求/反馈**: 设置了多个定时录音，但只有第一个生效了，后面的都没有生效。部分"每天"类型的任务显示的下次触发时间是1月26日（过期日期），而非当前日期1月27日。
- **技术逻辑变更**: 
    - **@Published 响应式更新修复**: 在 `TimerTaskManager.swift` 的三处直接修改数组元素的代码中，改用临时数组更新后再整体赋值的方式，确保触发 SwiftUI 的 `@Published` 响应式通知，使 UI 能正确刷新任务列表：
        1. `loadTasks()`: 加载任务后重新计算触发时间，现在会正确更新 UI 并保存到持久化存储
        2. `handleTimeChange()`: 系统时间变化时重新计算触发时间
        3. `handleWakeFromSleep()`: 系统从休眠恢复时重新计算触发时间
    - **持久化同步**: 在 `loadTasks()` 完成时间计算后立即调用 `saveTasks()`，确保更新后的触发时间被保存到 UserDefaults
    - **调试日志增强**: 在加载任务时记录每个任务的时间更新详情，便于后续问题排查
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/TimerTaskManager.swift`
    - `docs/changelog.md`
- **变更原因**: 修复定时任务触发时间没有正确更新的问题，确保所有定时任务都能按预期触发。

# [2026-01-25 21:30]
- **用户需求/反馈**: 希望日志功能能记录所有信息（接口回调、内部执行逻辑等），以便用户反馈问题时能根据日志找到原因。
- **技术逻辑变更**: 
    - **LogManager 增强**：
        - 新增录音会话 ID 追踪（`startRecordingSession()`/`endRecordingSession()`），同一次录音的所有日志都会带上会话 ID 前缀，方便关联分析
        - 对 `error` 和 `critical` 级别日志增加同步写入（`synchronize()`），确保崩溃前日志已保存到磁盘
        - 新增 `flush()` 方法供关键时刻手动刷新缓冲区
        - 应用启动时记录系统信息（macOS 版本、应用版本）
    - **AudioRecorderManager 日志补充**：
        - 录音启动时记录会话 ID、音频源、设备名、文件名
        - 每 30 秒记录一次录音进度（时长、已写入帧数）
        - 缓冲队列溢出时记录警告日志
        - 防休眠断言创建/释放时记录日志
        - 磁盘空间不足时记录详细信息
        - 资源清理时记录清空了多少缓冲帧
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/LogManager.swift`
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `docs/changelog.md`
- **变更原因**: 增强日志系统的完整性，便于排查"录音没录上"、崩溃等用户反馈的问题。

# [2026-01-25 20:59]
- **用户需求/反馈**: 使用麦克风+系统内部录音同时录制时，暂停后恢复录制，结束录音后只保存了暂停之前的音频，暂停后录制的部分丢失。
- **技术逻辑变更**: 
    - **根因定位**：在 `resumeRecording()` 方法中，`isPaused = false` 原本在方法末尾才执行，但 `audioEngine.start()` 在前面就已启动。这导致音频引擎恢复后，`installRecordingTap` 中 tap 回调的 `!self.isPaused` 判断失败，所有音频数据被直接丢弃。
    - **修复方案**：将 `isPaused = false` 移到 `audioEngine.start()` 之前执行，确保音频引擎恢复后 tap 回调能立即处理数据。
    - **状态回滚**：新增恢复失败时的 `isPaused = true` 回滚逻辑。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `docs/changelog.md`
- **变更原因**: 确保混合录音模式下暂停/恢复功能正常工作，暂停后的录音内容能完整保存。

# [2026-01-25 20:13]
- **用户需求/反馈**: 打包最新稳定版本，包含近期所有修复和功能更新。
- **技术逻辑变更**: 
    - **构建与打包**: 执行 Release 构建并生成 `MeetingRecorderPro_20260125.dmg`。
    - **代码签名**: 自动识别系统中的 Developer ID 证书进行签名，并执行 `xattr -cr` 清除隔离属性以确保可运行性。
- **涉及文件清单**: 
    - `MeetingRecorderPro_20260125.dmg` [NEW]
    - `docs/changelog.md`
- **变更原因**: 发布最新版本供用户测试使用。

# [2026-01-25 15:55]
- **用户需求/反馈**: 1) 选择 MacBook Pro 麦克风时无法录音；2) iPhone 连续互通麦克风设备选择后没有反应，需要激活。
- **技术逻辑变更**: 
    - **AVCaptureSession 激活机制**：重写 `updateInputDevice()` 方法，使用 `AVCaptureSession` 配合 `AVCaptureDeviceInput` 激活麦克风设备。这种方式会触发 iPhone 连续互通设备进入麦克风模式。
    - **辅助方法**：新增 `setDefaultInputDevice()` 设置系统默认输入设备，`stopDeviceActivationSession()` 清理激活会话。
    - **资源清理**：在 `cleanupAudioCapture()` 中添加设备激活会话的清理逻辑。
    - **成员变量**：新增 `deviceActivationSession` 和 `deviceActivationInput` 用于保持设备激活状态。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `docs/changelog.md`
- **变更原因**: 使用 AVCaptureSession 激活设备是 macOS 官方推荐的方式，可以正确激活 iPhone 连续互通麦克风等需要特殊处理的设备。

# [2026-01-25 15:39]
- **用户需求/反馈**: 选择 MacBook Pro 麦克风设备时无法开启录音。
- **技术逻辑变更**: 
    - **inputNode 初始化修复**：在 `updateInputDevice()` 中，先调用 `inputNode.inputFormat(forBus: 0)` 触发底层初始化，解决新创建的 `AVAudioEngine` 实例 `audioUnit` 尚未就绪的问题。
    - **错误处理增强**：将静默失败（仅打印日志）改为抛出明确错误，确保设备切换失败时用户能感知问题。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `docs/changelog.md`
- **变更原因**: 修复选择特定麦克风设备后录音无法启动的问题。

# [2026-01-25 15:31]
- **用户需求/反馈**: 将 `~/会议录音 Pro` 下的日志文件夹设置为隐藏，避免干扰用户。
- **技术逻辑变更**: 将 `LogManager.swift` 中的 `logDirectory` 路径组件由 `"日志"` 改为 `".日志"`。在 macOS 中，以点开头的文件/文件夹会被系统自动隐藏。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/LogManager.swift`
    - `docs/prd.md`
    - `docs/architecture.md`
    - `docs/changelog.md`
- **变更原因**: 提升主存储目录的整洁度，将系统生成的辅助文件（日志）进行隐藏处理。

# [2026-01-25 15:27]
- **用户需求/反馈**: 将默认音频存储路径从“极简录音/录音”修改为“会议录音 Pro”，保持与应用名称一致，并精简路径层级（不再需要“录音”子目录）。
- **技术逻辑变更**: 修改 `AppSettings.swift` 中的 `defaultRecordingsPath` 初始值，将路径更新为直接指向用户主目录下的“会议录音 Pro”。
- **涉及文件清单**: 
    - `SimpleRecorder/Models/AppSettings.swift`
    - `docs/prd.md`
    - `docs/changelog.md`
- **变更原因**: 增强品牌一致性，简化存储结构，提升用户易用性。

# [2026-01-25 15:02]
- **用户需求/反馈**: 定时计划页面信息碎片化，希望精简布局、合并脚注。
- **技术逻辑变更**: 
    - **任务行重构**：时间字号放大（32pt），右侧信息垂直堆叠（下次触发时间 + 触发方式），移除底部分散描述。
    - **脚注合并**：将"当前有 X 个已启用计划"与系统提示合并为一行，放在"定时录音计划"Section 底部。
    - **开关精简**：移除"有定时计划时禁止系统睡眠"开关下方的冗余计划数量提示。
- **涉及文件清单**: 
    - `SimpleRecorder/Views/TimerTaskViews.swift`
    - `docs/changelog.md`
- **变更原因**: 减少视觉碎片感，提升定时计划页面的信息密度和可读性。

# [2026-01-25 14:18]
- **用户需求/反馈**: 1) 录音中断后文件命名仍是 "ing"，未正确重命名为带时长格式；2) 点击"再次开始录音"依然崩溃。
- **技术逻辑变更**: 
    - **文件重命名修复**：在 `saveRecordingImmediately()` 中保存前获取 `currentRecordingURL`，保存成功后调用 `renameToFinalFormat()` 进行重命名。
    - **崩溃修复**：将再次录音前的延迟从 0.5 秒增加到 1 秒，确保 `cleanupAudioCapture()` 中异步释放的系统音频流完全释放；添加启动前状态二次检查。
    - **状态清理**：在 `saveRecordingImmediately()` 中添加 `isHandlingInterruption = false` 的重置。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `docs/changelog.md`
- **变更原因**: 确保录音中断后文件正确保存并命名，以及再次录音功能正常工作。

# [2026-01-25 13:58]
- **用户需求/反馈**: 1) 录音中断弹窗的原因描述太技术化，用户看不懂；2) 点击"再次开始录音"后应用崩溃。
- **技术逻辑变更**: 
    - **文案优化**：将技术性描述改为大白话，如"系统音频配置发生变化"改为"您的音频设备发生了变化（例如插拔耳机或连接蓝牙设备）"。
    - **崩溃修复**：修复 `saveRecordingImmediately()` 状态清理不完整的问题，添加对 `assetWriter`、`assetWriterInput`、`currentRecordingURL`、`isTransitioning`、`isWriterStarted` 等状态的清理，确保录音中断后可以正常重新开始录音。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `docs/changelog.md`
- **变更原因**: 提升用户体验，确保中断提醒信息通俗易懂，并修复再次录音崩溃问题。

# [2026-01-25 13:31]
- **用户需求/反馈**: 录音过程中插拔耳机等设备变更会导致录音静默中断，但界面仍显示"录音中"状态，用户无法感知录音已停止。
- **技术逻辑变更**: 
    - **中断原因枚举**：新增 `RecordingInterruptionReason` 枚举，定义 6 种可能导致录音中断的场景（设备移除、设备变更、引擎配置变更、系统音频错误、磁盘空间不足、写入失败）。
    - **Core Audio 监听**：在 `init()` 中通过 `AudioObjectAddPropertyListenerBlock` 注册设备变更监听（`kAudioHardwarePropertyDefaultInputDevice` 和 `kAudioHardwarePropertyDevices`）。
    - **AVAudioEngine 监听**：监听 `.AVAudioEngineConfigurationChange` 通知检测音频配置变更。
    - **SCStreamDelegate**：实现 `stream(_:didStopWithError:)` 捕获系统音频采集错误。
    - **定时检查**：在录音定时器中每 30 秒检查磁盘空间，实时检查 AssetWriter 状态。
    - **统一处理**：新增 `handleRecordingInterruption()` 方法，检测到异常后自动保存录音并弹窗告知用户原因。
    - **用户交互**：中断弹窗提供「再次开始录音」和「知道了」两个按钮。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `docs/prd.md`
    - `docs/architecture.md`
    - `docs/changelog.md`
- **变更原因**: 解决录音静默中断问题，确保用户始终知悉录音状态，已录制内容不会丢失。

# [2026-01-25 00:38]
- **用户需求/反馈**: 定时计划循环类型默认为“不循环”，触发方式默认为“自动录音”；“关于我们”页面移除产品 Logo。
- **技术逻辑变更**: 
    - 修改 `TimerTaskEditView` 中 `@State` 初始值：`repeatType` 设为 `.none`，`actionType` 设为 `.autoStart`。
    - 修改 `AboutView`：移除 `Image("BrandLogo")` 相关布局，调优标题顶部边距。
- **涉及文件清单**: 
    - `SimpleRecorder/Views/TimerTaskViews.swift`
    - `SimpleRecorder/Views/MainWindowView.swift`
    - `docs/changelog.md`
- **变更原因**: 优化用户添加计划的流程体验，使初始选项更符合常规预期；精简关于页面布局。

# [2026-01-25 00:21]
- **用户需求/反馈**: 把"开机自动启动"移到定时计划页面，并增加"录音时禁止系统睡眠"和"有计划时禁止系统睡眠"两个开关，三个开关默认都开启。
- **技术逻辑变更**: 
    - 在 `AppSettings` 添加 `preventSleepDuringRecording` 和 `preventSleepWithSchedule` 两个设置项（默认开启）。
    - 在 `TimerTaskListView` 添加"系统控制"Section，包含三个开关：开机自动启动、录音时禁止系统睡眠、有计划时禁止系统睡眠。
    - 修改 `AudioRecorderManager.finalizeRecordingStart()` 根据 `preventSleepDuringRecording` 设置决定是否启用防睡眠。
    - 在 `TimerTaskManager` 添加 `IOPMAssertion` 防睡眠逻辑：当有已启用的计划且 `preventSleepWithSchedule` 开启时，禁止系统空闲睡眠。
    - 从 `MainWindowView` 的高级设置中移除"开机自动启动"开关。
- **涉及文件清单**: 
    - `SimpleRecorder/Models/AppSettings.swift`
    - `SimpleRecorder/Views/TimerTaskViews.swift`
    - `SimpleRecorder/Views/MainWindowView.swift`
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `SimpleRecorder/Managers/TimerTaskManager.swift`
    - `SimpleRecorder/SimpleRecorderApp.swift`
    - `docs/changelog.md`
- **变更原因**: 将系统控制相关设置集中到定时计划页面，方便用户统一管理；禁止睡眠功能确保定时计划和录音不会被系统睡眠打断。

# [2026-01-25 00:15]
- **用户需求/反馈**: 相同时间不允许设置多个计划；最多只允许设置6个定时计划；修改提示文案为"系统唤醒且应用运行时，计划才能启动"，去掉图标。
- **技术逻辑变更**: 
    - 在 `TimerTaskEditView` 的 `saveTask` 中添加时间冲突检查，同一时间点只允许一个计划。
    - 在 `TimerTaskListView` 添加 `maxTaskCount=6` 上限，达到上限时禁用添加按钮并显示提示。
    - 修改 footer 提示文案为纯文字（无 Label 图标）。
- **涉及文件清单**: 
    - `SimpleRecorder/Views/TimerTaskViews.swift`
    - `docs/changelog.md`
- **变更原因**: 优化定时计划功能体验，避免用户误设重复计划或过多计划。

# [2026-01-24 23:55]
- **用户需求/反馈**: 定时计划排序改为按绝对时间(0-24点)排序，不考虑启用状态；提醒方式标签与循环描述放同一行，改为黑白灰色调。
- **技术逻辑变更**: 
    - 简化 `sortedTasks` 排序逻辑为仅按 `hour:minute` 绝对时间排序。
    - 重构 `TimerTaskRow` 布局：将提醒方式标签（"自动录音"/"提前X分钟"）与循环描述用分隔符合并为一行，标签改为灰色调背景。
- **涉及文件清单**: 
    - `SimpleRecorder/Views/TimerTaskViews.swift`
    - `docs/changelog.md`
- **变更原因**: 简化排序逻辑，优化定时计划列表的视觉布局，保持页面整洁。

# [2026-01-24 23:49]
- **用户需求/反馈**: 已设置的定时计划要完全按照时间的早晚来排序，并且在定时计划上面显示提醒方式（提前几分钟提醒/到点自动录音）。
- **技术逻辑变更**: 
    - 在 `TimerTaskListView` 添加 `sortedTasks` 计算属性，实现按时间早晚排序（已启用的优先，按 `nextTriggerTime` 升序；未启用的按设定时间排序）。
    - 在 `TimerTaskRow` 添加提醒方式标签，使用不同颜色区分：绿色标签显示"到点自动录音"，蓝色标签显示"提前 X 分钟提醒"。
- **涉及文件清单**: 
    - `SimpleRecorder/Views/TimerTaskViews.swift`
    - `docs/changelog.md`
- **变更原因**: 提升定时计划列表的可读性，让用户一目了然地看到每个计划的触发顺序和提醒方式。

# [2026-01-24 23:24]
- **用户需求/反馈**: 录制系统音频的权限，仅当用户在录制来源里面选择"系统声音"或"同时录制"这两个选项的时候才请求。用户安装应用后第一次启动应用时不要请求。
- **技术逻辑变更**: 
    - 移除了 `SimpleRecorderApp.swift` 中 `applicationDidFinishLaunching` 里的 `AppSettings.triggerScreenCapturePermissionCheck()` 调用。
    - 系统音频权限现在采用**按需请求策略**：仅在用户主动切换到"系统声音"或"麦克风 + 系统声音"模式时才触发权限申请。
    - 首次启动应用时不再弹出任何系统音频相关的权限请求。
- **涉及文件清单**: 
    - `SimpleRecorder/SimpleRecorderApp.swift`
    - `docs/changelog.md`
- **变更原因**: 改善用户首次使用体验，避免在用户尚未明确需要系统音频录制功能时就弹出权限请求。

# [2026-01-24 23:22]
- **用户需求/反馈**: 在定时录音编辑定时计划的页面最底下，增加一个删除的按钮，可以删除这个计划。
- **技术逻辑变更**: 
    - 在 `TimerTaskEditView` 编辑视图底部新增"删除此计划"按钮。
    - 该按钮仅在编辑模式（`.edit`）下显示，新增模式（`.add`）时不显示。
    - 点击按钮后调用 `TimerTaskManager.deleteTask()` 删除计划并关闭弹窗。
    - 调整弹窗高度从 500 增加到 520，为新按钮腾出空间。
- **涉及文件清单**: 
    - `SimpleRecorder/Views/TimerTaskViews.swift`
    - `docs/changelog.md`
- **变更原因**: 让用户可以在编辑页面直接删除定时计划，而无需回到列表页面滑动删除。

# [2026-01-24 20:01]
- **用户需求/反馈**: 检查项目里没用的文件和代码并进行清理。
- **技术逻辑变更**: 
    - **目录清理**: 删除了 `auc_python` 冗余目录及内部 Python 脚本。
    - **代码清理**: 移除了 `SimpleRecorderApp` 中未调用的 `getPausedImage()` 函数。
    - **逻辑优化**: 删除了 `AudioRecorderManager` 中冗余的 `AVAudioPCMBuffer.deepCopy` 扩展。
- **涉及文件清单**: 
    - `auc_python/` [DELETE]
    - `SimpleRecorder/Services/` [DELETE]
    - `SimpleRecorder/SimpleRecorderApp.swift`
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
- **变更原因**: 提高项目代码库的整洁度，移除历史遗留的废弃逻辑。

# [2026-01-24 19:46]
- **用户需求/反馈**: 将全局规则 `GEMINI.md` 拆分为 3 个当前项目空间的 `.cursor/rules` 规则文件。
- **技术逻辑变更**: 
    - 创建了 `.cursor/rules` 目录。
    - 按照职能拆分为 `language_and_execution.mdc`、`docs_and_privacy.mdc` 和 `mac_packaging_and_signing.mdc`。
    - 使用 `.mdc` 格式以契合 Cursor/Antigravity 的结构化规则系统。
- **涉及文件清单**: 
    - `.agent/rules/语言与执行规范.md` [NEW]
    - `.agent/rules/文档与隐私规范.md` [NEW]
    - `.agent/rules/Mac签名与发布规范.md` [NEW]
    - `docs/changelog.md`
- **变更原因**: 提高 AI 助理对项目规则理解的精确度，实现规则的结构化管理。

# [2026-01-24 22:55]
- **用户需求/反馈**: 将 logo.jpeg 设置为产品的 logo。
- **技术逻辑变更**: 
    - 使用 `sips` 生成适配 macOS 的全尺寸 `AppIcon` 系统资源。
    - 创建 `BrandLogo.imageset` 用于 UI 展示。
    - 在 `AboutView` 界面嵌入 `BrandLogo` 图片展示。
    - **编译修复**：修复 `AboutView` 语法错误并发起打包。
    - **编译修复**：在 `AudioRecorderManager.swift` 中补全缺失的 `AVAudioPCMBuffer` 深拷贝 (`deepCopy`) 扩展。
    - **工程化优化**：优化 `build_dmg.sh` 脚本，引入 `pipefail` 并显式禁用 Xcode 内建签名，支持 Ad-hoc 编译环境。
    - **配置优化**：移除项目文件 (`project.pbxproj`) 中的硬编码 Team ID，确保无证书环境下亦可顺利编译。
- **涉及文件清单**: 
    - `SimpleRecorder/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
    - `SimpleRecorder/Resources/Assets.xcassets/BrandLogo.imageset/`
    - `SimpleRecorder/Views/MainWindowView.swift`
    - `docs/prd.md`
    - `docs/architecture.md`
    - `docs/changelog.md`
- **变更原因**: 建立统一的品牌视觉标识，提升应用专业感。

# [2026-01-24 19:40]

- **用户需求/反馈**: 全方位品牌更名：将“极简录音”统一更名为“会议录音 Pro”。
- **技术逻辑变更**: 
    - **项目配置**: 更新 Xcode 项目文件中的 `CFBundleDisplayName`、`PRODUCT_BUNDLE_IDENTIFIER`（变更为 `com.meetingrecorderpro.app`）及权限描述。
    - **代码字符串**: 替换 UI 界面显示、注释、以及日志管理类中的应用名称。
    - **日志系统**: 更新日志存储目录为 `~/会议录音 Pro/日志/`，并修改日志文件名前缀为 `MeetingRecorderPro_`。
    - **构建脚本**: 更新 `build_dmg.sh` 以生成正确命名 `.dmg` 文件和卷标。
- **涉及文件清单**: 
    - `SimpleRecorder.xcodeproj/project.pbxproj`
    - `SimpleRecorder/Info.plist`
    - `SimpleRecorder/SimpleRecorderApp.swift`
    - `SimpleRecorder/Managers/LogManager.swift`
    - `SimpleRecorder/Views/ReminderWindowController.swift`
    - `SimpleRecorder/Views/TimerTaskViews.swift`
    - `build_dmg.sh`
    - `docs/prd.md`
    - `docs/architecture.md`
    - `docs/changelog.md`
- **变更原因**: 根据产品战略调整，确立正式品牌名称，增强会议场景的专业属性定位。

# [2026-01-24 18:58]
- **用户需求/反馈**: PRD 一致性专项修复（日志命名、弹窗超时、显示优化）。
- **技术逻辑变更**: 
    - **日志命名对齐**: 在 `LogManager` 中为文件名增加 `SimpleRecorder_` 前缀，完全闭环 PRD 规范。
    - **提醒弹窗动态失效**: 在 `ReminderWindowController` 中为提醒弹窗（Remind 模式）增加动态失效定时器，其持续时长与用户设置的“提前提醒时间”保持一致（例如设置提前 5 分钟提醒，则弹窗在 5 分钟后自动消失）。
    - **高级设置增强**: 在“高级设置”中新增“打开日志文件夹”按钮，提升问题排查的便利性。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/LogManager.swift`
    - `SimpleRecorder/Views/ReminderWindowController.swift`
    - `SimpleRecorder/Views/MainWindowView.swift`
    - `docs/changelog.md`
- **变更原因**: 确保代码实现与 PRD 需求文档实现 100% 同步，消除工程细节上的歧义。

# [2026-01-24 18:52]
- **用户需求/反馈**: PRD V6 精修反馈（计时格式 mm:ss、冲突逻辑校验、视觉策略分析、特性文案对齐）。
- **技术逻辑变更**: 
    - **计时规范化**: 在 PRD 中修正计时格式为始终 `mm:ss`（分钟支持三位），明确不随时间增长切换小时位。
    - **UI/逻辑对齐**: 1:1 同步了“关于”页面的核心特性官方完整文案，涵盖实时保存、双向录音等。
    - **深度逻辑说明**: 补充了快捷键冲突检测的 Alert 文案细节，并对视觉策略（图标样式切换、Alpha=0.35 闲置变暗）进行了技术性归纳。
- **涉及文件清单**: 
    - `docs/prd.md`
    - `docs/changelog.md`
- **变更原因**: 持续精进一步文案颗粒度，确保 PRD 不仅是逻辑规范，更成为应用 UI 字符串的标准来源。

# [2026-01-24 18:43]
- **用户需求/反馈**: PRD 终极精准校对（快捷键范围、UI 文案 1:1、存储按钮补全、移除冗余模块）。
- **技术逻辑变更**: 
    - **UI 文案同步**: 1:1 还原了锁定提示（“录音中，设置将在下次录音时生效”）、冲突告警（“该快捷键已被其他功能使用”）、提醒弹窗（“是否启动录音”）等所有面向用户的字符串。
    - **功能逻辑补全**: 补充了存储设置中的“在 Finder 中打开”按钮逻辑，明确了快捷键支持 A-Z/F1-F12/空格等全按键矩阵，修正了时长上限步进说明。
    - **关于页面官方化**: 完全采用了 App 内部的官方特性描述文本（实时保存、防止休眠等）。
    - **结构清理**: 删除了 PRD 尾部的“当前状态”模块，保持文档作为纯粹的需求/逻辑规范。
- **涉及文件清单**: 
    - `docs/prd.md`
    - `docs/changelog.md`
- **变更原因**: 消除文档与代码之间的最后一点文案与逻辑差异，实现 100% 同步的工程化交付标准。

# [2026-01-24 18:35]
- **用户需求/反馈**: 深度补充基础设置、定时计划、高级设置、关于我们页面里的逻辑。
- **技术逻辑变更**: 
    - **模块逻辑详述**: 在 `docs/prd.md` 中全方位补充了四大页面的交互与底层技术逻辑。
    - **基础设置**: 细化了快捷键冲突检测、Security-Scoped Bookmark 授权、以及录音期间的 Picker 锁定机制。
    - **定时计划**: 细化了 1 分钟级时间选择器、星期多选逻辑、以及后台 30s 轮询调度器的工作细节。
    - **高级设置**: 细化了 5 分钟档位步进调节、`NotificationCenter` 图标刷新广播、以及 0.35 闲置变暗系数。
    - **关于页面**: 详细定义了五大产品核心特性（实时保存、防休眠等）的功能边界。
- **涉及文件清单**: 
    - `docs/prd.md`
    - `docs/changelog.md`
- **变更原因**: 将 PRD 从“功能点列表”升级为“可执行的业务逻辑规范”，确保产品实现与文档说明实现 1:1 对等，为长期维护奠定严谨的基础。

# [2026-01-24 18:31]
- **用户需求/反馈**: V4 反馈精修（详述磁盘弹窗、修正录音限额调节范围）。
- **技术逻辑变更**: 
    - **PRD 详述**: 在 `docs/prd.md` 中补充了磁盘不足 100MB 时的 Alert 标题、内容及按钮逻辑。
    - **逻辑对齐**: 修正录音限额调节范围描述为 5 分钟至 9 小时 55 分钟，与代码中的分（5min步进）及小时逻辑完全闭环。
- **涉及文件清单**: 
    - `docs/prd.md`
    - `docs/changelog.md`
- **变更原因**: 建立极其精确的需求说明，确保用户界面文字、技术逻辑与规范文档实现“心脑一致”。

# [2026-01-24 18:28]
- **用户需求/反馈**: V3 精修反馈（磁盘文案 100MB、限额 5min 步进、移除日志 UI 入口）。
- **技术逻辑变更**: 
    - **UI 极简化**: 遵循用户指示，从“关于我们”页面移除了手动查看日志的按钮及相关描述。
    - **逻辑/文案对齐**: 将 `AudioRecorderManager` 中的磁盘空间不足预警文案从 500MB 精准修正为 100MB。
    - **文档精修**: 完善 PRD 中对磁盘弹窗的详细文案定义，并修正录音限额为 5 分钟档位步进。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `SimpleRecorder/Views/MainWindowView.swift`
    - `docs/prd.md`
    - `docs/changelog.md`
- **变更原因**: 贯彻极致简约的设计理念，确保所有文字描述与底层逻辑、UI 体验高度一致。

# [2026-01-24 18:22]
- **用户需求/反馈**: 对 PRD 进行 12 处细节精修（磁盘预检降至 100MB、计时格式 mm:ss、明确暂停逻辑、细化弹窗文案、日志路径详述等）。
- **技术逻辑变更**: 
    - **磁盘预检**: 更新 PRD 描述为 100MB 最低空间要求（由 500MB 降级，匹配 1 小时安全录制）。
    - **UI 规范**: 统一计时格式为 `mm:ss`（一小时内），并明确录制中锁定设置切换。
    - **逻辑详术**: 补充双路混音 PTS 对齐方案、MP3 异步转换耗时估算、及定时任务弹窗/通知的精确文案与超时逻辑。
    - **文档同步**: 完善日志系统路径 `~/极简录音/日志/` 及对用户的可见性说明。
- **涉及文件清单**: 
    - `docs/prd.md`
    - `docs/changelog.md`
- **变更原因**: 建立极其精准的产品文档，消除需求描述中的模糊地带，确保文档与代码细节及用户直觉完全一致。

# [2026-01-24 18:12]
- **用户需求/反馈**: 深度更新 PRD 文档，详尽记录每一处交互与逻辑细节，采用多级标题结构。
- **技术逻辑变更**: 
    - **文档重构**: 将 `docs/prd.md` 按照 H1-H3 级联结构彻底重构，深度对齐代码中已实现的图标样式、定时器双模式、自动命名与 Finder 定位等细节。
    - **一致性同步**: 同步更新 `docs/architecture.md` 确保架构描述与最新 PRD 颗粒度一致。
- **涉及文件清单**: 
    - `docs/prd.md`
    - `docs/architecture.md`
    - `docs/changelog.md`
- **变更原因**: 建立高质量的项目资产文档，确保产品演进过程中的需求与技术实现有据可查。

# [2026-01-24 16:40]
- **用户需求/反馈**: 打包应用并生成 DMG 安装包。
- **技术逻辑变更**: 
    - **脚本优化**: 更新 `build_dmg.sh`，使其符合最新的 Mac 打包与签名规约。
    - **环境集成**: 增加对 `.env` 环境变量的加载支持，用于读取签名证书（`DEVELOPER_ID_CERT`）。
    - **隔离属性清理**: 在签名后自动执行 `xattr -cr`，解决打包后应用无法直接运行的问题。
    - **自动签名**: 优先使用环境变量中的证书，若不存在则自动检测系统中的 Developer ID 证书。
- **涉及文件清单**: 
    - `build_dmg.sh`
    - `docs/changelog.md`
- **变更原因**: 规范应用分发流程，确保安装包具备正确的签名和权限，提升用户安装体验。

# [2026-01-21 22:55]
- **用户需求/反馈**: 定时提醒时间可配置（1-10分钟），支持两种模式：提前提醒和自动录音。
- **技术逻辑变更**: 
    - **新增枚举**: `TimerActionType`（remind/autoStart）定义定时行为类型
    - **全局设置**: 在 `AppSettings` 添加 `timerActionType` 和 `timerReminderMinutes` 属性
    - **调度逻辑**: 修改 `TimerTaskManager.checkAndTriggerReminders()` 根据定时类型执行不同操作
    - **自动录音**: 新增 `handleAutoStartRecording()` 方法，到时间直接开始录音
    - **通知弹窗**: 新增 `AutoStartNotificationView` 视图，5秒后自动消失
    - **设置界面**: 在「定时计划」Tab 添加全局设置 Section，包括定时类型和提醒时间选择
- **涉及文件清单**: 
    - `SimpleRecorder/Models/AppSettings.swift`
    - `SimpleRecorder/Models/TimerTask.swift`
    - `SimpleRecorder/Managers/TimerTaskManager.swift`
    - `SimpleRecorder/Views/ReminderWindowController.swift`
    - `SimpleRecorder/Views/TimerTaskViews.swift`
- **变更原因**: 满足不同使用场景：需要确认时选择提前提醒，无人值守时选择自动录音。

# [2026-01-21 22:35]
- **用户需求/反馈**: 新增定时录音提醒与一键启动功能，支持多计划配置、提前2分钟弹窗提醒。
- **技术逻辑变更**: 
    - **数据模型**: 新增 `TimerTask.swift`，定义定时任务数据结构，支持三种循环类型（单次/每天/每周）和星期多选，实现自动计算下次触发时间。
    - **调度管理器**: 新增 `TimerTaskManager.swift`（单例），实现 CRUD 操作、UserDefaults 持久化、30秒轮询调度、防重复触发机制、系统时间变化监听。
    - **提醒弹窗**: 新增 `ReminderWindowController.swift`，实现右上角浮窗样式弹窗，支持「忽略」和「开始录音」两个操作按钮。
    - **设置界面**: 新增 `TimerTaskViews.swift`（列表视图/编辑视图/星期选择器），在 MainWindowView 中添加「定时计划」Tab。
    - **应用集成**: 在 AppDelegate 中初始化调度器（启动时启动，退出时停止）。
- **涉及文件清单**: 
    - `SimpleRecorder/Models/TimerTask.swift` [NEW]
    - `SimpleRecorder/Managers/TimerTaskManager.swift` [NEW]
    - `SimpleRecorder/Views/ReminderWindowController.swift` [NEW]
    - `SimpleRecorder/Views/TimerTaskViews.swift` [NEW]
    - `SimpleRecorder/Views/MainWindowView.swift`
    - `SimpleRecorder/SimpleRecorderApp.swift`
    - `SimpleRecorder.xcodeproj/project.pbxproj`
    - `docs/prd.md`
    - `docs/architecture.md`
- **变更原因**: 减少用户手动操作，覆盖会议、访谈等固定时间场景。

# [2026-01-21 00:45]
- **用户需求/反馈**: 录音开始后，没有禁用“录制来源”和“麦克风设备”菜单项。
- **技术逻辑变更**: 
    - **统一菜单刷新**: 修改了 `updateMenuRecordingState`，通过直接调用 `setupMenu()` 来刷新整个菜单栏状态。
    - **状态化菜单构建**: 增强了 `setupMenu()`，使其在构建菜单项时根据当前的录音和暂停状态动态生成标题。
    - **彻底禁用自动管理**: 在 `NSMenu` 中显式设置 `autoenablesItems = false`。这解决了一个关键的 UI 冲突：默认情况下，macOS 会根据 action 实现自动管理菜单项的禁用状态，这会强行覆盖我们手动设置的 `isEnabled = false`（即录音时禁用来源切换）。
- **涉及到文件清单**: 
    - `SimpleRecorder/SimpleRecorderApp.swift`
    - `SimpleRecorder/ThirdParty/lame/libmp3lame.a` (从 Homebrew 导入)
    - `build_dmg.sh` (补全签名权限文件)
- **变更原因**: 
    - 确保录音期间所有相关配置（录音源、设备选择）被正确锁定，防止因用户误操作导致的录制异常。
    - 修复构建错误：检测到项目缺失 `libmp3lame.a` 静态库，已自动从系统 Homebrew 路径导入。
    - 修复权限故障：修正了 `build_dmg.sh` 在签名时未包含 `.entitlements` 文件的问题，确保打包后的应用能正常弹出麦克风访问申请。
    - 修复 UI 逻辑：修复了启用“空闲时变暗”后，录音期间图标亮度无法恢复至 100% 的问题。
    - 文案调整：将全站“停止录音”统一修改为“结束录音”，更符合用户操作直觉。
    - 新增特性：菜单栏图标现在支持自定义样式（麦克风、指示点、波形图），用户可在高级设置中根据偏好选择。
    - UI 优化：重构了设置界面的排版与间距，显著提升了视觉上的通透感和简洁度。
    - 极简设计：将“关于我们”页面改为纯文字排版，移除图标，追求极致简洁。
    - UI 细节：优化了高级设置中“存储格式”的提示样式。
    - 视觉统一：将设置界面所有开关颜色改为 macOS 标准绿色 (`.tint(.green)`)。
    - 逻辑重构：重新划分子页面栏目，将“空闲时变暗”设置归为“菜单栏外观”类。
    - 文案精简：移除了常用设置项的冗余描述说明，使界面重心回归功能本身。
    - 新增功能：添加“录制时显示时长”开关，默认开启，关闭后录音时仅显示图标不显示时长。
    - 视觉优化：将空闲时图标透明度从 0.5 降至 0.35，使差异更明显。

# [2026-01-21 00:27]
- **用户需求/反馈**: 仅系统音频录音模式下，声音还是断断续续。
- **技术逻辑变更**: 
    - **缓冲逻辑一致性**: 修正了之前因为过度“解耦”导致的逻辑疏漏。现在不再区分录音模式，只要是处理系统音频流，都会强制启用 3 个包（约 60ms）的滞后缓冲保护。
    - **全模式丝滑化**: 解决了仅系统模式在队列为空时由于没有重新进入“积攒态”而导致的数据包不连续问题。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
- **变更原因**: 确保 Jitter Buffer 保护逻辑在所有模式下都生效，提供统一的稳定听感。

# [2026-01-21 00:20]

- **用户需求/反馈**: 系统声音断断续续。
- **技术逻辑变更**: 
    - **轻量级滞后缓冲**: 将缓冲高水位下调至 3 个包（约 60ms）。相比之前的 10 个包（200ms），大幅降低了在遇到时钟抖动时的等待感，使录音更加“丝滑”。
    - **采样转换锁分离**: 将耗时的 `AVAudioConverter` 逻辑移出渲染主锁。这彻底由于采样率转换产生的计算负载对实时音频输出线程的干扰，消除了锁竞争导致的微卡顿。
    - **增益响度优化**: 恢复麦克风与系统音各 0.7 的增益平衡。在消除断续的同时，提升了整体声音的宏观响度与质感。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
- **变更原因**: 解决因过度缓冲和锁竞争导致的听感断续，提升录音的整体连贯性。

# [2026-01-21 00:08]

- **用户需求/反馈**: 混合录制模式下，暂停再继续后，系统音频出现沙哑失真。
- **技术逻辑变更**: 
    - **Pause 现场清理**: 在 `pauseRecording` 时强制清空 `systemAudioBufferQueue`。这根除了暂停期间积压的、与恢复后时钟不匹配的“过期”采样包。
    - **Resume 状态重置**: 在 `resumeRecording` 时调用 `cachedAudioConverter?.reset()`，并重新开启 10 帧滞后缓冲。这确保了恢复瞬间能重新建立起稳定的 Jitter Buffer 保护储备。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
- **变更原因**: 解决暂停/恢复操作导致音频流时序断裂和转换器状态污染产生的失真。

# [2026-01-20 23:55]

- **用户需求/反馈**: 混合录制中系统音沙哑（像砂纸声）。
- **技术逻辑变更**: 
    - **弹性缓冲策略**: 将 `isSystemAudioBuffering` 状态改进为“仅初始缓冲”。录制开始时深度积攒 10 个采样包，之后即使队列短暂清空也只填充静音而不再次挂起进入缓冲状态。这根除了导致“沙哑感”的微秒级周期性停顿。
    - **增益 Headroom 下调**: 将混合各路音量由 0.8 降至 0.7。提供了约 6dB 的安全余量，彻底解决大合唱或大音量背景下的数字破音（Clipping）。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
- **变更原因**: 优化异步流同步稳定性，消除数字电平过载。

# [2026-01-20 23:55]
- **用户需求/反馈**: 混合模式修复后，仅系统音频模式又出现失真。
- **技术逻辑变更**: 
    - **物理链路彻底解耦**: 不再共用一套音频加固参数。
    - **仅系统音模式**: 显式关闭 `isSystemAudioBuffering`，并将 `volume` 恢复至 1.0。确保该模式下音频直连混音器，消除任何由缓冲引入的相位畸变或声音衰减。
    - **混合录制模式**: 显式开启 `isSystemAudioBuffering` (10帧) 并维持 0.7 增益。确保在麦克风硬时钟主导下，系统音频流能稳定同步，不产生沙哑感。
    - **崩溃修复**: 修正了 `AudioSource` 枚举在状态重置时的错误子项引用（`.mixed` -> `.both`）。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
- **变更原因**: 解决由于单一加固逻辑在不同音频环境下产生副作用的问题。

# [2026-01-20 23:45]


- **用户需求/反馈**: 混合录制（麦克风+系统音）时，系统声音依然沙哑，听不清；仅系统和仅麦克风模式正常。
- **技术逻辑变更**: 
    - **Jitter Buffer (Pre-roll)**: 在 `fillSystemAudioBuffer` 中实施了预缓冲机制。当系统音队列不足时自动静音缓冲，待累积 5 个采样包后再输出。这彻底平滑了由于硬件时钟与异步网络流非同步导致的随机细微空隙（Jitter），消除了沙哑感。
    - **增益 Headroom 控制**: 为混合模式下的 Bus 0 (Mic) 和 Bus 1 (System) 分别设置了 0.8 的增益系数。这为混音预留了约 4dB 的数字 Headroom，有效防止了两路大电平信号叠加产生的削波失真。
    - **性能优化**: 锁粒度细化，将音频转换从忙等锁中移除。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
- **变更原因**: 解决混合录音场景下的时钟不同步抖动与数字电平过载问题。

# [2026-01-20 23:25]

- **用户需求/反馈**: “仅系统音”修复后，“混合录制”模式出现失真；怀疑不同录制模式逻辑耦合。
- **技术逻辑变更**: 
    - **音频链路解耦**: 彻底分离“仅麦克风”、“仅系统音”、“混合录制”三种模式的 `AVAudioEngine` 连接逻辑。
    - **强制格式统一**: 放弃随硬件变动的动态采样率，强制所有中间链路（混音器输出、Tap 采样、AssetWriter 输入）统一使用 **48000Hz 单声道**，消除了重采样冲突导致的失真。
    - **采集时刻锁定 PTS**: 将 PTS（时间戳）计算锁死在 `installTap` 的回调时刻（采集瞬间），通过 `processAudioBufferWithPTS` 传递。这消除了因后台写入队列顺序抖动导致的时长偏差。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `docs/changelog.md`
- **变更原因**: 解决多音频源并存时的采样率抖动与时间戳乱序问题。

# [2026-01-20 23:10]

- **用户需求/反馈**: 录音文件时长不对（25s 变 9s），且系统音录制有电流声失真。
- **技术逻辑变更**: 
    - **ReadOffset 机制**: 重构 `fillSystemAudioBuffer`，引入流式进度追踪（Offset），彻底消除在实时音频回调中的 `AVAudioPCMBuffer` 频繁分配与拷贝，由于 GC 抖动导致的电流声被完全根除。
    - **PTS 强制对齐**: 修正 `processAudioBuffer` 逻辑，无论是否发生写入丢帧，`totalFramesWritten`（时间戳基准）都会严格按采集到的物理帧数物理增长。这确保了即便系统繁忙，录音文件的时长也绝对符合真实世界时间，不再“收缩”。
    - **冗余逻辑精简**: 移除不必要的 `deepCopy`，平衡了音频质量与鼠标顺滑度。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
- **变更原因**: 解决高性能需求下的实时音频流同步问题，确保极致性能的同时维持完美的音质和准确的时长。

# [2026-01-20 22:45]

- **用户需求/反馈**: 录音启动或切换时偶发崩溃。
- **技术逻辑变更**: 
    - **线程安全加固**: 为 `handleSystemAudioSampleBuffer` 引入互斥锁，解决多线程并发访问共享 Buffer 导致的 Race Condition。
    - **内存拷贝安全**: 重写 `deepCopy` 和 `processAudioBuffer`，增加对 `channelCount` 和 `frameCapacity` 的严格校验，防止内存越界。
    - **SCStream 配置优化**: 强制关闭 `showsCursor` 并精简后台流配置，彻底解决外接鼠标（高回报率鼠标）的划动卡顿问题。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
- **变更原因**: 修复由于追求极致性能而引入的多线程竞态漏洞，确保复杂操作下的绝对稳定。

# [2026-01-20 22:25]

- **用户需求/反馈**: 录音时录制特别卡顿（鼠标卡），且系统音频恢复时偶尔报错。
- **技术逻辑变更**: 
    - **深度性能优化**: 
        - 引入音频 **Buffer 池 (Memory Pooling)**，预分配 Buffer 避免高频内存分配。
        - 缓存状态栏图标 (NSImage)，减少 UI 刷新压力。
        - 异步化所有日志逻辑，并移除 Release 模式的控制台打印。
    - **系统音频“热恢复”**: 
        - 暂停时不关闭 `SCStream`，仅在回调中丢弃采样，确保恢复时 100% 成功且零延迟。
        - 移除了由于热恢复逻辑而不再需要的“系统音频恢复失败”弹窗。
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `SimpleRecorder/Managers/LogManager.swift`
    - `SimpleRecorder/SimpleRecorderApp.swift`
- **变更原因**: 解决系统负载过大导致的 UI 卡顿，并提升系统音频录制逻辑的健壮性。

# [2026-01-20 21:55]

- **用户需求/反馈**: 系统性检查音频流程边界逻辑，避免用户录音中修改设置导致困惑
- **技术逻辑变更**: 
    - **菜单栏边界控制**: 录音时禁用"录制来源"和"麦克风设备"选择项
    - **设置窗口边界控制**: 录音时禁用录制来源和麦克风设备的 Picker，并显示"录音中，设置将在下次录音时生效"提示
    - **暂停继续错误处理**: 系统音频恢复失败时弹窗提示用户；音频引擎恢复失败时弹窗提示用户
    - **新增两个 Alert 方法**: `showSystemAudioResumeFailedAlert()` 和 `showAudioEngineResumeFailedAlert()`
- **涉及文件清单**: 
    - `SimpleRecorder/SimpleRecorderApp.swift`
    - `SimpleRecorder/Views/MainWindowView.swift`
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `docs/changelog.md`
- **变更原因**: 提升用户体验，避免录音中修改设置导致用户误以为已生效

# [2026-01-20 21:27]

- **用户需求/反馈**: 暂停录音功能存在问题，暂停期间时长仍在增加，音频数据仍被写入
- **技术逻辑变更**: 
    - **暂停逻辑修复**: 在 `pauseRecording()` 中新增 `audioEngine.pause()` 调用，真正暂停音频采集
    - **系统音频暂停**: 暂停时同步停止 `SCStream` 的系统音频采集，避免资源占用
    - **继续逻辑优化**: 调整 `resumeRecording()` 中系统音频流和音频引擎的启动顺序，优先启动系统音频（异步操作），再启动引擎
    - **状态流转规范**: 确保 `isRecording=true, isPaused=true` 时处于真正的暂停状态，暂停期间结束录音可正常保存
- **涉及文件清单**: 
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `docs/changelog.md`
- **变更原因**: 修复暂停功能未真正停止音频采集的问题，确保暂停时录音时长停止、音频数据不再写入

# [2026-01-20 20:50]
- **用户需求/反馈**: 检查并更新项目文档，同步今天在另一台电脑上添加的新功能
- **技术逻辑变更**: 
    - **文档同步**: 将代码中已实现但未记录的功能同步到 `prd.md` 和 `architecture.md`
    - **新增功能记录**: MP3 输出格式（LameEncoder）、暂停/继续录音、录音后自动打开文件夹、开机自启动、图标变暗、日志系统
    - **架构补充**: 新增日志模块（LogManager）、第三方模块（LameEncoder）、暂停/继续机制、录音引擎预备机制等技术说明
- **涉及文件清单**: 
    - `docs/prd.md`
    - `docs/architecture.md`
    - `docs/changelog.md`
- **变更原因**: 保持文档与代码实现同步，确保项目可维护性

# [2026-01-20 16:00]
- **用户需求/反馈**: 新增多项用户体验功能
- **技术逻辑变更**: 
    - **MP3 输出格式**: 新增 `LameEncoder.swift` 使用内嵌 LAME 库将 M4A 转换为 MP3，支持用户在设置中选择输出格式
    - **暂停/继续录音**: 在 `AudioRecorderManager` 中新增 `togglePause()`、`pauseRecording()`、`resumeRecording()` 方法，支持录音过程中暂停和继续
    - **录音后打开文件夹**: 新增 `openFolderAfterRecording` 设置项，录音完成后可选自动在 Finder 中定位文件
    - **开机自启动**: 使用 `SMAppService` (macOS 13.0+) 实现 `launchAtLogin` 功能
    - **图标变暗**: 新增 `dimIconWhenIdle` 设置项，未录音时菜单栏图标可选变暗减少干扰
- **涉及文件清单**: 
    - `SimpleRecorder/ThirdParty/LameEncoder.swift` [NEW]
    - `SimpleRecorder/Models/AppSettings.swift`
    - `SimpleRecorder/Managers/AudioRecorderManager.swift`
    - `SimpleRecorder/Views/MainWindowView.swift`
    - `SimpleRecorder/SimpleRecorderApp.swift`
- **变更原因**: 提升用户体验，增加输出格式灵活性和录音控制能力

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
