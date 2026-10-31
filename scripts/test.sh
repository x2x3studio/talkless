#!/bin/bash
# Model-free test suite (no microphone, models, network or real credentials).
#
#   scripts/test.sh                 run every suite
#   scripts/test.sh dictionary hud  run suites whose name contains any of these words
#   TALKLESS_TEST_VERBOSE=1 ...     stream each suite's full output
#
# Every selected suite runs even after a failure; the summary lists failures and the
# script exits nonzero if any failed. A failed suite prints the end of its output.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# name|command — prefer Tests/TalklessTests (swift test) for new tests; the scripts below
# compile selected sources with fakes and are kept where that isolation is the point.
SUITES=(
  "unit|swift test --package-path '$ROOT'"
  "localization|bash '$ROOT/Tests/LocalizationTests/run-tests.sh'"
  "translation-flow|python3 -I '$ROOT/Tests/TranslationFlowTests/run-tests.py'"
  "qwen-state|swift '$ROOT/Tests/NativeTests/run-qwen-state-tests.swift'"
  "qwen-output|swift '$ROOT/Tests/NativeTests/run-qwen-output-tests.swift'"
  "models|bash '$ROOT/Tests/ModelTests/run-tests.sh'"
  "api|bash '$ROOT/Tests/APITests/run-tests.sh'"
  "polish-validation|bash '$ROOT/Tests/PolishIntegration/test-validation.sh'"
  "provider-settings|bash '$ROOT/Tests/ProviderSettingsTests/run-tests.sh'"
  "dictionary|bash '$ROOT/Tests/DictionaryTests/run-tests.sh'"
  "activity|bash '$ROOT/Tests/ActivityTests/run-tests.sh'"
  "activity-view|bash '$ROOT/Tests/ActivityViewTests/run-tests.sh'"
  "updates|bash '$ROOT/Tests/UpdateTests/run-tests.sh'"
  "hud|swift '$ROOT/Tests/NativeTests/run-quiet-hud-tests.swift'"
  "menu-icon|swift '$ROOT/Tests/NativeTests/run-menu-icon-tests.swift'"
  "menu|bash '$ROOT/Tests/MenuTests/run-tests.sh'"
  "launch-at-login|bash '$ROOT/Tests/LaunchAtLoginTests/run-tests.sh'"
  "setup-guide|bash '$ROOT/Tests/SetupGuideTests/run-tests.sh'"
  "setup-guide-view|bash '$ROOT/Tests/SetupGuideViewTests/run-tests.sh'"
  "about-settings|bash '$ROOT/Tests/AboutSettingsTests/run-tests.sh'"
  "processing-hud|python3 -I '$ROOT/Tests/NativeTests/run-processing-hud-tests.py'"
  "audio|python3 -I '$ROOT/Tests/AudioTests/run-tests.py'"
  "hotkeys|python3 -I '$ROOT/Tests/HotkeyTests/run-tests.py'"
  "shortcut-recorder|python3 -I '$ROOT/Tests/ShortcutRecorderTests/run-tests.py'"
  "diagnostics|bash '$ROOT/Tests/DiagnosticsTests/run-tests.sh'"
  "release-tool|swift test --package-path '$ROOT/Tools/ReleaseTool'"
  "bundle|python3 -I '$ROOT/Tests/BundleTests/run-tests.py'"
)

# With no filter words every suite runs; otherwise a suite runs if its name contains one.
selected() {
  local name="$1"; shift
  (( $# == 0 )) && return 0
  for word in "$@"; do [[ "$name" == *"$word"* ]] && return 0; done
  return 1
}

failed=()
passed=0
started=$SECONDS
for suite in "${SUITES[@]}"; do
  name="${suite%%|*}"
  command="${suite#*|}"
  selected "$name" "$@" || continue
  suite_started=$SECONDS
  # Each suite runs in a subshell so one cannot end the run (e.g. with exit).
  log="$(mktemp "${TMPDIR:-/tmp}/talkless-test-$name.XXXXXX")"
  if [[ "${TALKLESS_TEST_VERBOSE:-}" == 1 ]]; then
    ( eval "$command" ) 2>&1 | tee "$log"; status=${PIPESTATUS[0]}
  else
    ( eval "$command" ) > "$log" 2>&1; status=$?
  fi
  if (( status == 0 )); then
    passed=$((passed + 1))
    printf '✓ %-18s %3ss\n' "$name" "$((SECONDS - suite_started))"
  else
    failed+=("$name")
    printf '✗ %-18s %3ss  (exit %s)\n' "$name" "$((SECONDS - suite_started))" "$status"
    [[ "${TALKLESS_TEST_VERBOSE:-}" == 1 ]] || tail -n 40 "$log" | sed 's/^/    /'
  fi
  rm -f "$log"
done

total=$((passed + ${#failed[@]}))
if (( total == 0 )); then
  echo "No suite matches: $*" >&2
  exit 2
fi
echo "$passed/$total suites passed in $((SECONDS - started))s."
if (( ${#failed[@]} )); then
  echo "Failed: ${failed[*]}" >&2
  exit 1
fi
