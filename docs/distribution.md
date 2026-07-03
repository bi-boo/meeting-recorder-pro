# 会议录音 Pro 独立分发说明

本项目不走 Mac App Store 上架流程，采用开源仓库 + 独立 DMG 分发。

## 分发口径

| 项目 | 内容 |
|---|---|
| 应用名称 | 会议录音 Pro |
| Bundle ID | `com.meetingrecorderpro.app` |
| 当前版本 | `1.0.0` (`1`) |
| 支持系统 | macOS 13.0 或更高版本 |
| 当前发布架构 | Apple Silicon (`arm64`) |
| 分发产物 | `MeetingRecorderPro_YYYYMMDD.dmg` |
| 分发渠道 | GitHub Releases 或项目主页下载链接 |
| 上架状态 | 不提交 Mac App Store |

## 签名策略

公开分发的 DMG 应使用 Developer ID Application 证书签名，并完成 notarization。没有证书时，`build_dmg.sh` 会退回 ad-hoc 签名，适合本机开发验证，不适合作为公开下载版本。

推荐发布环境变量：

```bash
DEVELOPER_ID_CERT="Developer ID Application: Your Name (TEAMID)"
NOTARY_PROFILE="notarytool-profile"
```

执行：

```bash
./build_dmg.sh
```

脚本会完成 Release 构建、应用签名、DMG 生成、DMG 签名、`codesign` 校验、`hdiutil verify` 校验，并在可用时执行 notarization 和 stapling。

## 权限说明

- 麦克风权限：用于录制本机麦克风输入。
- 屏幕与系统音频录制权限：仅在用户选择“仅系统声音”或“麦克风 + 系统声音”时需要，用于通过 ScreenCaptureKit 采集系统音频。
- 文件访问权限：用于保存到用户选择的录音目录。

当前独立分发版本不启用 App Sandbox，原因是 PermissionFlow 的系统设置拖拽授权引导需要跨进程跟踪系统设置窗口。由于不提交 Mac App Store，这个取舍与当前分发策略一致。

## 隐私承诺

- 不需要账号登录。
- 不联网，不上传录音。
- 不收集遥测、联系人、日历、位置或设备标识。
- 录音文件只保存在用户本地选择的目录。

## 开源发布前检查

- 根目录补齐 `LICENSE`，明确主项目开源许可证。
- 保留 `SimpleRecorder/ThirdParty/lame/COPYING`，发布说明中注明内嵌 LAME 的许可来源。
- 跑完整 QA：

```bash
scripts/run_full_qa.sh
```

- 检查 DMG 是否通过签名、公证和 Gatekeeper：

```bash
spctl --assess --type open --context context:primary-signature --verbose=4 MeetingRecorderPro_YYYYMMDD.dmg
```

## 发布说明模板

```markdown
## 会议录音 Pro 1.0.0

- 支持麦克风、系统声音、麦克风 + 系统声音三种录音模式。
- 支持定时录音、暂停继续、全局快捷键。
- 录音期间保持系统唤醒，降低长会议中断风险。
- 支持 M4A 和 MP3 输出。

下载 DMG 后打开，将“会议录音 Pro”拖入 Applications 文件夹。首次录音需要授予麦克风权限；录制系统声音时需要额外授予屏幕与系统音频录制权限。
```
