#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/talkless-setup-view-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/TalklessSetupPreview.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -R "$ROOT/Sources/Talkless/Resources" "$APP/Contents/Resources/Talkless_Talkless.bundle"
printf '%s' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>setup-view-tests</string><key>CFBundleIdentifier</key><string>local.talkless.setup-preview</string><key>CFBundleName</key><string>Talkless Setup Preview</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>' > "$APP/Contents/Info.plist"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -sdk "$SDK" -swift-version 6 -parse-as-library \
  "$ROOT/Sources/Talkless/L10n.swift" \
  "$ROOT/Sources/Talkless/LaunchAtLogin.swift" \
  "$ROOT/Sources/Talkless/LaunchAtLoginSettingsView.swift" \
  "$ROOT/Sources/Talkless/SetupGuideView.swift" \
  "$ROOT/Sources/Talkless/SetupGuideLiveView.swift" \
  "$ROOT/Tests/SetupGuideViewTests/SetupGuideViewTests.swift" \
  -o "$APP/Contents/MacOS/setup-view-tests"
"$APP/Contents/MacOS/setup-view-tests" "$@"
