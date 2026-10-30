#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/talkless-setup-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -sdk "$SDK" -swift-version 6 -parse-as-library \
  "$ROOT/Sources/Talkless/SetupGuideState.swift" \
  "$ROOT/Tests/SetupGuideTests/SetupGuideTests.swift" \
  -o "$WORK/setup-guide-tests"
"$WORK/setup-guide-tests"
python3 -I - "$ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
source = (root / "Sources/Talkless/App.swift").read_text()
initialization = source.split("override init() {", 1)[1].split("func applicationDidFinishLaunching", 1)[0]
assert initialization.index("SetupGuideController.shared") < initialization.index("controller = DictationController()")
assert initialization.index("guide.beginFirstLaunchIfNeeded()") < initialization.index("controller = DictationController()")
assert initialization.index("guide.beginFirstLaunchIfNeeded()") < initialization.index("settings = AppSettings.shared")
assert "DictationController.requestAccessibility()" not in source
assert "AVCaptureDevice.requestAccess" not in source
assert "if !DictationController.accessibilityGranted || !controller.activateHotkey()" in source
assert "if setupGuide.shouldPresentOnLaunch { openSetupGuide() }" in source
assert "if setupGuide.isPresented { setupGuide.skip() }" in source
assert "publisher(for: .showSetupGuide)" in source
startup_permission = source.split("// Startup only checks permission", 1)[1].split("if setupGuide.shouldPresentOnLaunch", 1)[0]
assert startup_permission.count('record(event: "permission_blocked"') == 1
assert startup_permission.index('record(event: "permission_blocked"') < startup_permission.index("permissionTimer =")
assert '"permission": "accessibility", "reason": "denied", "stage": "startup"' in startup_permission
live = (root / "Sources/Talkless/SetupGuideLiveView.swift").read_text()
assert 'shortcutsReady: controller.hotkeyActive' in live
view = (root / "Sources/Talkless/SetupGuideView.swift").read_text()
assert 'summaryRow("Accessibility", ready: snapshot.accessibility == .granted)' in view
assert 'summaryRow("Dictation shortcuts", ready: snapshot.shortcutsReady)' in view
print("PASS startup logs blocked AX once, guide preserves AX permission separately from shortcut readiness")
print("PASS App startup captures first-run before settings, prompts only on user action, and wires reopen/close")
PY
