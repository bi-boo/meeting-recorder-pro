#!/usr/bin/env bash

# Shared process-safety helpers for QA scripts. This file is sourced by other scripts.

QA_PROCESS_NAME="SimpleRecorder"
QA_BUNDLE_ID="com.meetingrecorderpro.app"

qa_process_executable() {
  local pid="$1"
  /usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null \
    | sed -n 's/^n//p' \
    | head -n 1
}

qa_running_pids() {
  pgrep -x "$QA_PROCESS_NAME" 2>/dev/null || true
}

qa_recording_flag_is_set() {
  local value
  value="$(defaults read "$QA_BUNDLE_ID" recording_in_progress 2>/dev/null || true)"
  case "$value" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

qa_wait_for_exit() {
  local pid="$1"
  local timeout_seconds="${2:-10}"
  local deadline=$((SECONDS + timeout_seconds))
  while kill -0 "$pid" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      return 1
    fi
    sleep 0.25
  done
}

qa_gracefully_quit_pid() {
  local pid="$1"
  local expected_bin="$2"
  local actual_bin
  actual_bin="$(qa_process_executable "$pid")"

  if [[ -z "$actual_bin" || "$actual_bin" != "$expected_bin" ]]; then
    echo "Refusing to stop PID $pid: expected $expected_bin, found ${actual_bin:-unknown}." >&2
    return 1
  fi
  if qa_recording_flag_is_set; then
    echo "Refusing to stop PID $pid because recording_in_progress is set." >&2
    return 1
  fi

  # NSRunningApplication 按已复核的 PID 请求正常退出，避免同 bundle ID 新进程在检查后启动时被误退出。
  osascript -l JavaScript -e "ObjC.import('AppKit'); const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier($pid); if (app.js) { app.terminate; }" >/dev/null 2>&1 || true
  if ! qa_wait_for_exit "$pid" 10; then
    echo "PID $pid did not exit after a graceful quit request; no force-kill was attempted." >&2
    return 1
  fi
}

qa_prepare_for_run() {
  local expected_bin="$1"
  local pid actual_bin
  local -a matching_pids=()

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    actual_bin="$(qa_process_executable "$pid")"
    if [[ "$actual_bin" != "$expected_bin" ]]; then
      echo "Another SimpleRecorder instance is running: PID $pid (${actual_bin:-unknown})." >&2
      echo "QA will not stop an installed or unrelated app. End any real recording and quit that app manually." >&2
      return 1
    fi
    matching_pids+=("$pid")
  done < <(qa_running_pids)

  for pid in "${matching_pids[@]}"; do
    qa_gracefully_quit_pid "$pid" "$expected_bin" || return 1
  done
}
