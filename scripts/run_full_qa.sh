#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
QA_DIR="${QA_RUN_DIR:-$ROOT_DIR/qa-runs/$RUN_ID}"
RECORDINGS_DIR="$QA_DIR/recordings"
SCENARIO_PATH="$QA_DIR/scenario.json"
RESULT_PATH="$QA_DIR/qa-result.json"
REPORT_PATH="$QA_DIR/report.md"
APP_PATH="$ROOT_DIR/build/Release/SimpleRecorder.app"
APP_BIN="$APP_PATH/Contents/MacOS/SimpleRecorder"
LOG_FILE="$HOME/Library/Application Support/Logs/MeetingRecorderPro_$(date +%Y-%m-%d).log"

RECORD_SECONDS="${QA_RECORD_SECONDS:-4}"
PAUSE_SECONDS="${QA_PAUSE_SECONDS:-1}"
INCLUDE_MP3="${QA_INCLUDE_MP3:-true}"
INCLUDE_SYSTEM_AUDIO="${QA_INCLUDE_SYSTEM_AUDIO:-true}"
INCLUDE_MIXED_AUDIO="${QA_INCLUDE_MIXED_AUDIO:-true}"
INCLUDE_TIMER="${QA_INCLUDE_TIMER:-true}"
QA_TIMEOUT_SECONDS="${QA_TIMEOUT_SECONDS:-180}"

mkdir -p "$RECORDINGS_DIR"

cat > "$SCENARIO_PATH" <<JSON
{
  "outputPath": "$RESULT_PATH",
  "recordingsPath": "$RECORDINGS_DIR",
  "recordSeconds": $RECORD_SECONDS,
  "pauseSeconds": $PAUSE_SECONDS,
  "includeSettings": true,
  "includeMP3": $INCLUDE_MP3,
  "includeSystemAudio": $INCLUDE_SYSTEM_AUDIO,
  "includeMixedAudio": $INCLUDE_MIXED_AUDIO,
  "includeTimer": $INCLUDE_TIMER
}
JSON

echo "== QA run =="
echo "目录: $QA_DIR"
echo "场景: $SCENARIO_PATH"

echo
echo "== Build package =="
./build_dmg.sh | tee "$QA_DIR/build.log"

DMG_PATH="$(find "$ROOT_DIR" -maxdepth 1 -type f -name 'MeetingRecorderPro_*.dmg' -print | sort | tail -n 1)"
if [[ -z "$DMG_PATH" ]]; then
  echo "未找到 MeetingRecorderPro_*.dmg" >&2
  exit 1
fi

echo
echo "== Stop existing app =="
pkill -x SimpleRecorder >/dev/null 2>&1 || true
sleep 1

if [[ ! -x "$APP_BIN" ]]; then
  echo "App binary not found: $APP_BIN" >&2
  exit 1
fi

echo
echo "== Run app automation =="
set +e
"$APP_BIN" --qa-scenario "$SCENARIO_PATH" >"$QA_DIR/app.stdout.log" 2>"$QA_DIR/app.stderr.log" &
APP_PID=$!
APP_EXIT=0
deadline=$((SECONDS + QA_TIMEOUT_SECONDS))

while kill -0 "$APP_PID" >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    echo "QA 自动化超时，终止进程: $APP_PID" >&2
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
    APP_EXIT=124
    break
  fi
  sleep 1
done

if [[ "$APP_EXIT" -eq 0 ]]; then
  wait "$APP_PID"
  APP_EXIT=$?
fi
set -e

if [[ "$APP_EXIT" -ne 0 ]]; then
  echo "App 自动化进程异常退出: $APP_EXIT" >&2
fi

if [[ ! -f "$RESULT_PATH" ]]; then
  echo "缺少 QA 结果文件: $RESULT_PATH" >&2
  exit 1
fi

echo
echo "== QA result =="
set +e
/usr/bin/python3 - "$RESULT_PATH" "$REPORT_PATH" "$DMG_PATH" <<'PY'
import hashlib
import json
import pathlib
import platform
import subprocess
import sys

result_path = pathlib.Path(sys.argv[1])
report_path = pathlib.Path(sys.argv[2])
dmg_path = pathlib.Path(sys.argv[3])

data = json.loads(result_path.read_text())
summary = data.get("summary", {})
steps = data.get("steps", [])

try:
    commit = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], text=True).strip()
except Exception:
    commit = "unknown"

sha256 = hashlib.sha256(dmg_path.read_bytes()).hexdigest()

lines = [
    "# 会议录音 Pro QA 自动化记录",
    "",
    f"- Git commit: {commit}",
    f"- App version: {data.get('appVersion', 'unknown')} ({data.get('buildVersion', 'unknown')})",
    f"- macOS: {data.get('macOS', platform.platform())}",
    f"- DMG: {dmg_path}",
    f"- SHA256: {sha256}",
    f"- 录音目录: {data.get('recordingsPath', '')}",
    f"- 结果: passed={summary.get('passed', 0)}, failed={summary.get('failed', 0)}, skipped={summary.get('skipped', 0)}, total={summary.get('total', len(steps))}",
    "",
    "| 场景 | 结果 | 说明 | 录音文件 |",
    "|---|---|---|---|",
]

for step in steps:
    recordings = "<br>".join(
        f"{pathlib.Path(item.get('path', '')).name} ({item.get('bytes', 0)} bytes)"
        for item in step.get("recordings", [])
    )
    message = (step.get("message") or "").replace("|", "\\|")
    lines.append(
        f"| {step.get('name', '')} | {step.get('status', '')} | {message} | {recordings} |"
    )

report_path.write_text("\n".join(lines) + "\n")
print(report_path)

sys.exit(1 if int(summary.get("failed", 0)) > 0 else 0)
PY
RESULT_EXIT=$?
set -e

echo
echo "== Artifact check =="
set +e
scripts/qa_artifact_check.sh \
  --dmg "$DMG_PATH" \
  --app "$APP_PATH" \
  --recordings "$RECORDINGS_DIR" \
  --log-file "$LOG_FILE" | tee "$QA_DIR/artifact-check.log"
ARTIFACT_EXIT="${PIPESTATUS[0]}"
set -e

echo
echo "== QA files =="
echo "JSON: $RESULT_PATH"
echo "报告: $REPORT_PATH"
echo "构建日志: $QA_DIR/build.log"
echo "应用 stdout: $QA_DIR/app.stdout.log"
echo "应用 stderr: $QA_DIR/app.stderr.log"
echo "包校验日志: $QA_DIR/artifact-check.log"

if [[ "$APP_EXIT" -ne 0 || "$RESULT_EXIT" -ne 0 || "$ARTIFACT_EXIT" -ne 0 ]]; then
  echo "QA 未完全通过: app=$APP_EXIT result=$RESULT_EXIT artifact=$ARTIFACT_EXIT" >&2
  exit 1
fi

echo
echo "QA 自动化通过。"
