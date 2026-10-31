#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/talkless-menu-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/TalklessMenuPreview.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Match the shipped app layout; packaged lookup must not use checkout resources.
cp -R "$ROOT/Sources/Talkless/Resources" "$APP/Contents/Resources/Talkless_Talkless.bundle"
printf '%s' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>menu-tests</string><key>CFBundleIdentifier</key><string>local.talkless.menu-preview</string><key>CFBundleName</key><string>Talkless Menu Preview</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>' > "$APP/Contents/Info.plist"
# Compile the exact production display enums without AppSettings or its services.
python3 -I - "$ROOT/Sources/Talkless/Settings.swift" "$WORK/ShortcutDisplay.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
Path(sys.argv[2]).write_text('import Foundation\n' + source[source.index('enum TriggerKey:'):source.index('enum AlternateFinishKey:')])
PY
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/Talkless/L10n.swift" \
  "$WORK/ShortcutDisplay.swift" \
  "$ROOT/Sources/Talkless/MenuContent.swift" \
  "$ROOT/Tests/MenuTests/MenuTests.swift" \
  -o "$APP/Contents/MacOS/menu-tests"
"$APP/Contents/MacOS/menu-tests" "$@"
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/Talkless/L10n.swift" \
  "$ROOT/Sources/Talkless/ApplicationEditMenu.swift" \
  "$ROOT/Tests/MenuTests/ApplicationEditMenuTests.swift" \
  -o "$APP/Contents/MacOS/menu-tests"
"$APP/Contents/MacOS/menu-tests"
