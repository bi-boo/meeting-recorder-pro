#!/usr/bin/env python3
"""Create and verify the source provenance of a release App/DMG pair."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import subprocess
import sys
from pathlib import Path


SCHEMA_VERSION = 1


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def git_output(repo_root: Path, *args: str) -> str:
    return subprocess.check_output(
        ["/usr/bin/git", "-C", str(repo_root), *args],
        text=True,
    ).strip()


def require_clean_repo(repo_root: Path) -> None:
    status = git_output(repo_root, "status", "--porcelain", "--untracked-files=normal")
    if status:
        raise ValueError("Git worktree is not clean; release provenance cannot be established")


def artifact_metadata(repo_root: Path, app: Path, dmg: Path) -> dict[str, object]:
    info_path = app / "Contents" / "Info.plist"
    executable_path = app / "Contents" / "MacOS" / "SimpleRecorder"
    if not info_path.is_file():
        raise ValueError(f"App Info.plist is missing: {info_path}")
    if not executable_path.is_file():
        raise ValueError(f"App executable is missing: {executable_path}")
    if not dmg.is_file():
        raise ValueError(f"DMG is missing: {dmg}")

    with info_path.open("rb") as handle:
        info = plistlib.load(handle)

    return {
        "schemaVersion": SCHEMA_VERSION,
        "gitCommit": git_output(repo_root, "rev-parse", "HEAD"),
        "appVersion": str(info["CFBundleShortVersionString"]),
        "buildVersion": str(info["CFBundleVersion"]),
        "appExecutableSHA256": sha256(executable_path),
        "dmgFileName": dmg.name,
        "dmgSHA256": sha256(dmg),
    }


def create_manifest(manifest: Path, repo_root: Path, app: Path, dmg: Path) -> None:
    require_clean_repo(repo_root)
    metadata = artifact_metadata(repo_root, app, dmg)
    manifest.parent.mkdir(parents=True, exist_ok=True)
    temporary = manifest.with_name(f".{manifest.name}.tmp")
    temporary.write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(manifest)
    print(
        "Release artifact manifest created: "
        f"commit={str(metadata['gitCommit'])[:12]} dmg={metadata['dmgSHA256']}"
    )


def verify_manifest(manifest: Path, repo_root: Path, app: Path, dmg: Path) -> None:
    require_clean_repo(repo_root)
    if not manifest.is_file():
        raise ValueError(f"Release artifact manifest is missing: {manifest}")
    try:
        recorded = json.loads(manifest.read_text(encoding="utf-8"))
    except Exception as error:
        raise ValueError(f"Release artifact manifest cannot be read: {error}") from error
    if not isinstance(recorded, dict):
        raise ValueError("Release artifact manifest must contain a JSON object")

    current = artifact_metadata(repo_root, app, dmg)
    labels = {
        "schemaVersion": "schema version",
        "gitCommit": "Git commit",
        "appVersion": "App version",
        "buildVersion": "App build version",
        "appExecutableSHA256": "App executable SHA-256",
        "dmgFileName": "DMG filename",
        "dmgSHA256": "DMG SHA-256",
    }
    errors = [
        f"{label} does not match the build-time manifest"
        for key, label in labels.items()
        if recorded.get(key) != current.get(key)
    ]
    if errors:
        raise ValueError("; ".join(errors))
    print(
        "Release artifact manifest valid: "
        f"commit={str(current['gitCommit'])[:12]} dmg={current['dmgSHA256']}"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("create", "verify"))
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--dmg", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        if args.action == "create":
            create_manifest(args.manifest, args.repo_root, args.app, args.dmg)
        else:
            verify_manifest(args.manifest, args.repo_root, args.app, args.dmg)
    except (KeyError, OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"Release artifact provenance invalid: {error}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
