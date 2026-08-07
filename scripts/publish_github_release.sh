#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${GITHUB_REPOSITORY:-bi-boo/meeting-recorder-pro}"
DMG_PATH="${1:-}"
APP_PATH="${ROOT_DIR}/build/Release/SimpleRecorder.app"
LAME_SOURCE_ARCHIVE="${ROOT_DIR}/SimpleRecorder/ThirdParty/lame/lame-3.100.tar.gz"
LAME_SOURCE_SHA256="ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"
MOUNT_DIR=""
RELEASE_VENV_DIR=""

cleanup_mount() {
    if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
        hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
        rm -rf "$MOUNT_DIR"
    fi
    if [[ -n "$RELEASE_VENV_DIR" && "$RELEASE_VENV_DIR" == "$ROOT_DIR/build/release-venv."* ]]; then
        rm -rf -- "$RELEASE_VENV_DIR"
    fi
}
trap cleanup_mount EXIT

is_true() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|y) return 0 ;;
        *) return 1 ;;
    esac
}

if ! is_true "${RELEASE:-0}" || ! is_true "${PUBLISH_GITHUB_RELEASE:-0}"; then
    echo "发布脚本只接受 RELEASE=1 PUBLISH_GITHUB_RELEASE=1 的显式调用。" >&2
    exit 1
fi

if [[ -z "$DMG_PATH" ]]; then
    DMG_PATH="$(find "$ROOT_DIR" -maxdepth 1 -type f -name 'MeetingRecorderPro_*.dmg' -print | sort | tail -n 1)"
fi
if [[ -z "$DMG_PATH" || ! -f "$DMG_PATH" ]]; then
    echo "未找到 DMG。用法: RELEASE=1 PUBLISH_GITHUB_RELEASE=1 scripts/publish_github_release.sh /path/to/MeetingRecorderPro_YYYYMMDD.dmg" >&2
    exit 1
fi
DMG_PATH="$(cd "$(dirname "$DMG_PATH")" && pwd)/$(basename "$DMG_PATH")"

if [[ -z "${RELEASE_QA_EVIDENCE:-}" || ! -f "${RELEASE_QA_EVIDENCE:-}" ]]; then
    echo "缺少 RELEASE_QA_EVIDENCE；发布必须消费本次最终 DMG 的完整 QA 证据。" >&2
    exit 1
fi
if [[ -z "${RELEASE_INTEGRATION_REPORT:-}" || ! -f "${RELEASE_INTEGRATION_REPORT:-}" ]]; then
    echo "缺少 RELEASE_INTEGRATION_REPORT；发布必须消费当前版本的真实录音集成报告。" >&2
    exit 1
fi
if [[ ! -f "$LAME_SOURCE_ARCHIVE" ]]; then
    echo "缺少随 Release 分发的 LAME 完整源码包: $LAME_SOURCE_ARCHIVE" >&2
    exit 1
fi
if [[ "$(shasum -a 256 "$LAME_SOURCE_ARCHIVE" | awk '{print $1}')" != "$LAME_SOURCE_SHA256" ]]; then
    echo "LAME 完整源码包 SHA-256 不匹配。" >&2
    exit 1
fi

for tool in gh git codesign hdiutil spctl xcrun rg python3 shasum cmp; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "缺少发布依赖命令: $tool" >&2
        exit 1
    fi
done

cd "$ROOT_DIR"

if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
    echo "Git 工作区不干净，禁止发布。" >&2
    git status --short >&2
    exit 1
fi
if find SimpleRecorder -name '*Conflict.swift' -print -quit | grep -q .; then
    echo "存在同步冲突 Swift 文件，禁止发布。" >&2
    exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "Release App 不存在: $APP_PATH" >&2
    exit 1
fi

/usr/bin/python3 "$ROOT_DIR/scripts/release_artifact_manifest.py" verify \
    --manifest "$ROOT_DIR/build/release-artifact-manifest.json" \
    --repo-root "$ROOT_DIR" \
    --app "$APP_PATH" \
    --dmg "$DMG_PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
TAG="${RELEASE_TAG:-v${VERSION}}"
if [[ "$TAG" != "v${VERSION}" ]]; then
    echo "发布 tag 必须与 App 版本一致：期望 v${VERSION}，实际 ${TAG}。" >&2
    exit 1
fi
HEAD_COMMIT="$(git rev-parse HEAD)"
APPCAST_PATH="${ROOT_DIR}/build/appcast.xml"
NOTES_PATH="${ROOT_DIR}/build/release-notes-${TAG}.md"

