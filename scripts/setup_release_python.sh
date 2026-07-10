#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
VENV_DIR="${RELEASE_VENV_DIR:-$ROOT_DIR/build/release-venv}"
REQUIREMENTS="$ROOT_DIR/scripts/requirements-release.txt"

if [[ ! -x "$PYTHON_BIN" ]]; then
    echo "Python not found: $PYTHON_BIN" >&2
    exit 1
fi

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

"$VENV_DIR/bin/python" -m pip install \
    --disable-pip-version-check \
    --requirement "$REQUIREMENTS"

"$VENV_DIR/bin/python" - <<'PY'
from cryptography import __version__

if __version__ != "49.0.0":
    raise SystemExit(f"unexpected cryptography version: {__version__}")
print(f"release Python ready: cryptography {__version__}")
PY
