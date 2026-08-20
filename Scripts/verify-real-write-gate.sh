#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lumisync-real-write-gate.XXXXXX")"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

cd "$ROOT_DIR"

python3 - "$SCRATCH_DIR/swift-build" <<'PY'
import subprocess
import sys

command = [
    "swift", "test",
    "--scratch-path", sys.argv[1],
    "--filter", "KeyboardBacklightSafetyTests/testWriteCommandRemainsBlockedEvenWithBothExplicitFlags",
]
try:
    completed = subprocess.run(command, timeout=120)
except subprocess.TimeoutExpired:
    print("real-write gate: focused XCTest exceeded 120 seconds", file=sys.stderr)
    raise SystemExit(124)
raise SystemExit(completed.returncode)
PY

grep -Fq \
    'keyboardBacklight: UnavailableKeyboardBacklightController()' \
    Apps/LumiSyncApp/LumiSyncApp.swift

grep -Fq \
    'throw ParseError.writeTestBlocked' \
    Sources/LumiSyncKeyboardProbe/KeyboardBacklightCommand.swift

helper_sources=(
    Sources/LumiSyncBacklightControllerCLI
    Sources/LumiSyncBacklightSupervisorCLI
    Sources/LumiSyncBacklightWriterCLI
)
if grep -RInE \
    'CoreBrightness|KeyboardBrightnessClient|setBrightness[[:space:]]*\(' \
    "${helper_sources[@]}"; then
    echo "real-write gate: helper CLI sources must not reference CoreBrightness or a real setter" >&2
    exit 1
fi

if grep -InE \
    'CoreBrightness|KeyboardBrightnessClient|lumisync-backlight-(controller|supervisor|writer)' \
    Apps/LumiSyncApp/LumiSyncApp.swift; then
    echo "real-write gate: production App must not expose a real-write executable path" >&2
    exit 1
fi

echo "real-write gate: PASS (focused guard executed; production writes remain unreachable)"
