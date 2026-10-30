#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/talkless-menu-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/TalklessMenuPreview.app"
mkdir -p "$APP/Contents/MacOS"
printf '%s' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>menu-tests</string><key>CFBundleIdentifier</key><string>local.talkless.menu-preview</string><key>CFBundleName</key><string>Talkless Menu Preview</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>' > "$APP/Contents/Info.plist"
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/Talkless/MenuContent.swift" \
  "$ROOT/Tests/MenuTests/MenuTests.swift" \
  -o "$APP/Contents/MacOS/menu-tests"
"$APP/Contents/MacOS/menu-tests" "$@"
