#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/talkless-login-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/Talkless/L10n.swift" \
  "$ROOT/Sources/Talkless/LaunchAtLogin.swift" \
  "$ROOT/Sources/Talkless/LaunchAtLoginSettingsView.swift" \
  "$ROOT/Tests/LaunchAtLoginTests/LaunchAtLoginTests.swift" \
  -o "$WORK/launch-at-login-tests"
"$WORK/launch-at-login-tests"
