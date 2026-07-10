# 会议录音 Pro 发布检查清单

本文件用于每次生成可分发 DMG 前的最终检查。普通开发提交不必每项都跑；准备发给用户时必须按本文件执行。

## 发布前条件

- P0/P1 问题为 0。
- README、PRD、架构、分发说明和功能清单没有过期承诺。
- `THIRD_PARTY_NOTICES.md`、`docs/lame-relinking.md`、`SimpleRecorder/ThirdParty/lame/COPYING` 和已校验的 `lame-3.100.tar.gz` 保留。
- `CFBundleShortVersionString` 和 `CFBundleVersion` 已更新，且 `CFBundleVersion` 大于上一版。
- Git 工作区没有未提交的相关改动。
- 没有 `_Conflict.swift`、`.env`、证书、Sparkle 私钥、DMG、build、qa-runs 被暂存。

检查命令：

```bash
git status --short
git diff --check
find SimpleRecorder -name '*Conflict.swift' -print
git check-ignore -v .env config/sparkle_ed25519_private.pem MeetingRecorderPro_*.dmg qa-runs/ build/ || true
```

## 本机验证包

用于开发机自测或小范围人工验证：

```bash
./build_dmg.sh
```

必须通过：

- Release build 成功。
- `codesign --verify` 通过。
- `hdiutil verify` 通过。
- DMG 根目录包含应用和许可文件。

验证 DMG 内容：

```bash
MOUNT_DIR="/tmp/MeetingRecorderProDMG-$$"
mkdir -p "$MOUNT_DIR"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" MeetingRecorderPro_YYYYMMDD.dmg
ls -la "$MOUNT_DIR"
test -d "$MOUNT_DIR/会议录音 Pro.app"
test -f "$MOUNT_DIR/LICENSE.txt"
test -f "$MOUNT_DIR/THIRD_PARTY_NOTICES.md"
test -f "$MOUNT_DIR/LAME-COPYING.txt"
test -f "$MOUNT_DIR/LAME-SOURCE-AND-RELINKING.md"
test -f "$MOUNT_DIR/lame-3.100.tar.gz"
echo "ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e  $MOUNT_DIR/lame-3.100.tar.gz" | shasum -a 256 -c -
test -f "$MOUNT_DIR/PermissionFlow-LICENSE.txt"
test -f "$MOUNT_DIR/Sparkle-LICENSE.txt"
hdiutil detach "$MOUNT_DIR"
```

未公证的本机验证包可能显示：

```text
Gatekeeper: not accepted
source=Unnotarized Developer ID
```

这不阻断本机验证，但不能作为正式公开发布包。

## 正式公开分发包

正式发布必须执行：

```bash
RELEASE=1 ./build_dmg.sh
```

正式发布并同步自动更新源：

1. 先执行上面的 `RELEASE=1 ./build_dmg.sh`，安装这次生成的 App，并运行真实录音集成测试。
2. 将通过的 `report.json` 交给发布命令；发布命令复用同一份现成 App/DMG，不会重新构建。

```bash
RELEASE=1 PUBLISH_GITHUB_RELEASE=1 \
RELEASE_INTEGRATION_REPORT="test-results/recording-integration/<timestamp>/report.json" \
./build_dmg.sh
```

发布脚本还会强制检查：工作区干净、HEAD 已在 `origin` 远程分支上、本地和远程 tag 均指向 HEAD、公开 Release 不含 QA Runner、Developer ID 签名、DMG 公证/stapler/Gatekeeper 全部通过。上传前会对最终 DMG 再跑完整 QA，并把 QA 证据绑定到当前 HEAD、App 版本和 DMG SHA-256；真实录音报告必须匹配当前 HEAD、版本和 Release App 可执行文件 SHA-256，DMG 内可执行文件也必须完全一致。

环境变量：

```bash
DEVELOPER_ID_CERT="Developer ID Application: Your Name (TEAMID)"
NOTARY_PROFILE="notarytool-profile"
```

通过标准：

- Developer ID Application 签名。
- notarytool submit 成功。
- stapler staple 成功。
- `xcrun stapler validate` 成功。
- Gatekeeper accepted。
- GitHub Release 包含 `MeetingRecorderPro_YYYYMMDD.dmg`、`appcast.xml` 和 `lame-3.100.tar.gz` 三个资产。
- `appcast.xml` 的 `sparkle:version` 与当前 `CFBundleVersion` 一致，且 `enclosure url` 指向同一 tag 的 DMG。

额外检查：

```bash
spctl --assess --type open --context context:primary-signature --verbose=4 MeetingRecorderPro_YYYYMMDD.dmg
shasum -a 256 MeetingRecorderPro_YYYYMMDD.dmg
```

## 发布 QA

正式发布前运行：

```bash
scripts/run_full_qa.sh
```

通过标准：

- 报告中核心自动化场景全部 passed。
- `failed=0`。
- 只有 `manual-remainder` 可 skipped。
- `artifact-check.log` 完成。
- 录音样本包含 M4A 和 MP3，每个文件都可解码、时长达标且非静音。
- `qa-result.json` 中所有按开关启用的场景必须恰好出现一次；缺失、重复、状态与 summary 不一致都会失败。

## 发布说明必含内容

Release Notes 至少包含：

- 版本号。
- 支持系统：macOS 13.0+。
- 架构：Apple Silicon (`arm64`)。
- 核心功能：麦克风、系统声音、混合录音、定时录音、M4A/MP3。
- 权限说明：麦克风、屏幕与系统音频录制。
- 隐私说明：仅访问 GitHub Releases 检查更新，不上传录音或遥测。
- 第三方组件说明：PermissionFlow、Sparkle、LAME，以及 LAME 源码/重链接说明。
- SHA256。

## 发布后检查

发布后从下载链接重新下载 DMG，再执行：

```bash
spctl --assess --type open --context context:primary-signature --verbose=4 MeetingRecorderPro_YYYYMMDD.dmg
hdiutil verify MeetingRecorderPro_YYYYMMDD.dmg
curl -I https://github.com/bi-boo/meeting-recorder-pro/releases/latest/download/appcast.xml
```

打开 DMG，将 `会议录音 Pro.app` 拖入 Applications，启动后完成一次短录音。发布后如果用户反馈丢录音、打不开、权限异常、MP3 转码失败，按 P0/P1 处理并暂停继续分发。
