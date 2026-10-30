#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/talkless-activity-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/Talkless/History.swift" \
  "$ROOT/Sources/Talkless/DictationActivity.swift" \
  "$ROOT/Tests/ActivityTests/ActivityTests.swift" \
  -o "$WORK/activity-tests"
"$WORK/activity-tests"
