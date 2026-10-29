#!/usr/bin/env python3
"""Bind publication to matching full-QA and real-recording evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import subprocess
import sys
from collections import Counter
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_json(path: Path, label: str, errors: list[str]) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except Exception as error:
        errors.append(f"cannot read {label} {path}: {error}")
        return {}
    if not isinstance(value, dict):
        errors.append(f"{label} must contain a JSON object")
        return {}
    return value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--qa-evidence", required=True, type=Path)
    parser.add_argument("--integration-report", required=True, type=Path)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--dmg", required=True, type=Path)
    args = parser.parse_args()

    errors: list[str] = []
    qa = load_json(args.qa_evidence, "QA evidence", errors)
    integration = load_json(args.integration_report, "integration report", errors)
    try:
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    except Exception as error:
        errors.append(f"cannot read Git HEAD: {error}")
        head = ""

    try:
        with (args.app / "Contents" / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        version = str(info["CFBundleShortVersionString"])
        build_version = str(info["CFBundleVersion"])
        executable_hash = sha256(args.app / "Contents" / "MacOS" / "SimpleRecorder")
    except Exception as error:
        errors.append(f"cannot read app version: {error}")
        version = build_version = executable_hash = ""

    dmg_hash = sha256(args.dmg) if args.dmg.is_file() else ""
    expected = {
        "gitCommit": head,
        "appVersion": version,
        "buildVersion": build_version,
    }
    for key, value in expected.items():
        if qa.get(key) != value:
            errors.append(f"QA evidence {key} does not match current release")
        if str(integration.get(key, "")) != value:
            errors.append(f"integration report {key} does not match current release")
    if integration.get("appExecutableSHA256") != executable_hash:
        errors.append(
            "integration report executable SHA-256 does not match the exact Release app"
        )
    if qa.get("schemaVersion") != 1 or qa.get("status") != "passed":
        errors.append("QA evidence is not a passed schemaVersion 1 record")
    if qa.get("allowSkips") is not False:
        errors.append("QA evidence must be produced with skips disabled")
    if qa.get("dmgSHA256") != dmg_hash:
        errors.append("QA evidence DMG SHA-256 does not match publication artifact")
    if qa.get("dmgFileName") != args.dmg.name:
        errors.append("QA evidence DMG filename does not match publication artifact")

    qa_result_path = Path(str(qa.get("qaResultPath", "")))
    if not qa_result_path.is_file():
        errors.append("QA evidence references a missing qa-result.json")
    elif qa.get("qaResultSHA256") != sha256(qa_result_path):
        errors.append("qa-result.json changed after QA evidence was written")

    qa_summary = qa.get("summary")
    if not isinstance(qa_summary, dict):
        errors.append("QA evidence summary is missing")
    elif qa_summary.get("failed") != 0 or qa_summary.get("skipped") != 1:
        errors.append("QA evidence must have failed=0 and only manual-remainder skipped")

    results = integration.get("results")
    summary = integration.get("summary")
    if not isinstance(results, list) or not isinstance(summary, dict):
        errors.append("integration report results/summary are missing")
        results = []
        summary = {}
    result_objects = [item for item in results if isinstance(item, dict)]
    names = [item.get("name") for item in result_objects if isinstance(item.get("name"), str)]
    duplicate_names = sorted(name for name, count in Counter(names).items() if count != 1)
    if duplicate_names:
        errors.append(f"integration report has duplicate cases: {', '.join(duplicate_names)}")

    profile = integration.get("profile")
    valid_profiles = {"smoke", "restart", "input-switch", "long-recording", "full"}
    if profile not in valid_profiles:
        errors.append(
            "integration report profile must be one of: "
            + ", ".join(sorted(valid_profiles))
        )

    modes = integration.get("modes")
    if not isinstance(modes, list) or not modes or any(
        mode not in {"microphone", "system_audio", "both"} for mode in modes
    ):
        errors.append("integration report modes are missing or invalid")
        modes = []
    elif profile == "long-recording" and len(modes) != 1:
        errors.append("long-recording evidence must target exactly one mode")
    elif profile in {"smoke", "restart", "full"} and not (
        "both" in modes or {"microphone", "system_audio"} <= set(modes)
    ):
        # 发布证据必须同时录到真人说话和系统声音；混合模式一次录音即可覆盖两者。
        errors.append("integration evidence must cover microphone and system audio")

    planned_cases = integration.get("planned_cases")
    if not isinstance(planned_cases, list) or not planned_cases or any(
        not isinstance(name, str) for name in planned_cases
    ):
        errors.append("integration report planned_cases are missing or invalid")
        planned_cases = []

    by_name = {item.get("name"): item for item in result_objects}

    recordings_root_raw = integration.get("recordings_dir")
    recordings_root = (
        Path(recordings_root_raw).resolve()
        if isinstance(recordings_root_raw, str) and recordings_root_raw
        else None
    )

    def validate_audio_case(item: dict, name: str) -> None:
        raw_path = item.get("file")
        if not isinstance(raw_path, str) or not raw_path:
            errors.append(f"passed integration case has no recording file: {name}")
            return
        path = Path(raw_path).resolve()
        if not path.is_file():
            errors.append(f"integration recording is missing: {name}: {path}")
            return
        if recordings_root is None:
            errors.append("integration report recordings_dir is missing")
        else:
            try:
                path.relative_to(recordings_root)
            except ValueError:
                errors.append(f"integration recording is outside its run directory: {name}")
        duration = item.get("duration")
        if not isinstance(duration, (int, float)) or duration < 0.5:
            errors.append(f"integration recording has invalid duration: {name}")
        full_volume = item.get("full_volume")
        max_db = full_volume.get("max_db") if isinstance(full_volume, dict) else None
        if not isinstance(max_db, (int, float)) or max_db <= -80.0:
            errors.append(f"integration recording is silent or has no volume metrics: {name}")

    if isinstance(profile, str):
        if profile == "smoke":
            required_names = [f"smoke/{mode}" for mode in modes]
        elif profile == "restart":
            required_names = [
                f"restart/{mode}/{pass_name}"
                for mode in modes
                for pass_name in ("first", "second")
            ]
        elif profile == "long-recording":
            required_names = [f"long_recording/{mode}" for mode in modes]
        else:
            required_names = [
                f"restart/{mode}/{pass_name}"
                for mode in modes
                for pass_name in ("first", "second")
            ] if profile == "full" else []

        if profile in {"input-switch", "full"}:
            input_switches = [
                name for name in planned_cases if name.startswith("input_switch/")
            ]
            input_restarts = [
                name
                for name in planned_cases
                if name.startswith(("input_switch_autorestart/", "input_switch_restart/"))
            ]
            if not input_switches or not input_restarts:
                errors.append(
                    "input-switch and input-switch-restart cases are required "
                    f"for profile {profile}"
                )
            required_names.extend(input_switches)
            required_names.extend(input_restarts)

        if profile == "long-recording":
            for name in required_names:
                item = by_name.get(name, {})
                duration = item.get("duration")
                if isinstance(duration, (int, float)) and duration < 30.0:
                    errors.append(
                        f"long-recording case is shorter than 30 seconds: {name}"
                    )

        for name in required_names:
            item = by_name.get(name)
            if not isinstance(item, dict):
                errors.append(f"required integration case is missing: {name}")
                continue
            if item.get("status") != "passed":
                errors.append(f"required integration case did not pass: {name}")
            else:
                validate_audio_case(item, name)

        for name in planned_cases:
            if name not in required_names:
                errors.append(f"integration report contains an unrecognized case: {name}")

    for item in result_objects:
        status = item.get("status")
        name = str(item.get("name", ""))
        if status == "failed":
            errors.append(f"integration case failed: {name}")
        if status == "skipped":
            errors.append(f"integration case was skipped: {name}")

    actual = Counter(item.get("status") for item in result_objects)
    expected_summary = {
        "passed": actual["passed"],
        "failed": actual["failed"],
        "skipped": actual["skipped"],
    }
    for key, value in expected_summary.items():
        if summary.get(key) != value:
            errors.append(f"integration summary.{key} does not match results")
    if expected_summary["failed"] != 0:
        errors.append("integration report has failed cases")

    if errors:
        for error in errors:
            print(f"Release evidence invalid: {error}", file=sys.stderr)
        raise SystemExit(1)
    print(
        "Release evidence valid: "
        f"commit={head[:12]} version={version} ({build_version}) dmg={dmg_hash}"
    )


if __name__ == "__main__":
    main()
