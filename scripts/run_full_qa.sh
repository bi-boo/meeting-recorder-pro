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
EVIDENCE_PATH="${QA_EVIDENCE_PATH:-$QA_DIR/release-evidence.json}"
PUBLIC_APP_PATH="$ROOT_DIR/build/Release/SimpleRecorder.app"
APP_PATH="$ROOT_DIR/build/QA/Release/SimpleRecorder.app"
APP_BIN="$APP_PATH/Contents/MacOS/SimpleRecorder"
LOG_FILE="$HOME/Library/Application Support/com.meetingrecorderpro.app/Logs/MeetingRecorderPro_$(date +%Y-%m-%d).log"

RECORD_SECONDS="${QA_RECORD_SECONDS:-4}"
PAUSE_SECONDS="${QA_PAUSE_SECONDS:-1}"
INCLUDE_MP3="${QA_INCLUDE_MP3:-true}"
INCLUDE_SYSTEM_AUDIO="${QA_INCLUDE_SYSTEM_AUDIO:-true}"
INCLUDE_MIXED_AUDIO="${QA_INCLUDE_MIXED_AUDIO:-true}"
INCLUDE_TIMER="${QA_INCLUDE_TIMER:-true}"
ALLOW_SKIPS="${QA_ALLOW_SKIPS:-false}"
QA_TIMEOUT_SECONDS="${QA_TIMEOUT_SECONDS:-180}"
SKIP_RELEASE_BUILD="${QA_SKIP_BUILD:-false}"

source "$ROOT_DIR/scripts/qa_process_guard.sh"

json_bool() {
  local name="$1"
  local value
  value="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    true|1|yes|y) echo "true" ;;
    false|0|no|n) echo "false" ;;
    *)
      echo "$name must be a boolean: true/false/1/0/yes/no" >&2
      exit 2
      ;;
  esac
}

json_positive_int() {
  local name="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "$name must be a positive integer." >&2
    exit 2
  fi

  if [[ "$value" -eq 0 ]]; then
    echo "$name must be a positive integer." >&2
    exit 2
  fi

  echo "$value"
}

RECORD_SECONDS_JSON="$(json_positive_int QA_RECORD_SECONDS "$RECORD_SECONDS")"
PAUSE_SECONDS_JSON="$(json_positive_int QA_PAUSE_SECONDS "$PAUSE_SECONDS")"
INCLUDE_MP3_JSON="$(json_bool QA_INCLUDE_MP3 "$INCLUDE_MP3")"
INCLUDE_SYSTEM_AUDIO_JSON="$(json_bool QA_INCLUDE_SYSTEM_AUDIO "$INCLUDE_SYSTEM_AUDIO")"
INCLUDE_MIXED_AUDIO_JSON="$(json_bool QA_INCLUDE_MIXED_AUDIO "$INCLUDE_MIXED_AUDIO")"
INCLUDE_TIMER_JSON="$(json_bool QA_INCLUDE_TIMER "$INCLUDE_TIMER")"
ALLOW_SKIPS_JSON="$(json_bool QA_ALLOW_SKIPS "$ALLOW_SKIPS")"
SKIP_RELEASE_BUILD_JSON="$(json_bool QA_SKIP_BUILD "$SKIP_RELEASE_BUILD")"
QA_TIMEOUT_SECONDS="$(json_positive_int QA_TIMEOUT_SECONDS "$QA_TIMEOUT_SECONDS")"

mkdir -p "$RECORDINGS_DIR"

QA_SCENARIO_PATH="$SCENARIO_PATH" \
QA_RESULT_PATH="$RESULT_PATH" \
QA_RECORDINGS_PATH="$RECORDINGS_DIR" \
QA_RECORD_SECONDS_JSON="$RECORD_SECONDS_JSON" \
QA_PAUSE_SECONDS_JSON="$PAUSE_SECONDS_JSON" \
QA_INCLUDE_MP3_JSON="$INCLUDE_MP3_JSON" \
QA_INCLUDE_SYSTEM_AUDIO_JSON="$INCLUDE_SYSTEM_AUDIO_JSON" \
QA_INCLUDE_MIXED_AUDIO_JSON="$INCLUDE_MIXED_AUDIO_JSON" \
QA_INCLUDE_TIMER_JSON="$INCLUDE_TIMER_JSON" \
/usr/bin/python3 <<'PY'
import json
import os
import pathlib

