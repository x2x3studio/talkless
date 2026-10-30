#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/talkless-update-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# Build a network-free Sparkle substitute, then compile the complete production controller.
xcrun swiftc -swift-version 6 -emit-library -emit-module -module-name Sparkle \
  "$ROOT/Tests/UpdateTests/FakeSparkle.swift" \
  -emit-module-path "$WORK/Sparkle.swiftmodule" -o "$WORK/libSparkle.dylib"
xcrun swiftc -swift-version 6 -parse-as-library -I "$WORK" -L "$WORK" -lSparkle \
  -Xlinker -rpath -Xlinker "$WORK" \
  "$ROOT/Sources/Talkless/L10n.swift" \
  "$ROOT/Sources/Talkless/UpdateController.swift" \
  "$ROOT/Tests/UpdateTests/UpdateTests.swift" -o "$WORK/update-tests"
"$WORK/update-tests" "$WORK/fixtures"
# Check the production API against the pinned framework when already resolved locally.
# Never resolve/download dependencies as part of this offline suite.
FRAMEWORKS="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
if [ -d "$FRAMEWORKS/Sparkle.framework" ]; then
  xcrun swiftc -swift-version 6 -typecheck -F "$FRAMEWORKS" \
    "$ROOT/Sources/Talkless/L10n.swift" \
    "$ROOT/Sources/Talkless/UpdateController.swift"
  printf '%s\n' 'PASS typecheck against the real pinned Sparkle framework'
else
  printf '%s\n' 'SKIP real Sparkle typecheck: cached framework is not present (covered by app build)'
fi
