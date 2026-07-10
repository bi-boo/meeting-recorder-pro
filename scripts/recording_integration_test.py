#!/usr/bin/env python3
"""
End-to-end smoke tests for SimpleRecorder's hardest audio paths.

What this script checks:
- microphone-only, system-audio-only, and mixed recording modes
- a second recording after stop/restart
- output-device switching while recording system audio
- input-device switching while recording microphone audio, followed by a restart

The script drives the installed app through the global recording hotkey, then
uses ffprobe/ffmpeg to verify that the generated files have duration and
non-silent audio. It snapshots UserDefaults before changing app settings and
restores them at the end.
"""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import plistlib
import re
import shutil
import socket
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_APP_PATH = Path("/Applications/会议录音 Pro.app")
DEFAULT_BUNDLE_ID = "com.meetingrecorderpro.app"
PROCESS_NAME = "SimpleRecorder"
MODES = ("microphone", "system_audio", "both")
RECORD_EXTENSIONS = (".m4a", ".mp3", ".wav", ".caf", ".aiff")


@dataclass
class Device:
    name: str
    unique_id: str | None = None
    source: str = ""


@dataclass
class Segment:
    name: str
    start: float
    duration: float
    threshold_db: float
    required: bool = True


@dataclass
class VolumeStats:
    mean_db: float | None = None
    max_db: float | None = None
    raw: str = ""


@dataclass
class CaseResult:
    name: str
    status: str
    mode: str | None = None
    file: str | None = None
    duration: float | None = None
    full_volume: dict | None = None
    segment_volumes: dict[str, dict] = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    def fail(self, message: str) -> None:
        self.status = "failed"
        self.errors.append(message)

    def note(self, message: str) -> None:
        self.notes.append(message)


class CommandError(RuntimeError):
    def __init__(self, cmd: list[str], returncode: int, stdout: str, stderr: str):
        self.cmd = cmd
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        joined = " ".join(cmd)
        super().__init__(f"{joined} exited {returncode}: {stderr.strip() or stdout.strip()}")


def run(
    cmd: list[str],
    *,
    check: bool = True,
    timeout: float | None = None,
    text: bool = True,
    capture: bool = True,
) -> subprocess.CompletedProcess:
    kwargs = {
        "check": False,
        "timeout": timeout,
        "text": text,
    }
    if capture:
        kwargs["stdout"] = subprocess.PIPE
        kwargs["stderr"] = subprocess.PIPE
    proc = subprocess.run(cmd, **kwargs)
    if check and proc.returncode != 0:
        stdout = proc.stdout if isinstance(proc.stdout, str) else ""
        stderr = proc.stderr if isinstance(proc.stderr, str) else ""
        raise CommandError(cmd, proc.returncode, stdout, stderr)
    return proc


def command_path(name: str) -> str | None:
    return shutil.which(name)


def print_step(message: str) -> None:
    print(f"\n==> {message}", flush=True)


def defaults_read(domain: str, key: str) -> str | None:
    proc = run(["defaults", "read", domain, key], check=False)
    if proc.returncode != 0:
        return None
    return proc.stdout.strip()


def defaults_write_string(domain: str, key: str, value: str) -> None:
    run(["defaults", "write", domain, key, "-string", value])


def defaults_write_bool(domain: str, key: str, value: bool) -> None:
    run(["defaults", "write", domain, key, "-bool", "true" if value else "false"])


def defaults_delete(domain: str, key: str) -> None:
    run(["defaults", "delete", domain, key], check=False)


def defaults_synchronize(domain: str) -> None:
    run(["defaults", "synchronize", domain], check=False)


def preference_plist_paths(domain: str) -> list[Path]:
    home = Path.home()
    return [
        home / "Library" / "Preferences" / f"{domain}.plist",
        home
        / "Library"
        / "Containers"
        / domain
        / "Data"
        / "Library"
        / "Preferences"
        / f"{domain}.plist",
    ]


