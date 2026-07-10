# LAME 源码与重链接说明

会议录音 Pro 静态链接 LAME `3.100` 以提供 MP3 输出。本文说明如何获取对应源码、构建可替换的库，并将应用重新链接到修改后的库。

## 对应版本

- LAME 版本：`3.100`
- 源码包：<https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz>
- 项目内完整源码包：`SimpleRecorder/ThirdParty/lame/lame-3.100.tar.gz`
- 源码包 SHA-256：`ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e`
- 仓库内静态库 SHA-256：`dea6b41806721d6e7494250d2d5fa30552e16fd155e632fddbd0d11a1cbce44c`

DMG 和对应 GitHub Release 都随附 `lame-3.100.tar.gz`。先校验随附源码包：

```bash
echo "ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e  lame-3.100.tar.gz" \
  | shasum -a 256 -c -
```

也可以从上游重新下载并校验：

```bash
curl -L --fail -o lame-3.100.tar.gz \
  https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
echo "ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e  lame-3.100.tar.gz" \
  | shasum -a 256 -c -
```

## 构建 arm64 静态库

以 macOS 13 为最低系统版本，构建不包命令行前端的静态库：

```bash
tar -xzf lame-3.100.tar.gz
cd lame-3.100

export MACOSX_DEPLOYMENT_TARGET=13.0
./configure \
  --disable-shared \
  --enable-static \
  --disable-frontend \
  CFLAGS="-O2 -arch arm64 -mmacosx-version-min=13.0"

make -j"$(sysctl -n hw.logicalcpu)"
lipo -info libmp3lame/.libs/libmp3lame.a
```

`lipo -info` 应显示 `arm64`。修改 LAME 源码时，在执行上述步骤前应用你的补丁。

## 替换并重新链接应用

1. 检出与已分发版本对应的 Git tag。
2. 用新构建的静态库替换 `SimpleRecorder/ThirdParty/lame/libmp3lame.a`。
3. 如果公开头文件发生改动，同步替换 `SimpleRecorder/ThirdParty/lame/lame.h`。
4. 执行项目的 Release 构建：

```bash
xcodebuild \
  -project SimpleRecorder.xcodeproj \
  -scheme SimpleRecorder \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -packageAuthorizationProvider netrc \
  CODE_SIGNING_ALLOWED=NO \
  build
```

5. 执行 `xcodebuild test` 和项目录音 QA，确认 M4A 与 MP3 都能生成可解码、有效时长且非静音的文件。

上述步骤用修改后的 LAME 静态库重新产生应用二进制文件。公开分发时还需按项目发布规则完成 Developer ID 签名和公证。
