# 会议录音 Pro 自动更新说明

## 更新机制

会议录音 Pro 使用 Sparkle 2 做独立分发自动更新，不走 Mac App Store。

- 更新源：`https://github.com/bi-boo/meeting-recorder-pro/releases/latest/download/appcast.xml`
- 下载源：GitHub Releases 中的 `MeetingRecorderPro_YYYYMMDD.dmg`
- 检查频率：每天一次，配置为 `SUScheduledCheckInterval=86400`
- 安装方式：用户点击菜单栏更新项后，由 Sparkle 下载、验签、替换应用并重启安装
- 录音保护：录音中禁止检查更新，也不会启动安装流程

## 菜单栏行为

- 默认文案：`当前版本 x.y.z`
- 后台发现更新：同一菜单项显示 `下载并安装 x.y.z...`
- 更新流程状态：同一菜单项按阶段显示 `正在检查更新...`、`正在下载更新...`、`正在准备安装...`、`正在安装并重启...`
- 重启完成确认：安装前记录目标版本，重启后比对当前版本；确认成功后回到 `当前版本 x.y.z`
- 录音中：更新菜单项禁用

后台检查发现更新时不弹出更新窗口，只更新这个菜单项。用户主动点击“下载并安装 x.y.z...”后，不展示更新窗口和版本说明，直接进入 Sparkle 的下载、验签、重启安装流程；如果系统要求管理员授权，仍可能出现系统授权提示。

## GitHub Release 闭环

Sparkle 不能直接读取 GitHub Release JSON；它读取的是 `appcast.xml`。本项目不维护额外服务器，而是把 `appcast.xml` 作为 GitHub Release asset 上传。

每次版本迭代必须同步三个数据：

1. `CFBundleShortVersionString`：用户可见版本号，例如 `1.0.1`
2. `CFBundleVersion`：Sparkle 比较用构建号，必须递增
3. GitHub Release assets：同一 tag 下必须同时包含 DMG、`appcast.xml` 和 `lame-3.100.tar.gz`

默认正式发布命令：

先执行 `RELEASE=1 ./build_dmg.sh`，安装生成的 App 并取得通过的真实录音集成报告。然后发布同一份现成 App/DMG：

```bash
RELEASE=1 PUBLISH_GITHUB_RELEASE=1 \
RELEASE_INTEGRATION_REPORT="test-results/recording-integration/<timestamp>/report.json" \
./build_dmg.sh
```

该命令不会重新构建；它会先校验现成 App/DMG 的签名、公证、Gatekeeper，以及真实录音报告中的可执行文件 SHA-256，再执行：

```bash
scripts/publish_github_release.sh MeetingRecorderPro_YYYYMMDD.dmg
```

发布脚本会先核对 Sparkle 私钥派生出的 Ed25519 公钥与 App 内 `SUPublicEDKey`，并立即验签生成的签名；随后使用锁定的独立 Python 环境生成 `build/appcast.xml`。已有 tag 必须是正式 Release，draft/prerelease 会被拒绝，避免 `/releases/latest/` 保持旧版本。

## 签名密钥

Sparkle 更新包必须使用 Ed25519 签名。

- 公钥写在 `SimpleRecorder/Info.plist` 的 `SUPublicEDKey`
- 私钥只保存在本机忽略文件，例如 `config/sparkle_ed25519_private.pem`
- 私钥不得提交到 Git、Release、日志或文档

如果私钥丢失，已安装旧版本的用户无法验证未来更新；这种情况需要重新发布一个手动安装版本，并在该版本内更新新的公钥。

## 发布前检查

正式发布前必须确认：

```bash
git status --short
git check-ignore -v config/sparkle_ed25519_private.pem
git tag --points-at HEAD
RELEASE=1 PUBLISH_GITHUB_RELEASE=1 \
RELEASE_INTEGRATION_REPORT="test-results/recording-integration/<timestamp>/report.json" \
./build_dmg.sh
```

发布前要先创建并推送与版本号一致的 tag。脚本不会替用户创建 tag，也不会在 tag 与当前 HEAD 不一致时上传资产。

发布后必须验证：

```bash
curl -I https://github.com/bi-boo/meeting-recorder-pro/releases/latest/download/appcast.xml
curl -L https://github.com/bi-boo/meeting-recorder-pro/releases/latest/download/appcast.xml
```

`appcast.xml` 中的 `sparkle:version` 必须大于当前线上版本，`enclosure url` 必须指向同一 tag 的 DMG。