def read_plist(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        with path.open("rb") as handle:
            data = plistlib.load(handle)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def app_release_metadata(app_path: Path) -> dict[str, str]:
    info = read_plist(app_path / "Contents" / "Info.plist")
    executable = expected_app_binary(app_path)
    digest = hashlib.sha256(executable.read_bytes()).hexdigest()
    commit = run(
        ["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"],
        check=False,
    ).stdout.strip()
    if not commit:
        commit = "unknown"
    return {
        "gitCommit": commit,
        "appVersion": str(info.get("CFBundleShortVersionString", "unknown")),
        "buildVersion": str(info.get("CFBundleVersion", "unknown")),
        "appExecutableSHA256": digest,
    }


def write_plist(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        plistlib.dump(data, handle, fmt=plistlib.FMT_BINARY)


def kill_cfprefsd() -> None:
    run(["killall", "cfprefsd"], check=False)
    time.sleep(0.2)


def update_preference_files(
    domain: str,
    values: dict,
    *,
    delete_keys: Iterable[str] = (),
) -> None:
    # The app has existed both sandboxed and unsandboxed, so machines can have
    # two preference stores. Write both while the app is closed to avoid tests
    # accidentally running against stale settings.
    kill_cfprefsd()
    for path in preference_plist_paths(domain):
        data = read_plist(path)
        for key in delete_keys:
            data.pop(key, None)
        data.update(values)
        write_plist(path, data)
    kill_cfprefsd()


def plist_bool_value(path: Path, key: str) -> bool | None:
    value = read_plist(path).get(key)
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return value != 0
    if isinstance(value, str):
        return value.lower() in {"1", "true", "yes"}
    return None


def recording_flag(domain: str) -> bool:
    value = defaults_read(domain, "recording_in_progress")
    if value in {"1", "true", "TRUE", "YES", "Yes", "yes"}:
        return True
    return any(
        plist_bool_value(path, "recording_in_progress") is True
        for path in preference_plist_paths(domain)
    )


def running_app_pids() -> list[int]:
    result = run(["pgrep", "-x", PROCESS_NAME], check=False)
    return [int(value) for value in result.stdout.split() if value.isdigit()]


def process_executable(pid: int) -> Path | None:
    result = run(
        ["lsof", "-a", "-p", str(pid), "-d", "txt", "-Fn"],
        check=False,
    )
    for line in result.stdout.splitlines():
        if line.startswith("n/"):
            return Path(line[1:]).resolve()
    return None


def expected_app_binary(app_path: Path) -> Path:
    return (app_path / "Contents" / "MacOS" / PROCESS_NAME).resolve()


def assert_only_expected_app_is_running(app_path: Path) -> list[int]:
    expected = expected_app_binary(app_path)
    pids = running_app_pids()
    for pid in pids:
        executable = process_executable(pid)
        if executable != expected:
            raise RuntimeError(
                "Another SimpleRecorder instance is running and will not be stopped: "
                f"PID {pid}, executable={executable or 'unknown'}, expected={expected}. "
                "End any real recording and quit that app manually before running QA."
            )
    return pids


def app_running(app_path: Path | None = None) -> bool:
    if app_path is None:
        return bool(running_app_pids())
    expected = expected_app_binary(app_path)
    return any(process_executable(pid) == expected for pid in running_app_pids())


def quit_app(bundle_id: str, app_path: Path, timeout: float = 8.0) -> None:
    pids = assert_only_expected_app_is_running(app_path)
    if not pids:
        return
    if recording_flag(bundle_id) or log_recording_active():
        raise RuntimeError(
            "Refusing to quit SimpleRecorder because a recording appears to be active. "
            "Stop and save it before running QA."
        )

    for pid in pids:
        run(
            [
                "osascript",
                "-l",
                "JavaScript",
                "-e",
                (
                    "ObjC.import('AppKit'); "
                    "const app = $.NSRunningApplication."
                    f"runningApplicationWithProcessIdentifier({pid}); "
                    "if (app.js) { app.terminate; }"
                ),
            ],
            check=False,
        )
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not app_running(app_path):
            return
        time.sleep(0.25)
    raise RuntimeError(
        f"App did not exit within {timeout:.0f}s after a graceful quit request; "
        "no force-kill was attempted."
    )


def launch_app(app_path: Path, timeout: float = 10.0) -> None:
    run(["open", str(app_path)])
    deadline = time.time() + timeout
    while time.time() < deadline:
        if app_running(app_path):
            time.sleep(2.0)
            return
        time.sleep(0.25)
    raise RuntimeError(f"App did not launch within {timeout:.0f}s: {app_path}")


def export_preferences(domain: str, backup_dir: Path) -> bool:
    backup_dir.mkdir(parents=True, exist_ok=True)
    manifest: dict[str, dict] = {}
    for index, path in enumerate(preference_plist_paths(domain)):
        key = f"store_{index}"
        target = backup_dir / f"{key}.plist"
        manifest[key] = {"path": str(path), "existed": path.exists()}
        if path.exists():
            shutil.copy2(path, target)
    (backup_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return True


def restore_preferences(domain: str, backup_dir: Path | None) -> None:
    if not backup_dir:
        return
    manifest_path = backup_dir / "manifest.json"
    if not manifest_path.exists():
        return
    kill_cfprefsd()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    for key, entry in manifest.items():
        path = Path(entry["path"])
        source = backup_dir / f"{key}.plist"
        if entry.get("existed") and source.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, path)
        elif path.exists():
            path.unlink()
    kill_cfprefsd()


def configure_app_preferences(domain: str, mode: str, recordings_dir: Path) -> None:
    update_preference_files(
        domain,
        {
            "audioSource": mode,
            "outputFormat": "m4a",
            "selectedDeviceID": "default",
            "recordingsPath_path": str(recordings_dir),
            "openFolderAfterRecording": False,
            "recording_in_progress": False,
        },
        delete_keys=("recordingHotKey", "pauseHotKey"),
    )


def trigger_record_hotkey(key_code: int) -> None:
    script = (
        'tell application "System Events" to key code '
        f"{key_code} using {{command down, option down, control down}}"
    )
    try:
        run(["osascript", "-e", script], timeout=15)
    except CommandError as exc:
        raise RuntimeError(
            "Could not send the recording hotkey through System Events. "
            "Grant Accessibility permission to the terminal/Codex process that runs this script."
        ) from exc


def wait_for_recording_flag(domain: str, expected: bool, timeout: float) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if recording_flag(domain) == expected:
            return True
        time.sleep(0.25)
    return False


def current_log_path() -> Path:
    stamp = datetime.now().strftime("%Y-%m-%d")
    return (
        Path.home()
        / "Library"
        / "Application Support"
        / DEFAULT_BUNDLE_ID
        / "Logs"
        / f"MeetingRecorderPro_{stamp}.log"
    )


def log_offset(path: Path) -> int:
    try:
        return path.stat().st_size
    except FileNotFoundError:
        return 0


def read_log_lines(path: Path, offset: int) -> tuple[list[str], int]:
    if not path.exists():
        return [], offset
    size = path.stat().st_size
    if size < offset:
        offset = 0
    with path.open("rb") as handle:
        handle.seek(offset)
        data = handle.read()
        new_offset = handle.tell()
    if not data:
        return [], new_offset
    return data.decode("utf-8", errors="replace").splitlines(), new_offset


def wait_for_log_line(
    path: Path,
    offset: int,
    *,
    contains: Iterable[str],
    failures: Iterable[str] = (),
    timeout: float,
) -> tuple[str | None, int]:
    wanted = tuple(contains)
    failed = tuple(failures)
    deadline = time.time() + timeout
    current_offset = offset
    while time.time() < deadline:
        lines, current_offset = read_log_lines(path, current_offset)
        for line in lines:
            if any(pattern in line for pattern in failed):
                raise RuntimeError(line)
            if any(pattern in line for pattern in wanted):
                return line, current_offset
        time.sleep(0.25)
    return None, current_offset


def log_recording_active() -> bool:
    path = current_log_path()
    if not path.exists():
        return False
    try:
        size = path.stat().st_size
        with path.open("rb") as handle:
            handle.seek(max(0, size - 250_000))
            data = handle.read()
    except OSError:
        return False

    active = False
    for line in data.decode("utf-8", errors="replace").splitlines():
        if "录音已启动" in line:
            active = True
        elif (
            "录音已保存" in line
            or "录音已紧急保存" in line
            or "结束录音会话" in line
            or "录音启动失败" in line
            or "应用退出" in line
        ):
            active = False
    return active


def list_recording_files(recordings_dir: Path, since: float) -> list[Path]:
    if not recordings_dir.exists():
        return []
    files: list[Path] = []
    for path in recordings_dir.iterdir():
        if (
            path.is_file()
            and path.suffix.lower() in RECORD_EXTENSIONS
            and " - ing" not in path.stem
        ):
            try:
                if path.stat().st_mtime >= since - 1.0:
                    files.append(path)
            except FileNotFoundError:
                continue
    return sorted(files, key=lambda p: p.stat().st_mtime, reverse=True)


def wait_for_new_recording(recordings_dir: Path, since: float, timeout: float) -> Path | None:
    deadline = time.time() + timeout
    last_seen: tuple[Path, int] | None = None
    while time.time() < deadline:
        files = list_recording_files(recordings_dir, since)
        if files:
            candidate = files[0]
            try:
                size = candidate.stat().st_size
            except FileNotFoundError:
                time.sleep(0.25)
                continue
            if last_seen == (candidate, size) and size > 0:
                return candidate
            last_seen = (candidate, size)
        time.sleep(0.5)
    files = list_recording_files(recordings_dir, since)
    return files[0] if files else None


def start_recording(
    domain: str,
    hotkey_code: int,
    timeout: float,
    *,
    attempts: int = 2,
) -> tuple[float, float]:
    wall_start = time.time()
    log_path = current_log_path()
    failures = ("录音启动失败", "麦克风录音启动失败", "系统音频录音启动失败")
    last_error = "Recording did not reach the started log state after the hotkey."
    for attempt in range(max(1, attempts)):
        attempt_offset = log_offset(log_path)
        trigger_record_hotkey(hotkey_code)
        line, _ = wait_for_log_line(
            log_path,
            attempt_offset,
            contains=("收到录音启动请求", "录音已启动"),
            failures=failures,
            timeout=min(5.0, timeout),
        )
        if line is None:
            last_error = "Recording hotkey was not observed by the app."
            continue
        if "录音已启动" in line:
            return wall_start, time.monotonic()

        line, _ = wait_for_log_line(
            log_path,
            attempt_offset,
            contains=("录音已启动",),
            failures=failures,
            timeout=timeout,
        )
        if line is not None:
            return wall_start, time.monotonic()
        last_error = "The app received the start request but did not finish starting."
        break
    raise RuntimeError(last_error)


def stop_recording(
    domain: str,
    hotkey_code: int,
    recordings_dir: Path,
    since: float,
    timeout: float,
    *,
    assume_recording: bool = False,
) -> Path | None:
    if assume_recording or recording_flag(domain):
        trigger_record_hotkey(hotkey_code)
    return wait_for_new_recording(recordings_dir, since, timeout)


def ffprobe_duration(path: Path) -> float | None:
    proc = run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(path),
        ],
        check=False,
    )
    if proc.returncode != 0:
        return None
    try:
        return float(proc.stdout.strip())
    except ValueError:
        return None


