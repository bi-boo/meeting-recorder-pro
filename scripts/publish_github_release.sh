#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${GITHUB_REPOSITORY:-bi-boo/meeting-recorder-pro}"
DMG_PATH="${1:-}"

if [ -z "${DMG_PATH}" ]; then
    DMG_PATH="$(find "${ROOT_DIR}" -maxdepth 1 -type f -name 'MeetingRecorderPro_*.dmg' -print | sort | tail -n 1)"
fi

if [ -z "${DMG_PATH}" ] || [ ! -f "${DMG_PATH}" ]; then
    echo "未找到 DMG。用法: scripts/publish_github_release.sh /path/to/MeetingRecorderPro_YYYYMMDD.dmg" >&2
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "缺少 GitHub CLI: gh。请先安装并执行 gh auth login。" >&2
    exit 1
fi

cd "${ROOT_DIR}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Release/SimpleRecorder.app/Contents/Info.plist)"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/Release/SimpleRecorder.app/Contents/Info.plist)"
TAG="${RELEASE_TAG:-v${VERSION}}"
APPCAST_PATH="${ROOT_DIR}/build/appcast.xml"
NOTES_PATH="${ROOT_DIR}/build/release-notes-${TAG}.md"

scripts/generate_appcast.py \
    --dmg "${DMG_PATH}" \
    --app "${ROOT_DIR}/build/Release/SimpleRecorder.app" \
    --repo "${REPO}" \
    --tag "${TAG}" \
    --output "${APPCAST_PATH}"

SHA256="$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"
cat > "${NOTES_PATH}" <<EOF
## 会议录音 Pro ${VERSION}

- 支持系统：macOS 13.0+
- 架构：Apple Silicon (arm64)
- 构建号：${BUILD_VERSION}
- SHA256: \`${SHA256}\`
EOF

if gh release view "${TAG}" --repo "${REPO}" >/dev/null 2>&1; then
    gh release upload "${TAG}" "${DMG_PATH}" "${APPCAST_PATH}" --repo "${REPO}" --clobber
    gh release edit "${TAG}" --repo "${REPO}" --title "会议录音 Pro ${VERSION}" --notes-file "${NOTES_PATH}"
else
    gh release create "${TAG}" "${DMG_PATH}" "${APPCAST_PATH}" \
        --repo "${REPO}" \
        --title "会议录音 Pro ${VERSION}" \
        --notes-file "${NOTES_PATH}"
fi

echo "GitHub Release 已更新: https://github.com/${REPO}/releases/tag/${TAG}"
echo "Sparkle appcast: https://github.com/${REPO}/releases/latest/download/appcast.xml"