ORIGIN_URL="$(git remote get-url origin)"
case "$ORIGIN_URL" in
    "https://github.com/${REPO}"|"https://github.com/${REPO}.git"|"git@github.com:${REPO}"|"git@github.com:${REPO}.git"|"ssh://git@github.com/${REPO}.git") ;;
    *)
        echo "origin ($ORIGIN_URL) 与发布仓库 ($REPO) 不一致。" >&2
        exit 1
        ;;
esac

git fetch origin --prune --tags
if ! git branch -r --contains "$HEAD_COMMIT" | rg 'origin/' >/dev/null; then
    echo "当前 HEAD 还不在 origin 的任何远程分支上，禁止发布。" >&2
    exit 1
fi

if ! git rev-parse --verify --quiet "refs/tags/${TAG}" >/dev/null; then
    echo "本地 tag ${TAG} 不存在；请先在已验证的 HEAD 上创建并推送 tag。" >&2
    exit 1
fi
LOCAL_TAG_COMMIT="$(git rev-list -n 1 "$TAG")"
if [[ "$LOCAL_TAG_COMMIT" != "$HEAD_COMMIT" ]]; then
    echo "本地 tag ${TAG} 不指向当前 HEAD。" >&2
    exit 1
fi

REMOTE_TAG_COMMIT="$(git ls-remote origin "refs/tags/${TAG}^{}" | awk 'NR == 1 {print $1}')"
if [[ -z "$REMOTE_TAG_COMMIT" ]]; then
    REMOTE_TAG_COMMIT="$(git ls-remote origin "refs/tags/${TAG}" | awk 'NR == 1 {print $1}')"
fi
if [[ "$REMOTE_TAG_COMMIT" != "$HEAD_COMMIT" ]]; then
    echo "远程 tag ${TAG} 不存在或不指向当前 HEAD。" >&2
    exit 1
fi

"$ROOT_DIR/scripts/verify_public_release.sh" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
if ! codesign -dv --verbose=4 "$APP_PATH" 2>&1 | rg '^Authority=Developer ID Application:' >/dev/null; then
    echo "Release App 不是 Developer ID Application 签名。" >&2
    exit 1
fi
codesign --verify --verbose=2 "$DMG_PATH"
hdiutil verify "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

MOUNT_DIR="$(mktemp -d /tmp/MeetingRecorderProRelease.XXXXXX)"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$DMG_PATH" >/dev/null
DMG_APP_PATH="$(find "$MOUNT_DIR" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$DMG_APP_PATH" ]]; then
    echo "DMG 内未找到 App。" >&2
    exit 1
fi
DMG_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DMG_APP_PATH/Contents/Info.plist")"
DMG_BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DMG_APP_PATH/Contents/Info.plist")"
if [[ "$DMG_VERSION" != "$VERSION" || "$DMG_BUILD_VERSION" != "$BUILD_VERSION" ]]; then
    echo "DMG 内版本 ${DMG_VERSION} (${DMG_BUILD_VERSION}) 与当前 Release ${VERSION} (${BUILD_VERSION}) 不一致。" >&2
    exit 1
fi
APP_EXECUTABLE_SHA256="$(shasum -a 256 "$APP_PATH/Contents/MacOS/SimpleRecorder" | awk '{print $1}')"
DMG_EXECUTABLE_SHA256="$(shasum -a 256 "$DMG_APP_PATH/Contents/MacOS/SimpleRecorder" | awk '{print $1}')"
if [[ "$APP_EXECUTABLE_SHA256" != "$DMG_EXECUTABLE_SHA256" ]]; then
    echo "DMG 内 App 可执行文件与完成真实录音测试的 Release App 不一致。" >&2
    exit 1
