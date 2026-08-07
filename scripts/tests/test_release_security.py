#!/usr/bin/env python3
"""Focused regression tests for local release-chain trust boundaries."""

from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[2]
BUILD_SCRIPT = ROOT_DIR / "build_dmg.sh"
MANIFEST_SCRIPT = ROOT_DIR / "scripts" / "release_artifact_manifest.py"
SETUP_SCRIPT = ROOT_DIR / "scripts" / "setup_release_python.sh"
REQUIREMENTS = ROOT_DIR / "scripts" / "requirements-release.txt"


class BuildEnvironmentTests(unittest.TestCase):
    def make_project(self, root: Path) -> Path:
        script = root / "build_dmg.sh"
        shutil.copy2(BUILD_SCRIPT, script)
        archive = root / "SimpleRecorder" / "ThirdParty" / "lame" / "lame-3.100.tar.gz"
        archive.parent.mkdir(parents=True)
        archive.write_bytes(b"not-the-release-archive")
        return script

    def run_script(self, script: Path, cwd: Path) -> subprocess.CompletedProcess[str]:
        environment = {
            "HOME": os.environ.get("HOME", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "RELEASE": "0",
            "PUBLISH_GITHUB_RELEASE": "0",
        }
        return subprocess.run(
            ["/bin/bash", str(script)],
            cwd=cwd,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_caller_working_directory_env_is_not_loaded(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            temporary = Path(raw)
            project = temporary / "project"
            caller = temporary / "caller"
            project.mkdir()
            caller.mkdir()
            script = self.make_project(project)
            (caller / ".env").write_text("RELEASE=not-a-boolean\n", encoding="utf-8")

            result = self.run_script(script, caller)

            self.assertEqual(result.returncode, 1)
            self.assertIn("LAME 源码包 SHA-256 不匹配", result.stderr)
            self.assertNotIn("RELEASE must be a boolean", result.stderr)

    def test_project_env_allows_release_flags(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            project = Path(raw)
            script = self.make_project(project)
            (project / ".env").write_text("RELEASE=not-a-boolean\n", encoding="utf-8")

            result = self.run_script(script, project)

            self.assertEqual(result.returncode, 2)
            self.assertIn("RELEASE must be a boolean", result.stderr)

    def test_project_env_cannot_replace_command_search_path(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            temporary = Path(raw)
            project = temporary / "project"
            fake_bin = temporary / "fake-bin"
            marker = temporary / "unexpected-shasum-call"
            project.mkdir()
            fake_bin.mkdir()
            script = self.make_project(project)
            fake_shasum = fake_bin / "shasum"
            fake_shasum.write_text(
                f"#!/bin/sh\n/usr/bin/touch '{marker}'\nexit 0\n",
                encoding="utf-8",
            )
            fake_shasum.chmod(0o755)
            (project / ".env").write_text(f"PATH={fake_bin}\n", encoding="utf-8")

            result = self.run_script(script, project)

            self.assertEqual(result.returncode, 1)
            self.assertIn("已忽略 .env 中不支持的变量: PATH", result.stderr)
            self.assertFalse(marker.exists())


class ReleasePythonContractTests(unittest.TestCase):
    def test_release_python_is_fresh_isolated_and_hash_locked(self) -> None:
        setup = SETUP_SCRIPT.read_text(encoding="utf-8")
        requirements = REQUIREMENTS.read_text(encoding="utf-8")

        self.assertIn('PYTHON_BIN="/usr/bin/python3"', setup)
        self.assertIn('mktemp -d "$ROOT_DIR/build/release-venv.XXXXXX"', setup)
        self.assertIn("--isolated", setup)
        self.assertIn("--only-binary=:all:", setup)
        self.assertIn("--require-hashes", setup)
        self.assertNotIn("${PYTHON_BIN:-", setup)
        self.assertNotIn("${RELEASE_VENV_DIR:-", setup)

        expected_hashes = {
            "ec5e529fb80935c94fe7b729f9972b50e351a0e6b50aa294fd5cabb109fcc29a",
            "de8dad4425a6ca6e4e5e297b27b5c824ecc7581910bf9aee86cb6835e6812aa7",
            "e5c6e8d3fbad53479cab09ac03729e0a9faf2bee3db8208a550daf5af81a5934",
            "481caa481374e813c1b176ada14e97f1f67a4539ce9cfeb3f350d78d6370c2e8",
        }
        self.assertEqual(
            {line.split("sha256:", 1)[1] for line in requirements.splitlines() if "sha256:" in line},
            expected_hashes,
        )


class ReleaseArtifactManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.repo = Path(self.temporary.name)
        self.run_git("init", "-q")
        self.run_git("config", "user.email", "release-test@example.invalid")
        self.run_git("config", "user.name", "Release Test")
        (self.repo / ".gitignore").write_text("build/\n", encoding="utf-8")
        (self.repo / "source.txt").write_text("source-v1\n", encoding="utf-8")
        self.run_git("add", ".gitignore", "source.txt")
        self.run_git("commit", "-q", "-m", "fixture")

        self.app = self.repo / "build" / "Release" / "SimpleRecorder.app"
        executable = self.app / "Contents" / "MacOS" / "SimpleRecorder"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"release-executable")
        info = {
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "123",
        }
        with (self.app / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)
        self.dmg = self.repo / "build" / "MeetingRecorderPro.dmg"
        self.dmg.write_bytes(b"release-dmg")
        self.manifest = self.repo / "build" / "release-artifact-manifest.json"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_git(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/usr/bin/git", "-C", str(self.repo), *args],
            text=True,
            capture_output=True,
            check=True,
        )

    def run_manifest(self, action: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(MANIFEST_SCRIPT),
                action,
                "--manifest",
                str(self.manifest),
                "--repo-root",
                str(self.repo),
                "--app",
                str(self.app),
                "--dmg",
                str(self.dmg),
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_matching_clean_artifacts_are_accepted(self) -> None:
        self.assertEqual(self.run_manifest("create").returncode, 0)
        result = self.run_manifest("verify")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Release artifact manifest valid", result.stdout)

    def test_changed_app_is_rejected(self) -> None:
        self.assertEqual(self.run_manifest("create").returncode, 0)
        executable = self.app / "Contents" / "MacOS" / "SimpleRecorder"
        executable.write_bytes(b"different-executable")

        result = self.run_manifest("verify")

        self.assertEqual(result.returncode, 1)
        self.assertIn("App executable SHA-256 does not match", result.stderr)

    def test_new_source_commit_is_rejected(self) -> None:
        self.assertEqual(self.run_manifest("create").returncode, 0)
        (self.repo / "source.txt").write_text("source-v2\n", encoding="utf-8")
        self.run_git("add", "source.txt")
        self.run_git("commit", "-q", "-m", "new source")

        result = self.run_manifest("verify")

        self.assertEqual(result.returncode, 1)
        self.assertIn("Git commit does not match", result.stderr)

    def test_dirty_source_tree_cannot_create_manifest(self) -> None:
        (self.repo / "source.txt").write_text("uncommitted source\n", encoding="utf-8")

        result = self.run_manifest("create")

        self.assertEqual(result.returncode, 1)
        self.assertIn("Git worktree is not clean", result.stderr)


if __name__ == "__main__":
    unittest.main()
