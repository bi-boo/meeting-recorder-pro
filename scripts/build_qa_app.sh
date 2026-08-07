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

QA_SIGNING_IDENTITY="${QA_CODE_SIGN_IDENTITY:-}"
if [[ -z "$QA_SIGNING_IDENTITY" ]]; then
  QA_SIGNING_IDENTITY="$(
    security find-identity -p codesigning -v \
      | awk '/Developer ID Application/ && !found {print $2; found=1}'
  )"
fi

if [[ -n "$QA_SIGNING_IDENTITY" ]]; then
  xattr -cr "$APP_PATH"

  component_sign_args=(
    --force
    --strict
    --options runtime
    --preserve-metadata=identifier,entitlements
    --sign "$QA_SIGNING_IDENTITY"
  )
  app_sign_args=(
    --force
    --strict
    --options runtime
    --entitlements "$ROOT_DIR/SimpleRecorder/SimpleRecorder.entitlements"
    --sign "$QA_SIGNING_IDENTITY"
  )

  sparkle_framework="$APP_PATH/Contents/Frameworks/Sparkle.framework"
  if [[ -d "$sparkle_framework" ]]; then
    for component in \
      "$sparkle_framework/Versions/Current/XPCServices/Downloader.xpc" \
      "$sparkle_framework/Versions/Current/XPCServices/Installer.xpc" \
      "$sparkle_framework/Versions/Current/Updater.app" \
      "$sparkle_framework/Versions/Current/Autoupdate" \
      "$sparkle_framework"; do
      if [[ -e "$component" ]]; then
        codesign "${component_sign_args[@]}" "$component"
      fi
    done
  fi

  codesign "${app_sign_args[@]}" "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  echo "QA App signed for local permission reuse: $QA_SIGNING_IDENTITY"
else
  echo "Developer ID Application identity not found; QA App remains unsigned."
fi

if ! nm -j "$APP_BIN" | xcrun swift-demangle | grep -F 'QAAutomationRunner' >/dev/null; then
  echo "QA build does not contain QAAutomationRunner; check QA_AUTOMATION configuration." >&2
  exit 1
fi

echo "$APP_PATH"
