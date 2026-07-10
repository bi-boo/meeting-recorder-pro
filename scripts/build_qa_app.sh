#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
QA_BUILD_ROOT="${QA_BUILD_ROOT:-$ROOT_DIR/build/QA}"
APP_PATH="$QA_BUILD_ROOT/Release/SimpleRecorder.app"
APP_BIN="$APP_PATH/Contents/MacOS/SimpleRecorder"

cd "$ROOT_DIR"

xcodebuild \
  -project SimpleRecorder.xcodeproj \
  -scheme SimpleRecorder \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$QA_BUILD_ROOT/DerivedData" \
  -packageAuthorizationProvider netrc \
  SYMROOT="$QA_BUILD_ROOT" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=QA_AUTOMATION \
  build

if [[ ! -x "$APP_BIN" ]]; then
  echo "QA App binary not found: $APP_BIN" >&2
  exit 1
fi

if ! nm -j "$APP_BIN" | xcrun swift-demangle | rg 'QAAutomationRunner' >/dev/null; then
  echo "QA build does not contain QAAutomationRunner; check QA_AUTOMATION configuration." >&2
  exit 1
fi

echo "$APP_PATH"