def parse_volumedetect(output: str) -> VolumeStats:
    mean_match = re.search(r"mean_volume:\s*(-?inf|-?\d+(?:\.\d+)?) dB", output)
    max_match = re.search(r"max_volume:\s*(-?inf|-?\d+(?:\.\d+)?) dB", output)

    def parse_value(match: re.Match[str] | None) -> float | None:
        if not match:
            return None
        value = match.group(1)
        if value == "-inf":
            return None
        return float(value)

    return VolumeStats(
        mean_db=parse_value(mean_match),
        max_db=parse_value(max_match),
        raw=output[-4000:],
    )


def ffmpeg_volume(path: Path, start: float | None = None, duration: float | None = None) -> VolumeStats:
    filters: list[str] = []
    if start is not None or duration is not None:
        start_value = max(0.0, start or 0.0)
        if duration is None:
            filters.append(f"atrim=start={start_value:.3f}")
        else:
            filters.append(f"atrim=start={start_value:.3f}:duration={max(0.1, duration):.3f}")
        filters.append("asetpts=PTS-STARTPTS")
    filters.append("volumedetect")
    proc = run(
        [
            "ffmpeg",
            "-hide_banner",
            "-nostats",
            "-i",
            str(path),
            "-af",
            ",".join(filters),
            "-f",
            "null",
            "-",
        ],
        check=False,
    )
    return parse_volumedetect((proc.stdout or "") + (proc.stderr or ""))


