# AGENTS.md

## 项目定位

`会议录音 Pro` 是一个 macOS 菜单栏录音应用，计划开源并通过独立 DMG 分发，不提交 Mac App Store。项目目标是把本地录音做稳定：不丢录音、文件可播放、权限边界清楚、发布包可验证。

## 先定交付标准

以后在本项目内做任何功能、新模块或大改动，先确认对应的稳定交付标准，再开始实现。不要用反复人工审查代替固定门禁。

默认执行顺序：

1. 确认本次改动属于功能、稳定性、UI、打包、文档还是测试。
2. 阅读相关标准文档。
3. 实现最小必要改动。
4. 跑对应测试。
5. 记录验证证据。
6. 只在标准未达成时继续修复。

## 必读文档索引

- 稳定交付门槛：[docs/stable-delivery-standard.md](docs/stable-delivery-standard.md)
- 功能清单：[docs/feature-list.md](docs/feature-list.md)
- 测试用例与流程：[docs/test-cases.md](docs/test-cases.md)
- 发布检查清单：[docs/release-checklist.md](docs/release-checklist.md)
- 自动更新说明：[docs/auto-update.md](docs/auto-update.md)
- 回归测试细则：[docs/qa-regression.md](docs/qa-regression.md)
- 独立分发说明：[docs/distribution.md](docs/distribution.md)
- 1.0.6 发布复盘与防复发背景：[docs/release-retrospective-1.0.6.md](docs/release-retrospective-1.0.6.md)
- 产品需求：[docs/prd.md](docs/prd.md)
- 技术架构：[docs/architecture.md](docs/architecture.md)

## 1.0.6 之后的防复发硬规则

- 对外版本、内部构建号、主分支、Git 标签和 GitHub Release 是五个独立状态。普通界面只显示 `CFBundleShortVersionString`；Sparkle 使用递增的 `CFBundleVersion`。正式发布后必须回读主分支、远程标签、Latest Release 和 `latest/download/appcast.xml`，不能用其中一个状态代替完整发布验证。
- 录音启动阶段允许 macOS 进行多轮设备路由和格式协商；必须把 `.starting` 与 `.recording` 分开处理。只有录音已稳定，且旧、新输入设备 ID 都已知并确实不同时，才按设备切换中断并保存。
- 真实录音集成测试前先列出设备并做短时音量预检。设备存在但静音时不得进入完整测试；有多个设备时使用 `--input-pair` 和 `--output-pair` 显式指定，禁止按名称排序自动选择。环境没有变化时，不重复运行同一测试。
- 任何安装、替换 App、完整 QA 或发布动作开始前，都要在系统权限环境检查 `SimpleRecorder` 进程，并用 `lsof` 检查是否持有 `.m4a`、`.mp3`、`.caf`、`.wav` 或临时录音文件。只要应用正在录音，就停止安装和会启动应用的测试，等待录音正常结束；不得移动或替换运行中的 App。
- 公证前先用 Keychain profile 验证 Apple 凭据，再开始正式构建。Apple ID 和 App 专用密码只能通过系统隐藏输入或 `notarytool` 安全提示输入；不得放进聊天、命令行参数、项目文件或日志。凭据一旦暴露，发布后撤销并更新 Keychain profile。
- 测试汇报必须给出 `passed / failed / skipped`、报告路径、失败或跳过原因，以及可直接打开的录音目录。数值判定不能代替人工试听入口。
- 无法满足测试环境而发布负责人明确要求继续发布时，必须记录发布例外，不得伪造通过报告。P0/P1、Developer ID 签名、Apple 公证、Stapler、Gatekeeper、DMG 完整性和远程资产一致性不可豁免。
- 正式资产上传后必须从 GitHub 回下载 DMG、`appcast.xml` 和 LAME 源码，复查 SHA-256、DMG 校验、公证、Gatekeeper、Sparkle 版本和下载 URL；本地上传成功日志不能代替远程回读。

## 稳定交付门槛

本项目达到以下条件，才算可以交付：

- P0/P1 问题为 0。
- 自动化 QA 核心场景全部通过，核心场景不能 skipped 后算通过。
- `xcodebuild test` 通过。
- `./build_dmg.sh` 通过，DMG 能被 `hdiutil verify` 校验。
- 正式公开分发时，`RELEASE=1 ./build_dmg.sh` 必须通过 notarization、stapler validation 和 Gatekeeper。
- 版本迭代正式发布时，`PUBLISH_GITHUB_RELEASE=1` 必须同步上传 DMG 和 `appcast.xml` 到 GitHub Releases。
- 人工冒烟测试没有阻断项；无法自动化的项目必须记录未执行原因。
- 文档中的功能承诺和实际代码一致。

