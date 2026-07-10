#!/usr/bin/env bash

# 会议录音 Pro 打包脚本
# 功能：清理 -> 构建 -> 签名 -> 生成 DMG -> DMG 签名 -> 可选公证 -> 校验

set -euo pipefail

PRODUCT_APP_NAME="SimpleRecorder"
DISPLAY_APP_NAME="会议录音 Pro"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
RELEASE_APP_PATH="${BUILD_DIR}/Release/${PRODUCT_APP_NAME}.app"
DMG_STAGING_DIR="${BUILD_DIR}/dmg-staging"
STAGED_APP_PATH="${DMG_STAGING_DIR}/${DISPLAY_APP_NAME}.app"
DMG_NAME="MeetingRecorderPro_$(date +%Y%m%d).dmg"
DMG_PATH="${PROJECT_DIR}/${DMG_NAME}"
TEMP_DMG="${PROJECT_DIR}/temp.dmg"
VOLUME_NAME="${DISPLAY_APP_NAME}"
RELEASE_BUILD=false
PUBLISH_RELEASE=false
PUBLISH_QA_EVIDENCE=""
LAME_SOURCE_ARCHIVE="${PROJECT_DIR}/SimpleRecorder/ThirdParty/lame/lame-3.100.tar.gz"
LAME_SOURCE_SHA256="ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"

cleanup_temporary_release_evidence() {
    if [ -n "${PUBLISH_QA_EVIDENCE}" ]; then
        rm -f "${PUBLISH_QA_EVIDENCE}"
    fi
}
trap cleanup_temporary_release_evidence EXIT

parse_release_flag() {
    case "$(printf '%s' "${RELEASE:-0}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|y) RELEASE_BUILD=true ;;
        0|false|no|n|"") RELEASE_BUILD=false ;;
        *)
            echo "RELEASE must be a boolean: 1/0/true/false/yes/no" >&2
            exit 2
            ;;
    esac
}

parse_publish_flag() {
    case "$(printf '%s' "${PUBLISH_GITHUB_RELEASE:-0}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|y) PUBLISH_RELEASE=true ;;
        0|false|no|n|"") PUBLISH_RELEASE=false ;;
        *)
            echo "PUBLISH_GITHUB_RELEASE must be a boolean: 1/0/true/false/yes/no" >&2
            exit 2
            ;;
    esac
}

parse_release_flag
parse_publish_flag

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

if [ -f .env ]; then
    load_env_file .env
    echo "已从 .env 加载环境变量"
    parse_release_flag
    parse_publish_flag
fi

if [ "${PUBLISH_RELEASE}" = true ] && [ "${RELEASE_BUILD}" != true ]; then
    echo "PUBLISH_GITHUB_RELEASE=1 必须与 RELEASE=1 同时使用，禁止发布未公证的开发包。" >&2
    exit 1
fi

if [ "${PUBLISH_RELEASE}" = true ]; then
    if [ -z "${RELEASE_INTEGRATION_REPORT:-}" ] || [ ! -f "${RELEASE_INTEGRATION_REPORT}" ]; then
        echo "正式发布必须设置 RELEASE_INTEGRATION_REPORT，指向当前 HEAD/版本通过的真实录音 report.json。" >&2
        exit 1
    fi
    RELEASE_INTEGRATION_REPORT="$(cd "$(dirname "${RELEASE_INTEGRATION_REPORT}")" && pwd)/$(basename "${RELEASE_INTEGRATION_REPORT}")"
    export RELEASE_INTEGRATION_REPORT
fi

if [ ! -f "${LAME_SOURCE_ARCHIVE}" ]; then
    echo "缺少 LAME 3.100 完整源码包: ${LAME_SOURCE_ARCHIVE}" >&2
    exit 1
fi
ACTUAL_LAME_SOURCE_SHA256="$(shasum -a 256 "${LAME_SOURCE_ARCHIVE}" | awk '{print $1}')"
if [ "${ACTUAL_LAME_SOURCE_SHA256}" != "${LAME_SOURCE_SHA256}" ]; then
    echo "LAME 源码包 SHA-256 不匹配，禁止构建分发包。" >&2
    exit 1
fi

if [ "${RELEASE_BUILD}" = true ] && [ "${PUBLISH_RELEASE}" != true ]; then
    if [ -z "${NOTARY_PROFILE:-}" ]; then
        echo "RELEASE=1 要求设置 NOTARY_PROFILE，用于 notarytool 公证。" >&2
        exit 1
    fi
    if [ -z "${DEVELOPER_ID_CERT:-}" ] \
        && ! security find-identity -p codesigning -v | grep -q "Developer ID Application"; then
        echo "RELEASE=1 要求 Developer ID Application 证书，不能使用 ad-hoc 签名。" >&2
        exit 1
    fi