def volume_dict(stats: VolumeStats) -> dict:
    return {
        "mean_db": stats.mean_db,
        "max_db": stats.max_db,
    }


def assert_audio_file(
    result: CaseResult,
    path: Path | None,
    segments: list[Segment],
    min_duration: float,
) -> None:
    if path is None:
        result.fail("No recording file was created.")
        return

    result.file = str(path)
    duration = ffprobe_duration(path)
    result.duration = duration
    if duration is None:
        result.fail("ffprobe could not read the recording duration.")
        return
    if duration < min_duration:
        result.fail(f"Recording is too short: {duration:.2f}s < {min_duration:.2f}s.")

    full_volume = ffmpeg_volume(path)
    result.full_volume = volume_dict(full_volume)

    for segment in segments:
        stats = ffmpeg_volume(path, segment.start, segment.duration)
        result.segment_volumes[segment.name] = {
            **volume_dict(stats),
            "start": segment.start,
            "duration": segment.duration,
            "threshold_db": segment.threshold_db,
            "required": segment.required,
        }
        if segment.required:
            if stats.max_db is None:
                result.fail(f"Segment '{segment.name}' has no measurable audio.")
            elif stats.max_db <= segment.threshold_db:
                result.fail(
                    f"Segment '{segment.name}' is too quiet: "
                    f"max {stats.max_db:.1f} dB <= threshold {segment.threshold_db:.1f} dB."
                )


def generate_tone(tone_path: Path, duration: float) -> None:
    if tone_path.exists():
        return
    run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-f",
            "lavfi",
            "-i",
            f"sine=frequency=880:duration={duration:.1f}:sample_rate=48000",
            "-af",
            "volume=0.85",
            "-c:a",
            "pcm_s16le",
            str(tone_path),
        ]
    )


def play_tone(tone_path: Path) -> None:
    afplay = command_path("afplay")
    if afplay:
        run([afplay, str(tone_path)], capture=False)
        return

    ffplay = command_path("ffplay")
    if ffplay:
        run([ffplay, "-nodisp", "-autoexit", "-loglevel", "quiet", str(tone_path)], capture=False)
        return

    raise RuntimeError("Neither afplay nor ffplay is available to play the system-audio test tone.")


def countdown(seconds: int, label: str) -> None:
    print(label, flush=True)
    for remaining in range(seconds, 0, -1):
        print(f"  {remaining}...", flush=True)
        time.sleep(1)


def run_mode_recording(
    *,
    name: str,
    mode: str,
    args: argparse.Namespace,
    recordings_dir: Path,
    tone_path: Path,
    manage_app: bool = True,
) -> CaseResult:
    result = CaseResult(name=name, status="passed", mode=mode)
    print_step(f"{name}: {mode}")
    if manage_app:
        quit_app(args.bundle_id, args.app)
        configure_app_preferences(args.bundle_id, mode, recordings_dir)
        launch_app(args.app)

    try:
        since_wall, recording_start = start_recording(
            args.bundle_id,
            args.hotkey_code,
            args.start_timeout,
            attempts=args.start_attempts,
        )
    except Exception as exc:
        result.fail(str(exc))
        return result

    segments: list[Segment] = []

    def elapsed() -> float:
        return max(0.0, time.monotonic() - recording_start)

    time.sleep(args.settle_seconds)

    if mode in {"microphone", "both"}:
        start = elapsed()
        if args.mic_prompt:
            countdown(
                args.prompt_countdown,
                "麦克风测试阶段：请对着当前输入设备持续说几秒话。",
            )
        else:
            print("麦克风测试阶段：未启用人工提示，将依赖环境声音。", flush=True)
        time.sleep(args.mic_seconds)
        segments.append(
            Segment(
                name="mic",
                start=start,
                duration=max(args.mic_seconds, elapsed() - start),
                threshold_db=args.mic_threshold_db,
            )
        )

    if mode in {"system_audio", "both"}:
        time.sleep(args.phase_gap_seconds)
        print("系统声音测试阶段：播放测试音。", flush=True)
        start = elapsed()
        play_tone(tone_path)
        segments.append(
            Segment(
                name="system",
                start=start,
                duration=args.tone_seconds,
                threshold_db=args.system_threshold_db,
            )
        )

    path = stop_recording(
        args.bundle_id,
        args.hotkey_code,
        recordings_dir,
        since_wall,
        args.stop_timeout,
        assume_recording=True,
    )
    min_duration = max(1.0, sum(segment.duration for segment in segments) * 0.55)
    assert_audio_file(result, path, segments, min_duration)
    return result


