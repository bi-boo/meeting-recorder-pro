# 会议录音 Pro 测试用例与流程

本文件是测试入口索引。详细人工步骤见 [qa-regression.md](qa-regression.md)，发布要求见 [release-checklist.md](release-checklist.md)。

## 测试分层

| 层级 | 用途 | 什么时候跑 |
|---|---|---|
| 单元测试 | 验证纯逻辑和可隔离边界 | 每次提交前 |
| 自动化 QA | 验证打包产物和核心用户路径 | 每次实质改动后 |
| 人工冒烟 | 验证菜单栏、系统权限、快捷键、Finder、登录项等强交互项 | 发布前或相关功能改动后 |
| 长录音测试 | 验证长时间稳定性和磁盘/转码边界 | beta 前、正式发布前、录音链路改动后 |
| 正式发布校验 | 验证签名、公证、Gatekeeper 和 DMG 内容 | 公开发布前 |

## 标准执行流程

1. 确认没有旧进程和旧挂载：

   ```bash
   pkill -x SimpleRecorder >/dev/null 2>&1 || true
   mount | rg '会议录音 Pro|MeetingRecorderPro' || true
   ```

2. 跑单元测试：

   ```bash
   xcodebuild test -project SimpleRecorder.xcodeproj \
     -scheme SimpleRecorder \
     -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath build/TestDerivedData
   ```

3. 跑完整 QA：

   ```bash
   scripts/run_full_qa.sh
   ```

4. 检查 QA 报告：

   ```bash
   latest="$(find qa-runs -maxdepth 1 -type d | sort | tail -n 1)"
   cat "$latest/report.md"
   ```

5. 根据改动范围执行人工冒烟测试。

   录音逻辑、设备变更处理或集成测试脚本发生变化时，还需安装本轮 Release App，
   再执行真实录音与设备切换测试：

   ```bash
   scripts/recording_integration_test.py \
     --app '/Applications/会议录音 Pro.app' \
     --yes --quick --prompt-countdown 2 --start-attempts 3
   ```

   当自动排序选中的麦克风没有有效输入时，应先做输入电平预检，再明确指定两个
   有声音且当前在线的设备，避免把静音硬件误报成应用失败：

   ```bash
   scripts/recording_integration_test.py \
     --app '/Applications/会议录音 Pro.app' \
     --yes --quick \
     --input-pair '源麦克风名称' '目标麦克风名称' \
     --output-pair '源扬声器名称' '目标扬声器名称'
   ```

6. 提交前检查：

   ```bash
   git diff --check
   git status --short
   find SimpleRecorder -name '*Conflict.swift' -print
   ```

## 自动化用例

| 编号 | 用例 | 自动化入口 | 通过标准 |
|---|---|---|---|
| A1 | 设置回读 | `scripts/run_full_qa.sh` | 设置可写入、可读取、可恢复 |
| A2 | 麦克风录音 | `4.1 microphone-basic` | 生成有效 M4A |
| A3 | 暂停继续 | `4.2 microphone-pause-resume` | 暂停/继续后生成有效文件 |
| A4 | 连续录音 | `4.5 microphone-second-pass` | 第二段录音有效，文件名不冲突 |
| A5 | MP3 输出 | `5.2 output-format-mp3` | 生成有效 MP3 |
| A6 | 系统声音 | `4.3 system-audio` | 生成有效 M4A，核心场景不能 skipped |
| A7 | 混合音源 | `4.4 mixed-audio` | 生成有效 M4A，核心场景不能 skipped |
| A8 | 定时自动录音 | `6.2 timer-auto-start` | 到点触发并保存有效文件 |
| A9 | 包体验证 | `scripts/qa_artifact_check.sh` | DMG、签名、音频元数据、日志检查通过 |

## 可听三模式验证

当需要人工听感确认三种音源都录进去时，运行：

```bash
scripts/run_audible_audio_modes_qa.sh
```

脚本会生成两段源音频：

- 系统播放源：口播“系统声音测试。system source. 一二三四五。”
- 麦克风播放源：口播“麦克风测试。microphone source. 六七八九十。”

脚本会输出三段录音结果：

- 直录系统声音。
- 直录麦克风。
- 系统 + 麦克风。

结果位于 `qa-runs/audible-mode-check-YYYYMMDD-HHMMSS/`，其中 `audible-report.md` 是测试报告，`results/*-raw.m4a` 是 App 原始录音复制件，`results/*-listen.m4a` 是便于试听的增益版。

## 人工冒烟用例

| 编号 | 用例 | 操作 | 通过标准 |
|---|---|---|---|
| M1 | 菜单栏入口 | 从 DMG 或 Release app 启动 | 菜单栏出现图标，无 Dock 图标 |
| M2 | 设置页切换 | 打开设置，切换四个 Tab | 内容不跳动，顶部间距一致 |
| M3 | 快捷键默认值 | 使用默认开始/停止和暂停/继续快捷键 | 状态变化正确，文件保存 |
| M4 | 快捷键改绑 | 修改两个快捷键 | 新快捷键生效，旧快捷键释放 |
| M5 | 快捷键冲突 | 两个动作设置成同一组合 | 弹出冲突提示，不覆盖原设置 |
| M6 | 录音中退出 | 录音中选择退出并确认 | 退出前保存文件；MP3 模式等待转码 |
| M7 | Finder 定位 | 开启录音后打开文件夹 | 结束录音后定位输出文件 |
| M8 | 保存目录 | 改到测试目录并重启 | 新录音落在测试目录 |
| M9 | 开机自动启动 | 切换开关并查看系统登录项 | UI 与系统状态一致，测试后恢复 |
| M10 | 权限引导 | 重置麦克风或屏幕录制权限后操作 | 给出系统设置引导，不生成空文件 |
| M11 | 更新菜单 | 非录音状态打开菜单，再开始录音后打开菜单 | 非录音状态显示“当前版本 x.y.z”或“下载并安装 x.y.z...”；录音中更新项禁用 |

## 长录音用例

| 编号 | 用例 | 操作 | 通过标准 |
|---|---|---|---|
| L1 | 30 分钟 M4A | M4A 模式录制 30 分钟 | 文件可播放，日志无写入失败 |
| L2 | 30 分钟 MP3 | MP3 模式录制 30 分钟 | 转码完成，MP3 可播放，源 M4A 按预期移除 |
| L3 | 长录音暂停 | 录制中暂停 2 次再继续 | 文件可播放，状态不乱 |
| L4 | 磁盘空间提示 | 设置较长最大时长并使用低空间测试盘 | 提示最小空间要求与实际门槛一致 |

长录音不要求每次代码提交都跑；改动涉及录音写入、转码、停止、退出、磁盘检查时必须跑。

## 失败处理

测试失败时按以下顺序处理：

1. 记录失败编号、命令、日志路径和复现条件。
2. 判断级别：P0/P1/P2/P3。
3. P0/P1 直接修复，不进入交付。
4. P2/P3 写入 QA 报告或 changelog，明确是否阻断。
5. 修复后重跑失败用例和相关完整 QA。

## QA 证据要求

每轮交付至少保留：

- Git commit。
- QA 报告路径。
- DMG 路径和 SHA256。
- macOS 版本。
- 失败项和未执行项说明。
- 如果是正式发布，保留 notarization、stapler、Gatekeeper 结果。
- 如果是正式发布，保留 GitHub Release 中 DMG 与 `appcast.xml` 的下载链接和 appcast 内容摘要。
