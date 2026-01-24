#!/bin/bash

# 会议录音 Pro 打包脚本
# 功能：清理 -> 构建 -> 签名 -> 生成 DMG -> DMG 签名

set -e

APP_NAME="SimpleRecorder"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
RELEASE_APP_PATH="${BUILD_DIR}/Release/${APP_NAME}.app"
DMG_NAME="MeetingRecorderPro_$(date +%Y%m%d).dmg"
TEMP_DMG="temp.dmg"
VOLUME_NAME="会议录音 Pro"

echo "--- [1/5] 清理环境 ---"
rm -rf "${BUILD_DIR}"
rm -f "${PROJECT_DIR}"/*.dmg

echo "--- [2/5] 执行 Xcode 构建 (Release) ---"
cd "${PROJECT_DIR}"
xcodebuild -project "${APP_NAME}.xcodeproj" \
           -scheme "${APP_NAME}" \
           -configuration Release \
           -derivedDataPath "${BUILD_DIR}/DerivedData" \
           SYMROOT="${BUILD_DIR}" \
           CODE_SIGNING_ALLOWED=NO \
           CODE_SIGNING_REQUIRED=NO \
           build | grep -E "(BUILD|error:|warning:)"

echo "--- [3/5] 代码签名 ---"

# 1. 加载环境变量 (参考规约)
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
    echo "已从 .env 加载环境变量"
fi

# 2. 确定签名证书
SIGNING_IDENTITY="-"
if [ -n "$DEVELOPER_ID_CERT" ]; then
    SIGNING_IDENTITY="$DEVELOPER_ID_CERT"
    echo "使用环境变量中的证书: ${SIGNING_IDENTITY}"
elif security find-identity -p codesigning -v | grep -q "Developer ID Application"; then
    SIGNING_IDENTITY=$(security find-identity -p codesigning -v | grep "Developer ID Application" | head -1 | awk '{print $2}')
    echo "使用检测到的系统证书: ${SIGNING_IDENTITY}"
else
    echo "未检测到 Developer ID 证书，将使用 Ad-hoc 签名 (-)"
fi

# 3. 执行签名
codesign --force --deep --strict --options runtime --entitlements "${PROJECT_DIR}/SimpleRecorder/SimpleRecorder.entitlements" --sign "${SIGNING_IDENTITY}" "${RELEASE_APP_PATH}"

# 4. 清除隔离属性 (规约必做步骤)
xattr -cr "${RELEASE_APP_PATH}"
echo "已清除隔离属性 (xattr -cr)"

echo "--- [4/5] 生成 DMG 镜像 ---"
hdiutil create -volname "${VOLUME_NAME}" -srcfolder "${RELEASE_APP_PATH}" -ov -format UDZO "${TEMP_DMG}"
mv "${TEMP_DMG}" "${DMG_NAME}"

echo "--- [5/5] DMG 签名 ---"
codesign --force --sign "${SIGNING_IDENTITY}" "${DMG_NAME}"
xattr -cr "${DMG_NAME}"

echo "--- 打包完成! ---"
echo "生成文件: ${DMG_NAME}"
