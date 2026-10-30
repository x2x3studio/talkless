#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/talkless-caret-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
xcrun swiftc -swift-version 6 \
  "$ROOT/Sources/Talkless/CaretPosition.swift" \
  "$ROOT/Tests/CaretTests/main.swift" \
  -o "$BUILD/caret-tests"
"$BUILD/caret-tests"