def switch_audio_source(kind: str, device_name: str) -> bool:
    switcher = command_path("SwitchAudioSource")
    if not switcher:
        return False
    proc = run([switcher, "-t", kind, "-s", device_name], check=False)
    return proc.returncode == 0


def current_audio_source(kind: str) -> str | None:
    switcher = command_path("SwitchAudioSource")
    if not switcher:
        return None
    proc = run([switcher, "-t", kind, "-c"], check=False)
    if proc.returncode != 0:
        return None
    return proc.stdout.strip()


def list_switch_audio_sources(kind: str) -> list[str]:
    switcher = command_path("SwitchAudioSource")
    if not switcher:
        return []
    proc = run([switcher, "-a", "-t", kind], check=False)
    if proc.returncode != 0:
        return []
    return sorted({line.strip() for line in proc.stdout.splitlines() if line.strip()})


def list_avfoundation_inputs() -> list[Device]:
    swift = command_path("swift")
    if not swift:
        return []

    swift_code = r'''
import AVFoundation

let deviceTypes: [AVCaptureDevice.DeviceType]
if #available(macOS 14.0, *) {
    deviceTypes = [.microphone, .external]
} else {
    deviceTypes = [.builtInMicrophone, .externalUnknown]
}

let session = AVCaptureDevice.DiscoverySession(
    deviceTypes: deviceTypes,
    mediaType: .audio,
    position: .unspecified
)

var seen = Set<String>()
for device in session.devices {
    if seen.contains(device.uniqueID) { continue }
    seen.insert(device.uniqueID)
    print("\(device.localizedName)\t\(device.uniqueID)")
}
'''
    proc = run([swift, "-e", swift_code], check=False, timeout=20)
    if proc.returncode != 0:
        return []
    devices: list[Device] = []
    for line in proc.stdout.splitlines():
        if "\t" in line:
            name, unique_id = line.split("\t", 1)
            devices.append(Device(name=name, unique_id=unique_id, source="AVFoundation"))
    return devices