fi

if [ "${PUBLISH_RELEASE}" = true ]; then
    if [ -n "${PUBLISH_DMG_PATH:-}" ]; then
        DMG_PATH="$(cd "$(dirname "${PUBLISH_DMG_PATH}")" && pwd)/$(basename "${PUBLISH_DMG_PATH}")"
    fi
    if [ ! -d "${RELEASE_APP_PATH}" ] || [ ! -f "${DMG_PATH}" ]; then
        echo "发布只使用已经完成真实录音测试的现成 App/DMG；请先执行 RELEASE=1 ./build_dmg.sh，再安装该包并运行录音集成测试。" >&2
        exit 1
    fi

    echo "--- 校验待发布的现成 App/DMG（不会重新构建） ---"
    "${PROJECT_DIR}/scripts/verify_public_release.sh" "${RELEASE_APP_PATH}"
    codesign --verify --deep --strict --verbose=2 "${RELEASE_APP_PATH}"
    if ! codesign -dv --verbose=4 "${RELEASE_APP_PATH}" 2>&1 | grep -q '^Authority=Developer ID Application:'; then
        echo "待发布 App 不是 Developer ID Application 签名。" >&2
        exit 1
    fi
    codesign --verify --verbose=2 "${DMG_PATH}"
    hdiutil verify "${DMG_PATH}"
    xcrun stapler validate "${DMG_PATH}"
    spctl --assess --type open --context context:primary-signature --verbose=4 "${DMG_PATH}"

    echo "--- 对同一份最终 DMG 运行完整 QA ---"
    PUBLISH_QA_EVIDENCE="$(mktemp /tmp/MeetingRecorderProReleaseQA.XXXXXX)"
    QA_SKIP_BUILD=true \
    QA_DMG_PATH="${DMG_PATH}" \
    QA_EVIDENCE_PATH="${PUBLISH_QA_EVIDENCE}" \
    QA_ALLOW_SKIPS=false \
        "${PROJECT_DIR}/scripts/run_full_qa.sh"

    echo "--- 发布到 GitHub Releases 并更新 Sparkle appcast ---"
    RELEASE_QA_EVIDENCE="${PUBLISH_QA_EVIDENCE}" \
        "${PROJECT_DIR}/scripts/publish_github_release.sh" "${DMG_PATH}"
    echo "--- 发布完成! ---"
    echo "已发布文件: ${DMG_PATH}"
    exit 0
fi

echo "--- [1/5] 清理环境 ---"
rm -rf "${BUILD_DIR}"
rm -f "${TEMP_DMG}" "${DMG_PATH}"

echo "--- [2/5] 执行 Xcode 构建 (Release) ---"
cd "${PROJECT_DIR}"
set -o pipefail
xcodebuild -project "${PRODUCT_APP_NAME}.xcodeproj" \
           -scheme "${PRODUCT_APP_NAME}" \
           -configuration Release \
           -destination "platform=macOS,arch=arm64" \
           -derivedDataPath "${BUILD_DIR}/DerivedData" \
           -packageAuthorizationProvider netrc \
           SYMROOT="${BUILD_DIR}" \
           CODE_SIGNING_ALLOWED=NO \
           CODE_SIGNING_REQUIRED=NO \
           CODE_SIGN_IDENTITY="" \
           SWIFT_ACTIVE_COMPILATION_CONDITIONS="" \
           build | grep -E "(BUILD|error:|warning:)"
set +o pipefail

"${PROJECT_DIR}/scripts/verify_public_release.sh" "${RELEASE_APP_PATH}"

echo "--- [3/5] 代码签名 ---"

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

if [ "${RELEASE_BUILD}" = true ]; then
    if [ "${SIGNING_IS_ADHOC}" = true ]; then
        echo "RELEASE=1 要求 Developer ID Application 证书，不能使用 ad-hoc 签名。" >&2
        exit 1
    fi
    if [ -z "${NOTARY_PROFILE:-}" ]; then
        echo "RELEASE=1 要求设置 NOTARY_PROFILE，用于 notarytool 公证。" >&2
        exit 1
    fi
fi

codesign_args=(--force --strict --options runtime --entitlements "${PROJECT_DIR}/SimpleRecorder/SimpleRecorder.entitlements" --sign "${SIGNING_IDENTITY}")
if [ "${SIGNING_IS_ADHOC}" = false ]; then
    codesign_args+=(--timestamp)
