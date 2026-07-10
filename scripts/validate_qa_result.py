#!/usr/bin/env python3
"""Validate a complete QAAutomationRunner result without allowing false-green reports."""

from __future__ import annotations

import argparse
import json
import plistlib
import sys
from collections import Counter
from pathlib import Path


def parse_bool(value: str) -> bool:
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "y"}:
        return True
    if normalized in {"0", "false", "no", "n"}:
        return False
    raise argparse.ArgumentTypeError(f"expected boolean, got: {value}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result", required=True, type=Path)
    parser.add_argument("--recordings", required=True, type=Path)
    parser.add_argument("--app-info-plist", required=True, type=Path)
    parser.add_argument("--expect-mp3", type=parse_bool, default=True)
    parser.add_argument("--expect-system-audio", type=parse_bool, default=True)
    parser.add_argument("--expect-mixed-audio", type=parse_bool, default=True)
    parser.add_argument("--expect-timer", type=parse_bool, default=True)
    parser.add_argument("--allow-skips", type=parse_bool, default=False)
    return parser.parse_args()


def fail(errors: list[str]) -> None:
    for error in errors:
        print(f"QA result invalid: {error}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    args = parse_args()
    errors: list[str] = []

    try:
        data = json.loads(args.result.read_text(encoding="utf-8"))
    except Exception as error:
        fail([f"cannot read JSON {args.result}: {error}"])
        return

    if not isinstance(data, dict):
        fail(["top-level value must be an object"])
    steps = data.get("steps")
    summary = data.get("summary")
    if not isinstance(steps, list):
        fail(["steps must be an array"])
    if not isinstance(summary, dict):
        fail(["summary must be an object"])

    expected = [
        "3.x 5.x settings-round-trip",
        "4.1 microphone-basic",
        "4.2 microphone-pause-resume",
        "4.5 microphone-second-pass",
    ]
    if args.expect_mp3:
        expected.append("5.2 output-format-mp3")
    if args.expect_system_audio:
        expected.append("4.3 system-audio")
    if args.expect_mixed_audio:
        expected.append("4.4 mixed-audio")
    if args.expect_timer:
        expected.append("6.2 timer-auto-start")
    expected.append("manual-remainder")

    names: list[str] = []
    normalized_steps: list[dict] = []
    for index, step in enumerate(steps):
        if not isinstance(step, dict):
            errors.append(f"steps[{index}] must be an object")
            continue
        name = step.get("name")
        if not isinstance(name, str) or not name:
            errors.append(f"steps[{index}].name must be a non-empty string")
            continue
        names.append(name)
        normalized_steps.append(step)

    counts = Counter(names)
    duplicates = sorted(name for name, count in counts.items() if count != 1)
    if duplicates:
        errors.append(f"duplicate step names: {', '.join(duplicates)}")
    missing = sorted(set(expected) - set(names))
    unexpected = sorted(set(names) - set(expected))
    if missing:
        errors.append(f"missing required steps: {', '.join(missing)}")
    if unexpected:
        errors.append(f"unexpected steps: {', '.join(unexpected)}")

    recordings_root = args.recordings.resolve()
    reported_recordings_path = data.get("recordingsPath")
    if not isinstance(reported_recordings_path, str):
        errors.append("recordingsPath must be present")
    else:
        try:
            if Path(reported_recordings_path).resolve() != recordings_root:
                errors.append("recordingsPath does not match this QA run")
        except OSError as error:
            errors.append(f"cannot resolve recordingsPath: {error}")

    non_recording_steps = {"3.x 5.x settings-round-trip", "manual-remainder"}
    valid_statuses = {"passed", "failed", "skipped"}
    for step in normalized_steps:
        name = step["name"]
        status = step.get("status")
        if status not in valid_statuses:
            errors.append(f"{name}: invalid status {status!r}")
            continue
        if name == "manual-remainder":
            if status != "skipped":
                errors.append("manual-remainder must be skipped")
            continue
        if status != "passed" and not (args.allow_skips and status == "skipped"):
            errors.append(f"{name}: required status is passed, got {status}")

        recordings = step.get("recordings")
        if name in non_recording_steps or status != "passed":
            continue
        if not isinstance(recordings, list) or not recordings:
            errors.append(f"{name}: passed recording step has no referenced recordings")
            continue
        valid_recording_found = False
        for item in recordings:
            if not isinstance(item, dict):
                continue
            raw_path = item.get("path")
            if not isinstance(raw_path, str) or not raw_path:
                continue
            path = Path(raw_path).resolve()
            try:
                path.relative_to(recordings_root)
            except ValueError:
                errors.append(f"{name}: recording is outside this QA run: {path}")
                continue
            if not path.is_file():
                errors.append(f"{name}: referenced recording is missing: {path}")
                continue
            if (
                item.get("validationError") in (None, "")
                and isinstance(item.get("durationSeconds"), (int, float))
                and item["durationSeconds"] > 0
                and isinstance(item.get("peakAmplitude"), (int, float))
                and item["peakAmplitude"] >= 0.001
                and isinstance(item.get("rmsAmplitude"), (int, float))
                and item["rmsAmplitude"] >= 0.0001
            ):
                valid_recording_found = True
        if not valid_recording_found:
            errors.append(f"{name}: no referenced recording has valid duration/peak/RMS metrics")

    actual_counts = Counter(step.get("status") for step in normalized_steps)
    expected_summary = {
        "total": len(normalized_steps),
        "passed": actual_counts["passed"],
        "failed": actual_counts["failed"],
        "skipped": actual_counts["skipped"],
    }
    for key, expected_value in expected_summary.items():
        if summary.get(key) != expected_value:
            errors.append(
                f"summary.{key}={summary.get(key)!r}, expected {expected_value} from steps"
            )

    try:
        with args.app_info_plist.open("rb") as handle:
            app_info = plistlib.load(handle)
        if data.get("appVersion") != app_info.get("CFBundleShortVersionString"):
            errors.append("qa appVersion does not match public Release app")
        if str(data.get("buildVersion")) != str(app_info.get("CFBundleVersion")):
            errors.append("qa buildVersion does not match public Release app")
    except Exception as error:
        errors.append(f"cannot read Release Info.plist: {error}")

    if errors:
        fail(errors)
    print(
        "QA result valid: "
        f"passed={expected_summary['passed']} failed={expected_summary['failed']} "
        f"skipped={expected_summary['skipped']} total={expected_summary['total']}"
    )


if __name__ == "__main__":
    main()
