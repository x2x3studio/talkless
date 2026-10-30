#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 6 -parse-as-library "$ROOT/Sources/Talkless/PolishValidation.swift" \
  "$ROOT/Tests/PolishIntegration/ValidationTests.swift" -o "$WORK/validation-tests"
"$WORK/validation-tests"