def list_ffmpeg_avfoundation_inputs() -> list[str]:
    if not command_path("ffmpeg"):
        return []
    proc = run(
        ["ffmpeg", "-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""],
        check=False,
        timeout=15,
    )
    output = (proc.stdout or "") + (proc.stderr or "")
    names: list[str] = []
    in_audio = False
    for line in output.splitlines():
        if "AVFoundation audio devices" in line:
            in_audio = True
            continue
        if "AVFoundation video devices" in line:
            in_audio = False
        if in_audio:
            match = re.search(r"\[\d+\]\s+(.+)$", line)
            if match:
                names.append(match.group(1).strip())
    return names


def device_pairs(devices: list[str], quick: bool) -> list[tuple[str, str]]:
    pairs = [(a, b) for a, b in itertools.permutations(devices, 2) if a != b]
    if quick and pairs:
        return [pairs[0]]
    return pairs


def run_input_switch_case(
    *,
    mode: str,
    source: str,
    target: str,
    args: argparse.Namespace,
    recordings_dir: Path,
    tone_path: Path,
) -> list[CaseResult]:
    name = f"input_switch/{mode}/{source} -> {target}"
    result = CaseResult(name=name, status="passed", mode=mode)
    print_step(name)

    if not args.manual_device_switch and not switch_audio_source("input", source):
        result.status = "skipped"
        result.note(f"Could not switch input to '{source}'.")
        return [result]

    quit_app(args.bundle_id, args.app)
    configure_app_preferences(args.bundle_id, mode, recordings_dir)
    launch_app(args.app)

    try:
        since_wall, recording_start = start_recording(
            args.bundle_id,
            args.hotkey_code,
            args.start_timeout,
            attempts=args.start_attempts,
        )
    except Exception as exc:
        result.fail(str(exc))
        return [result]

    def elapsed() -> float:
        return max(0.0, time.monotonic() - recording_start)

    time.sleep(args.settle_seconds)
    audible_start = elapsed()
    if args.mic_prompt:
        countdown(
            args.prompt_countdown,
            "输入切换前录音验证：请对着当前输入设备持续说几秒话。",
        )
    else:
        print("输入切换前录音验证：未启用人工提示，将依赖环境声音。", flush=True)
    time.sleep(args.mic_seconds)
    audible_segment = Segment(
        name="input_before_switch",
        start=audible_start,
        duration=max(args.mic_seconds, elapsed() - audible_start),
        threshold_db=args.mic_threshold_db,
    )

    time.sleep(args.switch_before_seconds)
    if args.manual_device_switch:
        countdown(
            args.prompt_countdown,
            "请现在连接/断开耳机或切换输入设备；脚本会观察录音是否被中断。",
        )
    else:
        if not switch_audio_source("input", target):
            result.fail(f"Could not switch input to '{target}'.")
            stop_recording(
                args.bundle_id,
                args.hotkey_code,
                recordings_dir,
                since_wall,
                args.stop_timeout,
                assume_recording=True,
            )
            return [result]

    interrupted = wait_for_recording_flag(args.bundle_id, False, args.switch_observe_seconds)
    path = wait_for_new_recording(recordings_dir, since_wall, args.stop_timeout)
    if interrupted:
        result.note("Recording stopped after input-device change, as expected.")
    else:
        result.fail(
            "Recording was still marked active after the input-device change observation window."
        )
        stop_recording(args.bundle_id, args.hotkey_code, recordings_dir, since_wall, args.stop_timeout)

    assert_audio_file(
        result,
        path,
        [audible_segment],
        min_duration=max(1.0, audible_segment.duration * 0.55),
    )

    restart = run_mode_recording(
        name=f"input_switch_restart/{mode}/after {target}",
        mode=mode,
        args=args,
        recordings_dir=recordings_dir,
        tone_path=tone_path,
    )
    return [result, restart]


def run_output_switch_case(
    *,
    mode: str,
    source: str,
    target: str,
    args: argparse.Namespace,
    recordings_dir: Path,
    tone_path: Path,
) -> CaseResult:
    name = f"output_switch/{mode}/{source} -> {target}"
    result = CaseResult(name=name, status="passed", mode=mode)
    print_step(name)

    if not args.manual_device_switch and not switch_audio_source("output", source):
        result.status = "skipped"
        result.note(f"Could not switch output to '{source}'.")
        return result

    quit_app(args.bundle_id, args.app)
    configure_app_preferences(args.bundle_id, mode, recordings_dir)
    launch_app(args.app)

    try:
        since_wall, recording_start = start_recording(
            args.bundle_id,
            args.hotkey_code,
            args.start_timeout,
            attempts=args.start_attempts,
        )
    except Exception as exc:
        result.fail(str(exc))
        return result

    def elapsed() -> float:
        return max(0.0, time.monotonic() - recording_start)

    time.sleep(args.settle_seconds)
    print("输出切换前：播放测试音。", flush=True)
    before_start = elapsed()
    play_tone(tone_path)

    if args.manual_device_switch:
        countdown(
            args.prompt_countdown,
            "请现在连接/断开耳机或切换输出设备；随后会再次播放测试音。",
        )
    else:
        if not switch_audio_source("output", target):
            result.fail(f"Could not switch output to '{target}'.")
            stop_recording(
                args.bundle_id,
                args.hotkey_code,
                recordings_dir,
                since_wall,
                args.stop_timeout,
                assume_recording=True,
            )
            return result
    time.sleep(args.switch_after_seconds)

    if not recording_flag(args.bundle_id):
        result.fail("Recording stopped after output-device change; it should have continued.")
        path = wait_for_new_recording(recordings_dir, since_wall, args.stop_timeout)
        assert_audio_file(result, path, [], 1.0)
        return result

    print("输出切换后：播放测试音。", flush=True)
    after_start = elapsed()
    play_tone(tone_path)
    path = stop_recording(
        args.bundle_id,
        args.hotkey_code,
        recordings_dir,
        since_wall,
        args.stop_timeout,
        assume_recording=True,
    )

    segments = [
        Segment("system_before_output_switch", before_start, args.tone_seconds, args.system_threshold_db),
        Segment("system_after_output_switch", after_start, args.tone_seconds, args.system_threshold_db),
    ]
    assert_audio_file(result, path, segments, args.tone_seconds * 1.2)
    return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run SimpleRecorder integration tests against the installed macOS app."
    )
    parser.add_argument("--app", type=Path, default=DEFAULT_APP_PATH, help="Path to SimpleRecorder.app.")
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    parser.add_argument(
        "--results-dir",
        type=Path,
        default=REPO_ROOT / "test-results" / "recording-integration",
        help="Directory where reports and test recordings are written.",
    )
    parser.add_argument("--modes", nargs="+", choices=MODES, default=list(MODES))
    parser.add_argument("--yes", action="store_true", help="Actually drive the app and record audio.")
    parser.add_argument("--dry-run", action="store_true", help="Print the planned run and exit.")
    parser.add_argument("--list-devices", action="store_true", help="Print discovered audio devices and exit.")
    parser.add_argument("--quick", action="store_true", help="Use only the first device pair per switch test.")
    parser.add_argument("--skip-device-switch", action="store_true")
    parser.add_argument(
        "--manual-device-switch",
        action="store_true",
        help="Prompt you to physically connect/disconnect devices instead of using SwitchAudioSource.",
    )
    parser.add_argument("--hotkey-code", type=int, default=23, help="macOS virtual key code for 5.")
    parser.add_argument("--start-attempts", type=int, default=2)
    parser.add_argument("--start-timeout", type=float, default=12.0)
    parser.add_argument("--stop-timeout", type=float, default=20.0)
    parser.add_argument("--settle-seconds", type=float, default=1.0)
    parser.add_argument("--mic-seconds", type=float, default=4.0)
    parser.add_argument("--tone-seconds", type=float, default=4.0)
    parser.add_argument("--phase-gap-seconds", type=float, default=0.8)
    parser.add_argument("--prompt-countdown", type=int, default=3)
    parser.add_argument("--switch-before-seconds", type=float, default=2.0)
    parser.add_argument("--switch-after-seconds", type=float, default=1.0)
    parser.add_argument("--switch-observe-seconds", type=float, default=10.0)
    parser.add_argument("--mic-threshold-db", type=float, default=-60.0)
    parser.add_argument("--system-threshold-db", type=float, default=-55.0)
    parser.add_argument(
        "--no-mic-prompt",
        dest="mic_prompt",
        action="store_false",
        help="Do not prompt for spoken microphone test audio.",
    )
    parser.set_defaults(mic_prompt=True)
    return parser


