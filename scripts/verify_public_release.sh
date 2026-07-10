#!/usr/bin/env bash

set -euo pipefail

APP_PATH="${1:-build/Release/SimpleRecorder.app}"
APP_BIN="$APP_PATH/Contents/MacOS/SimpleRecorder"

if [[ ! -x "$APP_BIN" ]]; then
  echo "App binary not found: $APP_BIN" >&2
  exit 1
fi

if nm -j "$APP_BIN" | xcrun swift-demangle | rg 'QAAutomationRunner' >/dev/null; then
  echo "Public Release contains QAAutomationRunner symbols." >&2
  exit 1
fi

if strings -a "$APP_BIN" | rg -- '--qa-scenario' >/dev/null; then
  echo "Public Release contains the --qa-scenario command-line entry." >&2
  exit 1
fi

echo "Public Release contains no QA automation entry points: $APP_BIN"
