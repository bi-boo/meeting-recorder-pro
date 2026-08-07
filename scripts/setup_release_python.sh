#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON_BIN="/usr/bin/python3"
REQUIREMENTS="$ROOT_DIR/scripts/requirements-release.txt"
VENV_DIR=""
SETUP_COMPLETE=false

if [[ ! -x "$PYTHON_BIN" ]]; then
    echo "Python not found: $PYTHON_BIN" >&2
    exit 1
fi

cleanup_failed_setup() {
    if [[ "$SETUP_COMPLETE" != true && -n "$VENV_DIR" && "$VENV_DIR" == "$ROOT_DIR/build/release-venv."* ]]; then
        rm -rf -- "$VENV_DIR"
    fi
}
trap cleanup_failed_setup EXIT

mkdir -p "$ROOT_DIR/build"
VENV_DIR="$(mktemp -d "$ROOT_DIR/build/release-venv.XXXXXX")"

/usr/bin/env \
    -u PYTHONHOME \
    -u PYTHONPATH \
    -u PYTHONSTARTUP \
    -u PYTHONINSPECT \
    "$PYTHON_BIN" -I -m venv "$VENV_DIR"

/usr/bin/env \
    -u PYTHONHOME \
    -u PYTHONPATH \
    -u PYTHONSTARTUP \
    -u PYTHONINSPECT \
    "$VENV_DIR/bin/python" -I -m pip install \
    --isolated \
    --disable-pip-version-check \
    --no-cache-dir \
    --only-binary=:all: \
    --require-hashes \
    --index-url https://pypi.org/simple \
    --requirement "$REQUIREMENTS" >&2

/usr/bin/env \
    -u PYTHONHOME \
    -u PYTHONPATH \
    -u PYTHONSTARTUP \
    -u PYTHONINSPECT \
    "$VENV_DIR/bin/python" -I - <<'PY' >&2
from importlib.metadata import version

expected = {
    "cryptography": "49.0.0",
    "cffi": "2.0.0",
    "pycparser": "2.23",
    "typing-extensions": "4.16.0",
}
for package, expected_version in expected.items():
    actual_version = version(package)
    if actual_version != expected_version:
        raise SystemExit(
            f"unexpected {package} version: {actual_version}; expected {expected_version}"
        )
print("release Python ready: " + ", ".join(f"{name} {value}" for name, value in expected.items()))
PY

SETUP_COMPLETE=true
printf '%s\n' "$VENV_DIR/bin/python"