def collect_environment() -> dict:
    return {
        "host": socket.gethostname(),
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "dependencies": {
            "SwitchAudioSource": command_path("SwitchAudioSource"),
            "ffmpeg": command_path("ffmpeg"),
            "ffprobe": command_path("ffprobe"),
            "afplay": command_path("afplay"),
            "ffplay": command_path("ffplay"),
            "swift": command_path("swift"),
        },
        "devices": {
            "switch_input": list_switch_audio_sources("input"),
            "switch_output": list_switch_audio_sources("output"),
            "current_input": current_audio_source("input"),
            "current_output": current_audio_source("output"),
            "avfoundation_input": [asdict(device) for device in list_avfoundation_inputs()],
            "ffmpeg_avfoundation_input": list_ffmpeg_avfoundation_inputs(),
        },
    }


def print_devices(env: dict) -> None:
    devices = env["devices"]
    print("SwitchAudioSource input:")
    for name in devices["switch_input"]:
        marker = "  *" if name == devices["current_input"] else "   "
        print(f"{marker} {name}")
    print("\nSwitchAudioSource output:")
    for name in devices["switch_output"]:
        marker = "  *" if name == devices["current_output"] else "   "
        print(f"{marker} {name}")
    print("\nAVFoundation input:")
    for device in devices["avfoundation_input"]:
        print(f"   {device['name']} [{device['unique_id']}]")
    print("\nffmpeg AVFoundation input:")
    for name in devices["ffmpeg_avfoundation_input"]:
        print(f"   {name}")


def validate_dependencies(env: dict) -> list[str]:
    missing = []
    deps = env["dependencies"]
    for name in ("ffmpeg", "ffprobe"):
        if not deps.get(name):
            missing.append(name)
    if not deps.get("afplay") and not deps.get("ffplay"):
        missing.append("afplay or ffplay")
    return missing


