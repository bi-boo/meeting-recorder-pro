#!/usr/bin/env bash

set -euo pipefail

DMG_PATH=""
APP_PATH="build/Release/SimpleRecorder.app"
RECORDINGS_DIR=""
LOG_FILE="$HOME/Library/Application Support/com.meetingrecorderpro.app/Logs/MeetingRecorderPro_$(date +%Y-%m-%d).log"
MINIMUM_AUDIO_DURATION_SECONDS="${QA_MINIMUM_AUDIO_DURATION_SECONDS:-1.0}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/qa_artifact_check.sh --dmg MeetingRecorderPro_YYYYMMDD.dmg [--app build/Release/SimpleRecorder.app] [--recordings /path/to/test-recordings] [--log-file /path/to/log]

Checks:
  - DMG checksum and hdiutil verification
  - .app and DMG code signature
  - Gatekeeper assessment, reported but not treated as fatal when unnotarized
  - recording files must decode, meet minimum duration, and contain non-silent audio
  - recent log warnings/errors relevant to recording
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg)
      DMG_PATH="${2:-}"
      shift 2
      ;;
    --app)
      APP_PATH="${2:-}"
      shift 2
      ;;
    --recordings)
      RECORDINGS_DIR="${2:-}"
      shift 2
      ;;
    --log-file)
      LOG_FILE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$DMG_PATH" ]]; then
  echo "Missing required --dmg argument." >&2
  usage
  exit 2
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

for tool in afinfo afconvert python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required command: $tool" >&2
    exit 2
  fi
done

echo "== Package =="
ls -lh "$DMG_PATH"
shasum -a 256 "$DMG_PATH"

echo
echo "== hdiutil verify =="
hdiutil verify "$DMG_PATH"

echo
echo "== codesign app =="
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo
echo "== codesign dmg =="
codesign --verify --verbose=2 "$DMG_PATH"

echo
echo "== Gatekeeper assessment =="
if spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"; then
  echo "Gatekeeper: accepted"
else
  status=$?
  echo "Gatekeeper: not accepted, usually because the DMG is not notarized yet. exit=$status"
fi

if [[ -n "$RECORDINGS_DIR" ]]; then
  if [[ ! -d "$RECORDINGS_DIR" ]]; then
    echo "Recordings dir not found: $RECORDINGS_DIR" >&2
    exit 1
  fi

  echo
  echo "== Recording validation =="
  found=0
  invalid=0
  while IFS= read -r -d '' file; do
    found=1
    echo "-- $file"
    if ! scripts/verify_audio_file.py \
      --minimum-duration "$MINIMUM_AUDIO_DURATION_SECONDS" \
      "$file"; then
      invalid=$((invalid + 1))
    fi
  done < <(find "$RECORDINGS_DIR" -maxdepth 1 -type f \( -name '*.m4a' -o -name '*.mp3' \) -print0 | sort -z)

  if [[ "$found" -eq 0 ]]; then
    echo "No .m4a or .mp3 files found in $RECORDINGS_DIR" >&2
    exit 1
  fi
  if [[ "$invalid" -gt 0 ]]; then
    echo "$invalid recording file(s) failed decode/duration/non-silence validation." >&2
    exit 1
  fi
fi

if [[ -f "$LOG_FILE" ]]; then
  echo
  echo "== Recent recording log lines =="
  tail -n 240 "$LOG_FILE" | rg 'ERROR|CRITICAL|启动失败|写入失败|录音中断|录音已保存|丢帧|SCStream|系统音频|权限' || true
else
  echo
  echo "Log file not found: $LOG_FILE"
fi

echo
echo "QA artifact check completed."
