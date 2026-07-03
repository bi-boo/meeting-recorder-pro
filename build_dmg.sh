#!/usr/bin/env bash

# 会议录音 Pro 打包脚本
# 功能：清理 -> 构建 -> 签名 -> 生成 DMG -> DMG 签名 -> 可选公证 -> 校验

set -euo pipefail

APP_NAME="SimpleRecorder"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
RELEASE_APP_PATH="${BUILD_DIR}/Release/${APP_NAME}.app"
DMG_NAME="MeetingRecorderPro_$(date +%Y%m%d).dmg"
DMG_PATH="${PROJECT_DIR}/${DMG_NAME}"
TEMP_DMG="${PROJECT_DIR}/temp.dmg"
VOLUME_NAME="会议录音 Pro"

load_env_file() {
    local env_file="$1"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == *=* ]] || continue

        local key="${line%%=*}"
        local value="${line#*=}"
        key="$(echo "$key" | xargs)"
        value="$(echo "$value" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"

        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        export "$key=$value"
    done < "$env_file"
}

echo "--- [1/5] 清理环境 ---"
rm -rf "${BUILD_DIR}"
rm -f "${TEMP_DMG}" "${DMG_PATH}"

echo "--- [2/5] 执行 Xcode 构建 (Release) ---"
cd "${PROJECT_DIR}"
set -o pipefail
xcodebuild -project "${APP_NAME}.xcodeproj" \
           -scheme "${APP_NAME}" \
           -configuration Release \
           -destination "platform=macOS,arch=arm64" \
           -derivedDataPath "${BUILD_DIR}/DerivedData" \
           SYMROOT="${BUILD_DIR}" \
           CODE_SIGNING_ALLOWED=NO \
           CODE_SIGNING_REQUIRED=NO \
           CODE_SIGN_IDENTITY="" \
           build | grep -E "(BUILD|error:|warning:)"
set +o pipefail

echo "--- [3/5] 代码签名 ---"

if [ -f .env ]; then
    load_env_file .env
    echo "已从 .env 加载环境变量"
fi

SIGNING_IDENTITY="-"
SIGNING_IS_ADHOC=true
if [ -n "${DEVELOPER_ID_CERT:-}" ]; then
    SIGNING_IDENTITY="$DEVELOPER_ID_CERT"
    SIGNING_IS_ADHOC=false
    echo "使用环境变量中的证书: ${SIGNING_IDENTITY}"
elif security find-identity -p codesigning -v | grep -q "Developer ID Application"; then
    SIGNING_IDENTITY=$(security find-identity -p codesigning -v | grep "Developer ID Application" | head -1 | awk '{print $2}')
    SIGNING_IS_ADHOC=false
    echo "使用检测到的系统证书: ${SIGNING_IDENTITY}"
else
    echo "未检测到 Developer ID 证书，将使用 ad-hoc 签名；该产物只适合本机验证。"
fi

codesign_args=(--force --strict --options runtime --entitlements "${PROJECT_DIR}/SimpleRecorder/SimpleRecorder.entitlements" --sign "${SIGNING_IDENTITY}")
if [ "${SIGNING_IS_ADHOC}" = false ]; then
    codesign_args+=(--timestamp)
fi

codesign "${codesign_args[@]}" "${RELEASE_APP_PATH}"

xattr -cr "${RELEASE_APP_PATH}"
echo "已清除隔离属性 (xattr -cr)"

echo "--- [4/5] 生成 DMG 镜像 ---"
hdiutil create -volname "${VOLUME_NAME}" -srcfolder "${RELEASE_APP_PATH}" -ov -format UDZO "${TEMP_DMG}"
mv "${TEMP_DMG}" "${DMG_PATH}"

echo "--- [5/5] DMG 签名 ---"
if [ "${SIGNING_IS_ADHOC}" = false ]; then
    codesign --force --timestamp --sign "${SIGNING_IDENTITY}" "${DMG_PATH}"
else
    codesign --force --sign "${SIGNING_IDENTITY}" "${DMG_PATH}"
fi
xattr -cr "${DMG_PATH}"

if [ -n "${NOTARY_PROFILE:-}" ] && [ "${SIGNING_IS_ADHOC}" = false ]; then
    echo "--- 可选公证：提交 notarytool ---"
    xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
    xcrun stapler staple "${DMG_PATH}"
fi

echo "--- 校验产物 ---"
codesign --verify --strict --verbose=2 "${RELEASE_APP_PATH}"
codesign --verify --verbose=2 "${DMG_PATH}"
hdiutil verify "${DMG_PATH}"
if spctl --assess --type open --context context:primary-signature --verbose=4 "${DMG_PATH}"; then
    echo "Gatekeeper: accepted"
else
    echo "Gatekeeper: not accepted（通常是未公证或 ad-hoc 签名）。"
fi

echo "--- 打包完成! ---"
echo "生成文件: ${DMG_PATH}"