def write_report(report_path: Path, report: dict) -> None:
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    args.app = args.app.expanduser().resolve()
    args.results_dir = args.results_dir.expanduser().resolve()

    env = collect_environment()

    if args.list_devices:
        print_devices(env)
        return 0

    missing = validate_dependencies(env)
    if missing:
        print(f"Missing required dependency: {', '.join(missing)}", file=sys.stderr)
        return 2

    if not args.app.exists():
        print(f"App not found: {args.app}", file=sys.stderr)
        return 2

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    run_dir = args.results_dir / timestamp
    recordings_dir = run_dir / "recordings"
    report_path = run_dir / "report.json"
    tone_path = run_dir / f"system-tone-{args.tone_seconds:.0f}s.wav"

    planned_cases: list[str] = []
    for mode in args.modes:
        planned_cases.append(f"restart/{mode}/first")
        planned_cases.append(f"restart/{mode}/second")

    input_pairs = device_pairs(env["devices"]["switch_input"], args.quick)
    output_pairs = device_pairs(env["devices"]["switch_output"], args.quick)
    if not args.skip_device_switch:
        for mode in [mode for mode in args.modes if mode in {"microphone", "both"}]:
            for source, target in input_pairs:
                planned_cases.append(f"input_switch/{mode}/{source} -> {target}")
                planned_cases.append(f"input_switch_restart/{mode}/after {target}")
        for mode in [mode for mode in args.modes if mode in {"system_audio", "both"}]:
            for source, target in output_pairs:
                planned_cases.append(f"output_switch/{mode}/{source} -> {target}")

    print("Planned cases:")
    for case in planned_cases:
        print(f"  - {case}")
    print(f"\nResults directory: {run_dir}")

    if args.dry_run:
        return 0
    if not args.yes:
        print("\nRefusing to record/switch devices without --yes.", file=sys.stderr)
        return 2

    recordings_dir.mkdir(parents=True, exist_ok=True)
    generate_tone(tone_path, args.tone_seconds)

    assert_only_expected_app_is_running(args.app)
    was_running = app_running(args.app)
    original_input = env["devices"]["current_input"]
    original_output = env["devices"]["current_output"]
    pref_backup = run_dir / "userdefaults-backup"
    backup_exists = export_preferences(args.bundle_id, pref_backup)
    if not backup_exists:
        pref_backup = None

    results: list[CaseResult] = []
    report = {
        **app_release_metadata(args.app),
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "appPath": str(args.app),
        "environment": env,
        "planned_cases": planned_cases,
        "results_dir": str(run_dir),
        "recordings_dir": str(recordings_dir),
        "results": [],
        "summary": {},
    }

    try:
        if log_recording_active():
            raise RuntimeError(
                "The app says a recording is already in progress. Stop it before running tests."
            )

        for mode in args.modes:
            quit_app(args.bundle_id, args.app)
            configure_app_preferences(args.bundle_id, mode, recordings_dir)
            launch_app(args.app)
            results.append(
                run_mode_recording(
                    name=f"restart/{mode}/first",
                    mode=mode,
                    args=args,
                    recordings_dir=recordings_dir,
                    tone_path=tone_path,
                    manage_app=False,
                )
            )
            results.append(
                run_mode_recording(
                    name=f"restart/{mode}/second",
                    mode=mode,
                    args=args,
                    recordings_dir=recordings_dir,
                    tone_path=tone_path,
                    manage_app=False,
                )
            )
            if log_recording_active():
                raise RuntimeError(f"Mode {mode} still appears to be recording after restart tests.")
            quit_app(args.bundle_id, args.app)

        if not args.skip_device_switch:
            if args.manual_device_switch and not input_pairs:
                input_pairs = [("manual-current-input", "manual-new-input")]
            for mode in [mode for mode in args.modes if mode in {"microphone", "both"}]:
                if not input_pairs:
                    results.append(
                        CaseResult(
                            name=f"input_switch/{mode}",
                            status="skipped",
                            mode=mode,
                            notes=["Fewer than two input devices were available."],
                        )
                    )
                    continue
                for source, target in input_pairs:
                    results.extend(
                        run_input_switch_case(
                            mode=mode,
                            source=source,
                            target=target,
                            args=args,
                            recordings_dir=recordings_dir,
                            tone_path=tone_path,
                        )
                    )

            if args.manual_device_switch and not output_pairs:
                output_pairs = [("manual-current-output", "manual-new-output")]
            for mode in [mode for mode in args.modes if mode in {"system_audio", "both"}]:
                if not output_pairs:
                    results.append(
                        CaseResult(
                            name=f"output_switch/{mode}",
                            status="skipped",
                            mode=mode,
                            notes=["Fewer than two output devices were available."],
                        )
                    )
                    continue
                for source, target in output_pairs:
                    results.append(
                        run_output_switch_case(
                            mode=mode,
                            source=source,
                            target=target,
                            args=args,
                            recordings_dir=recordings_dir,
                            tone_path=tone_path,
                        )
                    )
    except KeyboardInterrupt:
        print("\nInterrupted by user.", file=sys.stderr)
        results.append(CaseResult(name="run", status="failed", errors=["Interrupted by user."]))
    except Exception as exc:
        results.append(CaseResult(name="run", status="failed", errors=[str(exc)]))
    finally:
        try:
            if log_recording_active():
                stop_log_path = current_log_path()
                stop_offset = log_offset(stop_log_path)
                trigger_record_hotkey(args.hotkey_code)
                wait_for_log_line(
                    stop_log_path,
                    stop_offset,
                    contains=("录音已保存", "录音已紧急保存", "结束录音会话"),
                    timeout=args.stop_timeout,
                )
        except Exception:
            pass
        cleanup_succeeded = True
        try:
            quit_app(args.bundle_id, args.app)
        except Exception as exc:
            cleanup_succeeded = False
            results.append(
                CaseResult(name="cleanup", status="failed", errors=[str(exc)])
            )
        if cleanup_succeeded:
            restore_preferences(args.bundle_id, pref_backup)
            if original_input:
                switch_audio_source("input", original_input)
            if original_output:
                switch_audio_source("output", original_output)
            if was_running:
                launch_app(args.app)
        else:
            results.append(
                CaseResult(
                    name="cleanup_restore",
                    status="failed",
                    errors=[
                        "App is still running, so preferences and audio routes were not changed underneath it."
                    ],
                )
            )

        report["results"] = [asdict(result) for result in results]
        summary = {
            "passed": sum(1 for result in results if result.status == "passed"),
            "failed": sum(1 for result in results if result.status == "failed"),
            "skipped": sum(1 for result in results if result.status == "skipped"),
        }
        report["summary"] = summary
        write_report(report_path, report)

    print(f"\nReport: {report_path}")
    print(json.dumps(report["summary"], ensure_ascii=False, indent=2))
    return 1 if any(result.status == "failed" for result in results) else 0


if __name__ == "__main__":
    raise SystemExit(main())