fi
"$ROOT_DIR/scripts/verify_public_release.sh" "$DMG_APP_PATH"
codesign --verify --deep --strict --verbose=2 "$DMG_APP_PATH"
DMG_LAME_SOURCE="$MOUNT_DIR/lame-3.100.tar.gz"
DMG_NOTICE_FILES=(
    "LICENSE.txt"
    "THIRD_PARTY_NOTICES.md"
    "LAME-COPYING.txt"
    "LAME-SOURCE-AND-RELINKING.md"
    "lame-3.100.tar.gz"
    "PermissionFlow-LICENSE.txt"
    "Sparkle-LICENSE.txt"
)
SOURCE_NOTICE_FILES=(
    "$ROOT_DIR/LICENSE"
    "$ROOT_DIR/THIRD_PARTY_NOTICES.md"
    "$ROOT_DIR/SimpleRecorder/ThirdParty/lame/COPYING"
    "$ROOT_DIR/docs/lame-relinking.md"
    "$LAME_SOURCE_ARCHIVE"
    "$ROOT_DIR/build/DerivedData/SourcePackages/checkouts/PermissionFlow/LICENSE"
    "$ROOT_DIR/build/DerivedData/SourcePackages/checkouts/Sparkle/LICENSE"
)
for index in "${!DMG_NOTICE_FILES[@]}"; do
    dmg_notice="$MOUNT_DIR/${DMG_NOTICE_FILES[$index]}"
    source_notice="${SOURCE_NOTICE_FILES[$index]}"
    if [[ ! -f "$dmg_notice" || ! -f "$source_notice" ]]; then
        echo "DMG 分发材料缺失: ${DMG_NOTICE_FILES[$index]}" >&2
        exit 1
    fi
    if ! cmp -s "$source_notice" "$dmg_notice"; then
        echo "DMG 分发材料不是当前仓库/依赖构建中的版本: ${DMG_NOTICE_FILES[$index]}" >&2
        exit 1
    fi
done
if [[ ! -L "$MOUNT_DIR/Applications" ]]; then
    echo "DMG 内缺少 Applications 安装入口。" >&2
    exit 1
fi
if [[ "$(shasum -a 256 "$DMG_LAME_SOURCE" | awk '{print $1}')" != "$LAME_SOURCE_SHA256" ]]; then
    echo "DMG 内 LAME 源码包 SHA-256 不匹配。" >&2
    exit 1
fi
hdiutil detach "$MOUNT_DIR" >/dev/null
rm -rf "$MOUNT_DIR"
MOUNT_DIR=""

"$ROOT_DIR/scripts/verify_release_evidence.py" \
    --qa-evidence "$RELEASE_QA_EVIDENCE" \
    --integration-report "$RELEASE_INTEGRATION_REPORT" \
    --app "$APP_PATH" \
    --dmg "$DMG_PATH"

RELEASE_PYTHON="$("$ROOT_DIR/scripts/setup_release_python.sh")"
RELEASE_VENV_DIR="$(cd "$(dirname "$RELEASE_PYTHON")/.." && pwd)"
"$RELEASE_PYTHON" -I "$ROOT_DIR/scripts/generate_appcast.py" \
    --dmg "$DMG_PATH" \
    --app "$APP_PATH" \
    --repo "$REPO" \
    --tag "$TAG" \
    --output "$APPCAST_PATH"

SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
cat > "$NOTES_PATH" <<EOF
## 会议录音 Pro ${VERSION}

- 支持系统：macOS 13.0+
- 架构：Apple Silicon (arm64)
- 构建号：${BUILD_VERSION}
- 功能：麦克风、系统声音、混合录音、定时录音、M4A/MP3 输出
- 权限：麦克风；选择系统声音时需屏幕与系统音频录制权限
- 隐私：录音仅保存在本地，不上传录音、不收集遥测；仅访问 GitHub Releases 检查更新
- SHA256: \`${SHA256}\`
- 第三方组件：PermissionFlow、Sparkle、LAME；LAME 3.100 完整源码包同时位于 DMG 和本 Release 的 \`lame-3.100.tar.gz\`
EOF

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    RELEASE_STATE="$(gh release view "$TAG" --repo "$REPO" --json isDraft,isPrerelease --jq '[.isDraft, .isPrerelease] | map(tostring) | join(" ")')"
    if [[ "$RELEASE_STATE" != "false false" ]]; then
        echo "已有 ${TAG} 是 draft 或 prerelease，不能作为 /releases/latest/ 的更新源；请先明确转为正式 Release。" >&2
        exit 1
    fi
    gh release upload "$TAG" "$DMG_PATH" "$APPCAST_PATH" "$LAME_SOURCE_ARCHIVE" --repo "$REPO" --clobber
    gh release edit "$TAG" --repo "$REPO" --title "会议录音 Pro ${VERSION}" --notes-file "$NOTES_PATH"
else
    gh release create "$TAG" "$DMG_PATH" "$APPCAST_PATH" "$LAME_SOURCE_ARCHIVE" \
        --repo "$REPO" \
        --verify-tag \
        --title "会议录音 Pro ${VERSION}" \
        --notes-file "$NOTES_PATH"
fi

echo "GitHub Release 已更新: https://github.com/${REPO}/releases/tag/${TAG}"
echo "Sparkle appcast: https://github.com/${REPO}/releases/latest/download/appcast.xml"
