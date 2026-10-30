#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/talkless-api-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/Talkless/L10n.swift" \
  "$ROOT/Sources/Talkless/LLMProtocol.swift" \
  "$ROOT/Sources/Talkless/PolishProvider.swift" \
  "$ROOT/Sources/Talkless/LLMAPITransport.swift" \
  "$ROOT/Sources/Talkless/LLMClient.swift" \
  "$ROOT/Sources/Talkless/AudioInputDevice.swift" \
  "$ROOT/Sources/Talkless/AudioRecorder.swift" \
  "$ROOT/Sources/Talkless/Transcription.swift" \
  "$ROOT/Tests/APITests/APITests.swift" \
  -o "$WORK/api-tests"
TALKLESS_TEST_EXPECTED_VERSION=0.1.0 "$WORK/api-tests"

# Exercise Bundle.main in an actual app layout as well as the development fallback.
# Deliberately distinguish short version from build number and the documented example.
APP="$WORK/APITests.app/Contents"
mkdir -p "$APP/MacOS"
cp "$WORK/api-tests" "$APP/MacOS/api-tests"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<plist version="1.0"><dict>' \
  '<key>CFBundleIdentifier</key><string>test.talkless.api</string>' \
  '<key>CFBundleExecutable</key><string>api-tests</string>' \
  '<key>CFBundlePackageType</key><string>APPL</string>' \
  '<key>CFBundleShortVersionString</key><string>2099.1231.98765</string>' \
  '<key>CFBundleVersion</key><string>42</string>' \
  '</dict></plist>' > "$APP/Info.plist"
TALKLESS_TEST_EXPECTED_VERSION=2099.1231.98765 "$APP/MacOS/api-tests"
