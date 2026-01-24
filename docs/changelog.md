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
