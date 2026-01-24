---
trigger: always_on
glob: "**/*.swift,**/*.m,**/*.h,**/*.xib,**/*.storyboard,**/*.plist,**/*.xcconfig"
description: 会议录音 Pro 开发规则 - 每次代码修改后自动重新构建并启动应用
---

# 会议录音 Pro 开发规则

## 核心原则

每次修改完代码之后，必须**重新构建**并**启动新的应用**，方便用户实时测试修改效果。

## 执行流程

### 1. 代码修改后的必做动作

每当完成代码修改（包括但不限于 `.swift`、`.m`、`.h`、`.xib`、`.storyboard`、`.plist` 文件），必须依次执行：

1. **关闭正在运行的应用实例**
```bash
pkill -9 -f "SimpleRecorder.app" 2>/dev/null || true
```

2. **等待进程完全退出**
```bash
sleep 1
```

3. **构建应用（会议录音 Pro）**
```bash
cd "/Users/baozheng/代码文件/MAC 端录音软件" && xcodebuild -project SimpleRecorder.xcodeproj -scheme SimpleRecorder -configuration Release build 2>&1 | grep -E "(BUILD|error:|warning:)" | tail -10
```

4. **启动应用**
```bash
open "/Users/baozheng/Library/Developer/Xcode/DerivedData/SimpleRecorder-djrwyvonylczszfzilmxwhrqevyb/Build/Products/Release/SimpleRecorder.app"
```

5. **通知用户**：告知用户「会议录音 Pro」已重新启动，可以开始测试

### 2. 注意事项

- 如果构建失败，检查错误信息并修复后重试
- 确保 Xcode DerivedData 路径正确
- 构建命令会过滤输出，只显示关键的 BUILD 状态、错误和警告信息
