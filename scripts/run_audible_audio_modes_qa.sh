#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
QA_DIR="${QA_AUDIBLE_RUN_DIR:-$ROOT_DIR/qa-runs/audible-mode-check-$RUN_ID}"
SOURCES_DIR="$QA_DIR/sources"
RECORDINGS_DIR="$QA_DIR/recordings"
RESULTS_DIR="$QA_DIR/results"
SCENARIO_PATH="$QA_DIR/scenario.json"
RESULT_PATH="$QA_DIR/qa-result.json"
REPORT_PATH="$QA_DIR/audible-report.md"
APP_PATH="$ROOT_DIR/build/QA/Release/SimpleRecorder.app"
APP_BIN="$APP_PATH/Contents/MacOS/SimpleRecorder"
RECORD_SECONDS="${QA_AUDIBLE_RECORD_SECONDS:-8}"
TIMEOUT_SECONDS="${QA_AUDIBLE_TIMEOUT_SECONDS:-120}"
USE_LARK_DEVICE="${QA_AUDIBLE_USE_LARK:-auto}"

source "$ROOT_DIR/scripts/qa_process_guard.sh"

mkdir -p "$SOURCES_DIR" "$RECORDINGS_DIR" "$RESULTS_DIR"

for tool in say ffmpeg afinfo python3 SwitchAudioSource; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "缺少依赖命令: $tool" >&2
    exit 2
  fi
done

json_positive_int() {
  local name="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[0-9]+$ || "$value" -eq 0 ]]; then
    echo "$name must be a positive integer." >&2
    exit 2
  fi

  echo "$value"
}

RECORD_SECONDS="$(json_positive_int QA_AUDIBLE_RECORD_SECONDS "$RECORD_SECONDS")"
TIMEOUT_SECONDS="$(json_positive_int QA_AUDIBLE_TIMEOUT_SECONDS "$TIMEOUT_SECONDS")"

echo "== Audible audio modes QA =="
echo "目录: $QA_DIR"

echo
echo "== Generate source audio =="
say -v Tingting -o "$SOURCES_DIR/system-source.aiff" \
  "系统声音测试。system source. 一二三四五。"
say -v Tingting -o "$SOURCES_DIR/microphone-source.aiff" \
  "麦克风测试。microphone source. 六七八九十。"

ffmpeg -hide_banner -loglevel error -y \
  -i "$SOURCES_DIR/system-source.aiff" \
  -af "loudnorm=I=-14:TP=-1.0:LRA=9" \
  -ar 48000 -ac 1 "$SOURCES_DIR/system-source.wav"
ffmpeg -hide_banner -loglevel error -y \
  -i "$SOURCES_DIR/microphone-source.aiff" \
  -af "loudnorm=I=-14:TP=-1.0:LRA=9" \
  -ar 48000 -ac 1 "$SOURCES_DIR/microphone-source.wav"

