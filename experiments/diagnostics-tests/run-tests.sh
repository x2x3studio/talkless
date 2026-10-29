#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/talkless-diagnostics-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -swift-version 6 \
  "$ROOT/Sources/Talkless/Diagnostics.swift" \
  "$ROOT/experiments/diagnostics-tests/main.swift" \
  -o "$WORK/diagnostics-tests"
"$WORK/diagnostics-tests" "$WORK/fixtures"
