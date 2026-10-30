#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/talkless-activity-view-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/TalklessActivityPreview.app"
mkdir -p "$APP/Contents/MacOS"
printf '%s' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>activity-view-tests</string><key>CFBundleIdentifier</key><string>local.talkless.activity-preview</string><key>CFBundleName</key><string>Talkless Activity Preview</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>' > "$APP/Contents/Info.plist"
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/Talkless/L10n.swift" \
  "$ROOT/Sources/Talkless/DictationActivity.swift" \
  "$ROOT/Sources/Talkless/DictationActivityView.swift" \
  "$ROOT/Tests/ActivityViewTests/ActivityViewTests.swift" \
  -o "$APP/Contents/MacOS/activity-view-tests"
"$APP/Contents/MacOS/activity-view-tests" "$@"