fi

sign_component_args=(--force --strict --options runtime --preserve-metadata=identifier,entitlements --sign "${SIGNING_IDENTITY}")
if [ "${SIGNING_IS_ADHOC}" = false ]; then
    sign_component_args+=(--timestamp)
fi

SPARKLE_FRAMEWORK_PATH="${RELEASE_APP_PATH}/Contents/Frameworks/Sparkle.framework"
if [ -d "${SPARKLE_FRAMEWORK_PATH}" ]; then
    for component in \
        "${SPARKLE_FRAMEWORK_PATH}/Versions/Current/XPCServices/Downloader.xpc" \
        "${SPARKLE_FRAMEWORK_PATH}/Versions/Current/XPCServices/Installer.xpc" \
        "${SPARKLE_FRAMEWORK_PATH}/Versions/Current/Updater.app" \
        "${SPARKLE_FRAMEWORK_PATH}/Versions/Current/Autoupdate" \
        "${SPARKLE_FRAMEWORK_PATH}"; do
        if [ -e "${component}" ]; then
            codesign "${sign_component_args[@]}" "${component}"
        fi
    done
fi

codesign "${codesign_args[@]}" "${RELEASE_APP_PATH}"

xattr -cr "${RELEASE_APP_PATH}"
echo "已清除隔离属性 (xattr -cr)"

echo "--- [4/5] 生成 DMG 镜像 ---"
rm -rf "${DMG_STAGING_DIR}"
mkdir -p "${DMG_STAGING_DIR}"
ditto "${RELEASE_APP_PATH}" "${STAGED_APP_PATH}"
cp "${PROJECT_DIR}/LICENSE" "${DMG_STAGING_DIR}/LICENSE.txt"
cp "${PROJECT_DIR}/THIRD_PARTY_NOTICES.md" "${DMG_STAGING_DIR}/THIRD_PARTY_NOTICES.md"
cp "${PROJECT_DIR}/SimpleRecorder/ThirdParty/lame/COPYING" "${DMG_STAGING_DIR}/LAME-COPYING.txt"
cp "${PROJECT_DIR}/docs/lame-relinking.md" "${DMG_STAGING_DIR}/LAME-SOURCE-AND-RELINKING.md"
cp "${LAME_SOURCE_ARCHIVE}" "${DMG_STAGING_DIR}/lame-3.100.tar.gz"

PERMISSION_FLOW_LICENSE="${BUILD_DIR}/DerivedData/SourcePackages/checkouts/PermissionFlow/LICENSE"
SPARKLE_LICENSE="${BUILD_DIR}/DerivedData/SourcePackages/checkouts/Sparkle/LICENSE"
if [ ! -f "${PERMISSION_FLOW_LICENSE}" ] || [ ! -f "${SPARKLE_LICENSE}" ]; then
    echo "未找到 Swift Package 许可证文件，停止打包以避免分发不完整。" >&2
    exit 1
fi
cp "${PERMISSION_FLOW_LICENSE}" "${DMG_STAGING_DIR}/PermissionFlow-LICENSE.txt"
cp "${SPARKLE_LICENSE}" "${DMG_STAGING_DIR}/Sparkle-LICENSE.txt"
ln -s /Applications "${DMG_STAGING_DIR}/Applications"
hdiutil create -volname "${VOLUME_NAME}" -srcfolder "${DMG_STAGING_DIR}" -ov -format UDZO -fs HFS+ "${TEMP_DMG}"
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
codesign --verify --deep --strict --verbose=2 "${RELEASE_APP_PATH}"
codesign --verify --deep --strict --verbose=2 "${STAGED_APP_PATH}"
codesign --verify --verbose=2 "${DMG_PATH}"
hdiutil verify "${DMG_PATH}"
if [ "${RELEASE_BUILD}" = true ]; then
    xcrun stapler validate "${DMG_PATH}"
fi
if spctl --assess --type open --context context:primary-signature --verbose=4 "${DMG_PATH}"; then
    echo "Gatekeeper: accepted"
else
    if [ "${RELEASE_BUILD}" = true ]; then
        echo "Gatekeeper: not accepted，RELEASE=1 发布包校验失败。" >&2
        exit 1
    fi
    echo "Gatekeeper: not accepted（通常是未公证或 ad-hoc 签名）。"
fi

echo "--- 打包完成! ---"
echo "生成文件: ${DMG_PATH}"
