#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift "$ROOT/Tests/NativeTests/run-qwen-state-tests.swift"
swift "$ROOT/Tests/NativeTests/run-qwen-output-tests.swift"
bash "$ROOT/Tests/ModelTests/run-tests.sh"
bash "$ROOT/Tests/CaretTests/run-tests.sh"
swift "$ROOT/Tests/NativeTests/run-quiet-hud-tests.swift"
python3 -I "$ROOT/Tests/AudioTests/run-tests.py"
bash "$ROOT/Tests/DiagnosticsTests/run-tests.sh"
python3 -I "$ROOT/scripts/test-release-config.py"
python3 -I "$ROOT/scripts/test-release-version.py"
python3 -I "$ROOT/scripts/test-signing-session.py"