def bool_env(name):
    return os.environ[name] == "true"

scenario = {
    "outputPath": os.environ["QA_RESULT_PATH"],
    "recordingsPath": os.environ["QA_RECORDINGS_PATH"],
    "recordSeconds": int(os.environ["QA_RECORD_SECONDS_JSON"]),
    "pauseSeconds": int(os.environ["QA_PAUSE_SECONDS_JSON"]),
    "includeSettings": True,
    "includeMP3": bool_env("QA_INCLUDE_MP3_JSON"),
    "includeSystemAudio": bool_env("QA_INCLUDE_SYSTEM_AUDIO_JSON"),
    "includeMixedAudio": bool_env("QA_INCLUDE_MIXED_AUDIO_JSON"),
    "includeTimer": bool_env("QA_INCLUDE_TIMER_JSON"),
}

pathlib.Path(os.environ["QA_SCENARIO_PATH"]).write_text(
    json.dumps(scenario, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY

echo "== QA run =="
echo "目录: $QA_DIR"
echo "场景: $SCENARIO_PATH"

echo
echo "== Build package =="
if [[ "$SKIP_RELEASE_BUILD_JSON" == "true" ]]; then
  if [[ ! -d "$PUBLIC_APP_PATH" ]]; then
    echo "QA_SKIP_BUILD=true 但公开 Release App 不存在: $PUBLIC_APP_PATH" >&2
    exit 1
  fi
  printf '使用已有公开 Release App: %s\n' "$PUBLIC_APP_PATH" | tee "$QA_DIR/build.log"
else
  ./build_dmg.sh | tee "$QA_DIR/build.log"
fi

echo
echo "== Build QA-only app =="
scripts/build_qa_app.sh | tee "$QA_DIR/qa-app-build.log"

if [[ "$SKIP_RELEASE_BUILD_JSON" == "true" ]]; then
  DMG_PATH="${QA_DMG_PATH:-}"
else
  DMG_PATH="$(find "$ROOT_DIR" -maxdepth 1 -type f -name 'MeetingRecorderPro_*.dmg' -print | sort | tail -n 1)"
fi
if [[ -z "$DMG_PATH" ]]; then
  echo "未找到 DMG；QA_SKIP_BUILD=true 时必须显式设置 QA_DMG_PATH。" >&2
  exit 1
fi
if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG 不存在: $DMG_PATH" >&2
  exit 1
fi
DMG_PATH="$(cd "$(dirname "$DMG_PATH")" && pwd)/$(basename "$DMG_PATH")"

echo
echo "== Check existing app =="
qa_prepare_for_run "$APP_BIN"

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
    echo "QA 自动化超时，请求 App 优雅退出: $APP_PID" >&2
    if qa_gracefully_quit_pid "$APP_PID" "$APP_BIN"; then
      wait "$APP_PID" >/dev/null 2>&1 || true
    else
      echo "QA App 仍在运行，为避免丢失录音，脚本未强制终止它。" >&2
    fi
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
scripts/validate_qa_result.py \
  --result "$RESULT_PATH" \
  --recordings "$RECORDINGS_DIR" \
  --app-info-plist "$PUBLIC_APP_PATH/Contents/Info.plist" \
  --expect-mp3 "$INCLUDE_MP3_JSON" \
  --expect-system-audio "$INCLUDE_SYSTEM_AUDIO_JSON" \
  --expect-mixed-audio "$INCLUDE_MIXED_AUDIO_JSON" \
  --expect-timer "$INCLUDE_TIMER_JSON" \
  --allow-skips "$ALLOW_SKIPS_JSON"
RESULT_EXIT=$?
set -e

QA_ALLOW_SKIPS_JSON="$ALLOW_SKIPS_JSON" \
/usr/bin/python3 - "$RESULT_PATH" "$REPORT_PATH" "$DMG_PATH" <<'PY'
import hashlib
import json
import os
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
allow_skips = os.environ.get("QA_ALLOW_SKIPS_JSON") == "true"
skipped_required = [
    step for step in steps
    if step.get("name") != "manual-remainder" and step.get("status") == "skipped"
]

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
    f"- 核心场景 skipped 策略: {'允许' if allow_skips else '失败'}",
    "",
    "| 场景 | 结果 | 说明 | 录音文件 |",
    "|---|---|---|---|",
]

for step in steps:
    recordings = "<br>".join(
        (
            f"{pathlib.Path(item.get('path', '')).name} "
            f"({item.get('bytes', 0)} bytes, "
            f"duration={item.get('durationSeconds', 'unknown')}, "
            f"peak={item.get('peakAmplitude', 'unknown')}, "
            f"rms={item.get('rmsAmplitude', 'unknown')}, "
            f"error={item.get('validationError') or 'none'})"
        )
        for item in step.get("recordings", [])
    )
    message = (step.get("message") or "").replace("|", "\\|")
    lines.append(
        f"| {step.get('name', '')} | {step.get('status', '')} | {message} | {recordings} |"
    )

if skipped_required and not allow_skips:
    lines.extend([
        "",
        "## 未通过原因",
        "",
        "以下核心场景被跳过，默认视为 QA 未通过：",
    ])
    for step in skipped_required:
        lines.append(f"- {step.get('name')}: {step.get('message', '')}")

report_path.write_text("\n".join(lines) + "\n")
print(report_path)
PY

echo
echo "== Artifact check =="
set +e
scripts/qa_artifact_check.sh \
  --dmg "$DMG_PATH" \
  --app "$PUBLIC_APP_PATH" \
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

if [[ "$ALLOW_SKIPS_JSON" == "false" ]]; then
  QA_RESULT_PATH="$RESULT_PATH" \
  QA_EVIDENCE_PATH="$EVIDENCE_PATH" \
  QA_DMG_PATH="$DMG_PATH" \
  QA_ALLOW_SKIPS_JSON="$ALLOW_SKIPS_JSON" \
  /usr/bin/python3 <<'PY'
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import subprocess

result_path = pathlib.Path(os.environ["QA_RESULT_PATH"]).resolve()
evidence_path = pathlib.Path(os.environ["QA_EVIDENCE_PATH"]).resolve()
dmg_path = pathlib.Path(os.environ["QA_DMG_PATH"]).resolve()
app_info_path = pathlib.Path("build/Release/SimpleRecorder.app/Contents/Info.plist")

result = json.loads(result_path.read_text(encoding="utf-8"))
with app_info_path.open("rb") as handle:
    info = plistlib.load(handle)

evidence = {
    "schemaVersion": 1,
    "status": "passed",
    "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "gitCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "appVersion": str(info["CFBundleShortVersionString"]),
    "buildVersion": str(info["CFBundleVersion"]),
    "dmgFileName": dmg_path.name,
    "dmgSHA256": hashlib.sha256(dmg_path.read_bytes()).hexdigest(),
    "qaResultPath": str(result_path),
    "qaResultSHA256": hashlib.sha256(result_path.read_bytes()).hexdigest(),
    "allowSkips": os.environ["QA_ALLOW_SKIPS_JSON"] == "true",
    "summary": result["summary"],
}
evidence_path.parent.mkdir(parents=True, exist_ok=True)
evidence_path.write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"发布 QA 证据: {evidence_path}")
PY
else
  echo "QA_ALLOW_SKIPS=true：本轮仅作为本机烟测，不生成发布证据。"
fi

echo
echo "QA 自动化通过。"
