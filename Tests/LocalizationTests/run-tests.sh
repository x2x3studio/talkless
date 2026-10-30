#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/talkless-localization-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/Talkless/L10n.swift" \
  "$ROOT/Tests/LocalizationTests/LocalizationTests.swift" \
  -o "$WORK/localization-tests"
# Run away from the checkout to exercise the standalone source-relative resource lookup.
(cd "$WORK" && "$WORK/localization-tests" "$ROOT/Sources/Talkless")

# Exercise the SwiftPM branch with a relocatable bundle and SwiftPM's lowercase folders.
cp -R "$ROOT/Sources/Talkless/Resources" "$WORK/Talkless_Talkless.bundle"
mv "$WORK/Talkless_Talkless.bundle/zh-Hans.lproj" "$WORK/Talkless_Talkless.bundle/chinese-lproj"
mv "$WORK/Talkless_Talkless.bundle/chinese-lproj" "$WORK/Talkless_Talkless.bundle/zh-hans.lproj"
printf '%s\n' 'import Foundation' 'extension Bundle {' \
  '    static let module = Bundle(url: Bundle.main.bundleURL.appendingPathComponent("Talkless_Talkless.bundle"))!' \
  '}' > "$WORK/resource_bundle_accessor.swift"
xcrun --sdk macosx swiftc -swift-version 6 -D SWIFT_PACKAGE -parse-as-library \
  "$ROOT/Sources/Talkless/L10n.swift" "$WORK/resource_bundle_accessor.swift" \
  "$ROOT/Tests/LocalizationTests/LocalizationTests.swift" -o "$WORK/packaged-localization-tests"
(cd "$WORK" && "$WORK/packaged-localization-tests" "$ROOT/Sources/Talkless")
