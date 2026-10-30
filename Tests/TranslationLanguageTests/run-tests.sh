#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/talkless-translation-language-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/Talkless/L10n.swift" \
  "$ROOT/Sources/Talkless/TranslationLanguages.swift" \
  "$ROOT/Tests/TranslationLanguageTests/TranslationLanguageTests.swift" \
  -o "$WORK/translation-language-tests"
"$WORK/translation-language-tests"
# Compile the reusable native picker independently of the app/controller.
xcrun --sdk macosx swiftc -swift-version 6 -typecheck \
  "$ROOT/Sources/Talkless/L10n.swift" \
  "$ROOT/Sources/Talkless/TranslationLanguages.swift" \
  "$ROOT/Sources/Talkless/LanguagePickerView.swift"
