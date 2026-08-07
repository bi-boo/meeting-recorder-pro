# 会议录音 Pro 独立分发说明

本项目不走 Mac App Store 上架流程，采用开源仓库 + 独立 DMG 分发。

## 分发口径

| 项目 | 内容 |
|---|---|
| 应用名称 | 会议录音 Pro |
| Bundle ID | `com.meetingrecorderpro.app` |
| 当前版本 | `1.0.7` (`8`) |
| 支持系统 | macOS 13.0 或更高版本 |
| 当前发布架构 | Apple Silicon (`arm64`) |
| 分发产物 | `MeetingRecorderPro_YYYYMMDD.dmg` |
| DMG 内应用名 | `会议录音 Pro.app` |
| 分发渠道 | GitHub Releases 或项目主页下载链接 |
| 自动更新 | Sparkle 2 + GitHub Releases `appcast.xml` |
| 上架状态 | 不提交 Mac App Store |

## 签名策略

公开分发的 DMG 应使用 Developer ID Application 证书签名，并完成 notarization。没有证书时，`build_dmg.sh` 会退回 ad-hoc 签名，适合本机开发验证，不适合作为公开下载版本。

推荐发布环境变量：

```bash
DEVELOPER_ID_CERT="Developer ID Application: Your Name (TEAMID)"
NOTARY_PROFILE="notarytool-profile"
```

`build_dmg.sh` 只会读取项目根目录的 `.env`，并且只接受 `RELEASE`、`PUBLISH_GITHUB_RELEASE`、`RELEASE_INTEGRATION_REPORT`、`PUBLISH_DMG_PATH`、`NOTARY_PROFILE`、`DEVELOPER_ID_CERT`、`GITHUB_REPOSITORY` 和 `RELEASE_TAG`。`PATH`、`PYTHONPATH` 等其他变量会被忽略，避免本地配置改写构建命令的来源。

执行：

```bash
./build_dmg.sh
```

该命令用于本机验证包：有 Developer ID 和 `NOTARY_PROFILE` 时会自动公证；没有证书时会退回 ad-hoc 签名，仅适合本机功能验证。

正式对外发布必须使用严格模式：

```bash
RELEASE=1 ./build_dmg.sh
```

严格模式会要求干净的 Git 工作区、Developer ID Application 证书和 `NOTARY_PROFILE`，并强制通过 notarization、stapler validation、`codesign`、`hdiutil verify` 与 Gatekeeper 校验。构建完成后会在 `build/release-artifact-manifest.json` 记录当前提交、App 可执行文件和 DMG 的 SHA-256。

正式发布并同步自动更新源：

先用 `RELEASE=1 ./build_dmg.sh` 生成并公证最终包，安装这份 App 后运行真实录音集成测试。确认报告通过后，再执行：

```bash
RELEASE=1 PUBLISH_GITHUB_RELEASE=1 \
RELEASE_INTEGRATION_REPORT="test-results/recording-integration/<timestamp>/report.json" \
./build_dmg.sh
```

该命令不会重新构建，而是复用刚才完成真实录音测试的 App/DMG；它先根据构建时的来源清单确认 App/DMG 确实属于当前 HEAD，再严格比对报告、Release App 和 DMG 内 App 的可执行文件 SHA-256。生成 `appcast.xml` 时会创建全新的临时 Python 环境，只安装通过 SHA-256 锁定的 Apple Silicon 轮子，不复用旧环境。随后对同一份最终 DMG 运行完整 QA，再把 DMG、`appcast.xml` 和 LAME 3.100 完整源码包上传到 GitHub Releases。已有 tag 若仍是 draft 或 prerelease，脚本会拒绝上传，避免 `releases/latest` 继续指向旧更新源。

## 权限说明

- 麦克风权限：用于录制本机麦克风输入。
- 屏幕与系统音频录制权限：仅在用户选择“仅系统声音”或“麦克风 + 系统声音”时需要，用于通过 ScreenCaptureKit 采集系统音频。
- 文件访问权限：用于保存到用户选择的录音目录。

当前独立分发版本不启用 App Sandbox，原因是 PermissionFlow 的系统设置拖拽授权引导需要跨进程跟踪系统设置窗口。由于不提交 Mac App Store，这个取舍与当前分发策略一致。

## 自动更新

应用通过 Sparkle 2 检查更新，不依赖自建服务器。

- Appcast：`https://github.com/bi-boo/meeting-recorder-pro/releases/latest/download/appcast.xml`
- 更新包：GitHub Release asset 中的 `MeetingRecorderPro_YYYYMMDD.dmg`
- 检查频率：每天一次
- 菜单栏更新项默认显示“当前版本 x.y.z”，发现更新后显示“下载并安装 x.y.z...”
- 录音中禁止检查更新，避免安装流程影响录音保存
- 用户点击可用更新后，不展示更新窗口和版本说明，Sparkle 负责下载、验签、替换应用并重启安装；系统权限授权提示除外

## 隐私承诺

- 不需要账号登录。
- 仅访问 GitHub Releases 检查更新，不上传录音。
- 不收集遥测、联系人、日历、位置或设备标识。
- 录音文件只保存在用户本地选择的目录。

## 开源发布前检查

- 根目录保留 `LICENSE`，明确主项目开源许可证。
- 保留 `THIRD_PARTY_NOTICES.md`，发布说明中注明第三方组件来源。
- 保留 `SimpleRecorder/ThirdParty/lame/COPYING`，发布说明中注明内嵌 LAME 的许可来源。
- `build_dmg.sh` 会把项目许可证、第三方声明、PermissionFlow/Sparkle 完整许可证，以及 LAME 许可证、完整源码包和源码/重链接说明放入 DMG 根目录。
- 当前公开版支持 M4A 与 MP3 输出；MP3 由内嵌 `libmp3lame.a` 分块转码实现。
- 二进制 DMG 内继续分发 `libmp3lame.a` 时，DMG 和同一 GitHub Release 必须包含校验通过的 `lame-3.100.tar.gz`，Release Notes 需要说明该源码资产。
- 跑完整 QA：

```bash
scripts/run_full_qa.sh
```

- 自动化 QA 默认不允许核心场景跳过；若只是缺权限环境下的本机烟测，可临时加 `QA_ALLOW_SKIPS=true`，但不能作为正式发布证据。
- 使用 Developer ID 正式发布时，检查 DMG 是否通过签名、公证和 Gatekeeper。未公证的开发包会被 Gatekeeper 标记为 not accepted，只适合本机验证或面向愿意手动放行的测试用户。

```bash
RELEASE=1 ./build_dmg.sh
spctl --assess --type open --context context:primary-signature --verbose=4 MeetingRecorderPro_YYYYMMDD.dmg
```

## 发布说明模板

```markdown
## 会议录音 Pro 1.0.0

- 支持麦克风、系统声音、麦克风 + 系统声音三种录音模式。
- 支持定时录音、暂停继续、全局快捷键。
- 录音期间保持系统唤醒，降低长会议中断风险。
- 支持 M4A 和 MP3 输出，便于上传到只接受 MP3 的转写服务。
- MP3 转码使用内嵌 LAME 分块编码；第三方组件许可和重建说明见 `THIRD_PARTY_NOTICES.md`。

下载 DMG 后打开，将“会议录音 Pro.app”拖入 Applications 文件夹。首次录音需要授予麦克风权限；录制系统声音时需要额外授予屏幕与系统音频录制权限。
```
