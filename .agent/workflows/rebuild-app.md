---
description: 重新构建并启动极简录音 Mac 应用
---
# 重新构建并启动应用

// turbo-all

## 步骤

1. 关闭正在运行的应用实例
```bash
pkill -9 -f "SimpleRecorder.app" 2>/dev/null || true
```

2. 等待进程完全退出
```bash
sleep 1
```

3. 构建应用
```bash
cd "/Users/baozheng/代码文件/MAC 端录音软件" && xcodebuild -project SimpleRecorder.xcodeproj -scheme SimpleRecorder -configuration Debug build 2>&1 | grep -E "(BUILD|error:|warning:)" | tail -10
```

4. 启动应用
```bash
open "/Users/baozheng/Library/Developer/Xcode/DerivedData/SimpleRecorder-djrwyvonylczszfzilmxwhrqevyb/Build/Products/Debug/SimpleRecorder.app"
```

## 注意事项
- 如果构建失败，检查错误信息并修复后重试
- 确保 Xcode DerivedData 路径正确