停止继续排查的条件：

- 最近一轮完整 QA 通过。
- 最近一轮代码审查没有 P0/P1。
- 只剩人工环境项或低风险体验项，并且已记录。
- Git 有可回滚提交，工作区没有未提交的相关改动。

## 阻断级别

- P0：会丢录音、录音文件损坏、应用无法启动、DMG 无法安装、权限路径完全不可用、密钥或隐私数据泄露。
- P1：常用路径失败，包括 M4A/MP3 输出失败、系统音频或混合录音失败、录音中退出不能保存、定时录音不能触发。
- P2：体验或边界缺陷，包括提示文案不准、设置状态不同步、低频异常场景处理不清。
- P3：样式、命名、文档表达或非核心体验优化。

P0/P1 必须修复后才能交付；P2 可以进入下一轮但必须记录；P3 不阻断发布。

## 核心功能范围

当前必须保持可用的功能：

- 麦克风录音。
- 系统声音录音。
- 麦克风 + 系统声音混合录音。
- 暂停和继续。
- 连续多段录音，文件名不冲突。
- M4A 输出。
- MP3 输出。
- 定时自动录音。
- 全局快捷键。
- 录音中退出自动保存。
- 录音期间防休眠。
- 独立 DMG 分发。

## 测试命令

基础测试：

```bash
xcodebuild test -project SimpleRecorder.xcodeproj \
  -scheme SimpleRecorder \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/TestDerivedData
```

完整 QA：

```bash
scripts/run_full_qa.sh
```

本机验证包：

```bash
./build_dmg.sh
```

正式分发包：

```bash
RELEASE=1 ./build_dmg.sh
```

录音集成测试：

```bash
scripts/recording_integration_test.py --yes --quick --prompt-countdown 2 --start-attempts 3
```

改动涉及 app 代码、项目配置、录音逻辑、设备变更处理、权限、快捷键或 `scripts/recording_integration_test.py` 时，重新构建/安装应用后运行该测试。测试会真实录音；麦克风阶段需要提示用户对当前输入设备说话，系统音频阶段会自动播放测试音。

通过标准：

- `failed = 0`
- 麦克风、系统声音、混合模式都生成有效时长且非静音的音频文件。
- 输入设备切换会中断并保存当前录音。
- 输入设备切换后还能再次开始录音并录到声音。

输出设备切换场景在少于两个输出设备时可以跳过。最终汇报必须说明 `passed / failed / skipped`，失败或跳过原因以 `test-results/recording-integration/<timestamp>/report.json` 和应用日志为依据。

## 编码规则

- 录音、停止、转码、退出、权限和打包属于高风险路径，改动后必须跑完整 QA。
- 不新增不必要的依赖。
- 不把构建产物、DMG、QA 目录、日志、`.env`、证书或同步冲突文件提交进 Git。
- 不把 Sparkle 更新私钥提交进 Git；私钥默认保存在已忽略的 `config/sparkle_ed25519_private.pem`。
- `SimpleRecorder/ThirdParty/lame/` 是 MP3 输出能力的一部分，改动时同步检查许可证和分发文档。
- 文档更新必须和代码能力一致；不能在 README、PRD、架构或分发说明里保留旧承诺。

## 自动更新与发布规则

- 自动更新使用 Sparkle 2，更新源固定为 GitHub Releases 的 `appcast.xml`，不维护额外服务器。
- `CFBundleVersion` 是 Sparkle 判断新旧版本的依据，每次发布必须递增。
- 菜单栏更新项默认显示“当前版本 x.y.z”；后台发现更新后同一菜单项显示“下载并安装 x.y.z...”。
- 录音中禁止检查和安装更新，菜单项必须禁用，避免更新流程影响录音。
- 后台每日检查只更新菜单状态，不主动弹出更新窗口。
- 用户点击可用更新后，不展示更新窗口和版本说明，直接进入 Sparkle 的下载、验签、重启安装流程；系统权限授权提示除外。
- 每次正式版本迭代必须执行 `RELEASE=1 PUBLISH_GITHUB_RELEASE=1 ./build_dmg.sh`，确保 GitHub Release 同时包含 DMG 和 `appcast.xml`。

## Git 规则

- 每组可验证改动完成后创建本地提交。
- 提交前检查 `git status --short` 和 `git diff --cached`。
- 只提交本轮相关文件。
- 默认不 push，除非用户明确要求。

## 同步工具注意事项

Synology Drive 可能生成 `_Conflict.swift` 文件。构建或提交前必须确认：

```bash
find SimpleRecorder -name '*Conflict.swift' -print
```

如有冲突文件，先判断哪份是最新内容，再恢复到原始受跟踪路径。不要把 `_Conflict.swift` 提交进 Git。