for source in "$SOURCES_DIR"/*.wav; do
  echo "-- $source"
  afinfo "$source" | sed -n '1,14p'
done

cat >"$SCENARIO_PATH" <<JSON
{
  "outputPath": "$RESULT_PATH",
  "recordingsPath": "$RECORDINGS_DIR",
  "recordSeconds": $RECORD_SECONDS,
  "audibleModeCheck": true,
  "includeSettings": false,
  "includeMP3": false,
  "includeSystemAudio": true,
  "includeMixedAudio": true,
  "includeTimer": false,
  "systemSourcePath": "$SOURCES_DIR/system-source.wav",
  "microphoneSourcePath": "$SOURCES_DIR/microphone-source.wav"
}
JSON

echo
echo "== Build package =="
./build_dmg.sh | tee "$QA_DIR/build.log"

echo
echo "== Build QA-only app =="
scripts/build_qa_app.sh | tee "$QA_DIR/qa-app-build.log"

echo
echo "== Audio route =="
ORIGINAL_INPUT="$(SwitchAudioSource -c -t input 2>/dev/null || true)"
ORIGINAL_OUTPUT="$(SwitchAudioSource -c -t output 2>/dev/null || true)"
ORIGINAL_SYSTEM="$(SwitchAudioSource -c -t system 2>/dev/null || true)"
ROUTE_NOTE="保持当前默认音频设备"

restore_audio_route() {
  if [[ -n "${ORIGINAL_INPUT:-}" ]]; then
    SwitchAudioSource -s "$ORIGINAL_INPUT" -t input >/dev/null 2>&1 || true
  fi
  if [[ -n "${ORIGINAL_OUTPUT:-}" ]]; then
    SwitchAudioSource -s "$ORIGINAL_OUTPUT" -t output >/dev/null 2>&1 || true
  fi
  if [[ -n "${ORIGINAL_SYSTEM:-}" ]]; then
    SwitchAudioSource -s "$ORIGINAL_SYSTEM" -t system >/dev/null 2>&1 || true
  fi
}
trap restore_audio_route EXIT

if SwitchAudioSource -a -t input | grep -Fxq "LarkAudioDevice" \
  && SwitchAudioSource -a -t output | grep -Fxq "LarkAudioDevice" \
  && [[ "$USE_LARK_DEVICE" != "false" ]]; then
  SwitchAudioSource -s LarkAudioDevice -t input >/dev/null
  SwitchAudioSource -s LarkAudioDevice -t output >/dev/null
  SwitchAudioSource -s LarkAudioDevice -t system >/dev/null || true
  ROUTE_NOTE="默认输入/输出临时切到 LarkAudioDevice，用虚拟设备把麦克风测试源送入默认输入"
fi

echo "原输入: ${ORIGINAL_INPUT:-unknown}"
echo "原输出: ${ORIGINAL_OUTPUT:-unknown}"
echo "原系统输出: ${ORIGINAL_SYSTEM:-unknown}"
echo "本轮路由: $ROUTE_NOTE"

echo
echo "== Run app automation =="
qa_prepare_for_run "$APP_BIN"

if [[ ! -x "$APP_BIN" ]]; then
  echo "App binary not found: $APP_BIN" >&2
  exit 1
fi

set +e
"$APP_BIN" --qa-scenario "$SCENARIO_PATH" >"$QA_DIR/app.stdout.log" 2>"$QA_DIR/app.stderr.log" &
APP_PID=$!
APP_EXIT=0
deadline=$((SECONDS + TIMEOUT_SECONDS))

while kill -0 "$APP_PID" >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    echo "可听音频 QA 超时，请求 App 优雅退出: $APP_PID" >&2
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

restore_audio_route
trap - EXIT

if [[ "$APP_EXIT" -ne 0 ]]; then
  echo "App 自动化进程异常退出: $APP_EXIT" >&2
  exit "$APP_EXIT"
fi

if [[ ! -f "$RESULT_PATH" ]]; then
  echo "缺少 QA 结果文件: $RESULT_PATH" >&2
  exit 1
fi

echo
echo "== Build listening report =="
QA_DIR="$QA_DIR" \
RESULT_PATH="$RESULT_PATH" \
REPORT_PATH="$REPORT_PATH" \
ROUTE_NOTE="$ROUTE_NOTE" \
ORIGINAL_INPUT="$ORIGINAL_INPUT" \
ORIGINAL_OUTPUT="$ORIGINAL_OUTPUT" \
ORIGINAL_SYSTEM="$ORIGINAL_SYSTEM" \
python3 <<'PY'
import json
import os
import pathlib
import shutil
import subprocess
import sys

qa_dir = pathlib.Path(os.environ["QA_DIR"])
result_path = pathlib.Path(os.environ["RESULT_PATH"])
report_path = pathlib.Path(os.environ["REPORT_PATH"])
results_dir = qa_dir / "results"
sources_dir = qa_dir / "sources"
data = json.loads(result_path.read_text(encoding="utf-8"))
steps = data.get("steps", [])

expected = {
    "audible-4.3-system-audio": ("01-system-audio", "直录系统声音"),
    "audible-4.1-microphone": ("02-microphone", "直录麦克风"),
    "audible-4.4-mixed-audio": ("03-mixed-audio", "系统 + 麦克风"),
}

step_by_name = {step.get("name"): step for step in steps}
missing = [name for name in expected if name not in step_by_name]
failed = [
    step for step in steps
    if step.get("name") in expected and step.get("status") != "passed"
]
if missing or failed:
    print(f"missing={missing}", file=sys.stderr)
    print(f"failed={[s.get('name') + ':' + s.get('status', '') for s in failed]}", file=sys.stderr)
    sys.exit(1)

def run(cmd):
    return subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def afinfo(path):
    result = run(["afinfo", str(path)])
    lines = (result.stdout + result.stderr).splitlines()
    keep = []
    for line in lines:
        if any(token in line for token in [
            "Data format:",
            "estimated duration:",
            "audio bytes:",
            "bit rate:",
        ]):
            keep.append(line.strip())
    return "<br>".join(keep)

def volumedetect(path):
    result = run([
        "ffmpeg",
        "-hide_banner",
        "-nostats",
        "-i",
        str(path),
        "-af",
        "volumedetect",
        "-f",
        "null",
        "-",
    ])
    lines = result.stderr.splitlines()
    keep = []
    for line in lines:
        if "mean_volume:" in line or "max_volume:" in line:
            keep.append(line.split("]")[-1].strip())
    return "; ".join(keep)

rows = []
for step_name, (prefix, label) in expected.items():
    step = step_by_name[step_name]
    recording = step.get("recordings", [])[0]
    source = pathlib.Path(recording["path"])
    raw = results_dir / f"{prefix}-raw{source.suffix}"
    listen = results_dir / f"{prefix}-listen.m4a"
    shutil.copy2(source, raw)
    normalize = run([
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(raw),
        "-af",
        "loudnorm=I=-16:TP=-1.5:LRA=11",
        "-ar",
        "48000",
        "-ac",
        "1",
        str(listen),
    ])
    if normalize.returncode != 0:
        print(normalize.stderr, file=sys.stderr)
        sys.exit(normalize.returncode)
    rows.append({
        "label": label,
        "step": step_name,
        "raw": raw,
        "listen": listen,
        "message": step.get("message", ""),
        "details": step.get("details", {}),
        "afinfo": afinfo(raw),
        "volume": volumedetect(raw),
    })

source_rows = [
    ("系统播放源", sources_dir / "system-source.wav", "系统声音测试。system source. 一二三四五。"),
    ("麦克风播放源", sources_dir / "microphone-source.wav", "麦克风测试。microphone source. 六七八九十。"),
]

lines = [
    "# 三种录音模式可听测试报告",
    "",
    f"- 运行目录: `{qa_dir}`",
    f"- App version: {data.get('appVersion', 'unknown')} ({data.get('buildVersion', 'unknown')})",
    f"- macOS: {data.get('macOS', 'unknown')}",
    f"- 音频路由: {os.environ.get('ROUTE_NOTE', '')}",
    f"- 原输入设备: {os.environ.get('ORIGINAL_INPUT', '')}",
    f"- 原输出设备: {os.environ.get('ORIGINAL_OUTPUT', '')}",
    f"- 原系统输出: {os.environ.get('ORIGINAL_SYSTEM', '')}",
    "",
    "## 源音频",
    "",
    "| 用途 | 文件 | 口播内容 |",
    "|---|---|---|",
]

for label, path, text in source_rows:
    lines.append(f"| {label} | `{path}` | {text} |")

lines.extend([
    "",
    "## 录音结果",
    "",
    "| 模式 | 原始录音 | 试听增益版 | 结果 | 元数据 | 音量统计 |",
    "|---|---|---|---|---|---|",
])

for row in rows:
    lines.append(
        "| {label} | `{raw}` | `{listen}` | {message} | {afinfo} | {volume} |".format(
            **row
        )
    )

lines.extend([
    "",
    "## 说明",
    "",
    "- 原始录音是 App 真实输出文件的复制件。",
    "- 试听增益版只用于方便辨认口播内容，不作为原始测试证据。",
    "- 麦克风测试通过默认输入设备录制；本机使用虚拟设备时，会在上方音频路由中记录。",
])

report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(report_path)
PY

echo "报告: $REPORT_PATH"
echo "源音频: $SOURCES_DIR"
echo "结果音频: $RESULTS_DIR"
