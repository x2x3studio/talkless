#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
JOBS="${JOBS:-6}"
APP="$ROOT/dist/Talkless.app"

if [[ "$(uname -m)" != arm64 ]]; then
    printf '%s\n' 'Local Qwen requires Apple Silicon. Build on an arm64 Mac.' >&2
    exit 1
fi
# Swift 6.4's native backend is used because the default backend currently fails
# to compile MLX Metal shaders. The explicit Metal step below supplies them.
swift build --package-path "$ROOT" --build-system native -c "$CONFIGURATION" \
    --product Talkless -j "$JOBS" --disable-automatic-resolution
BIN="$(swift build --package-path "$ROOT" --build-system native -c "$CONFIGURATION" --show-bin-path)"
# Native SwiftPM assumes a command-line executable. Make its generated accessors
# look in the signed app's Resources directory as well. Upstream sources stay intact.
python3 -I - "$BIN" <<'PY'
from pathlib import Path
import sys
for path in Path(sys.argv[1]).glob("*.build/DerivedSources/resource_bundle_accessor.swift"):
    original = path.read_text()
    updated = original.replace("Bundle.main.bundleURL.appendingPathComponent", "(Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent")
    if updated != original:
        path.write_text(updated)
PY
swift build --package-path "$ROOT" --build-system native -c "$CONFIGURATION" \
    --product Talkless -j "$JOBS" --disable-automatic-resolution
python3 -I "$ROOT/scripts/build-metal.py" "$ROOT"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Talkless" "$APP/Contents/MacOS/Talkless"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
python3 -I "$ROOT/scripts/configure-bundle.py" "$APP/Contents/Info.plist"
SPARKLE_FRAMEWORK="$(find "$ROOT/.build/artifacts" -type d -path '*/macos-arm64_x86_64/Sparkle.framework' -print -quit)"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
    printf '%s\n' 'Sparkle framework not found; resolve package dependencies first.' >&2
    exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
# SwiftPM links the binary framework; the standalone app needs its own relative runpath.
if ! otool -l "$APP/Contents/MacOS/Talkless" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/Talkless"
fi
# MLX first searches next to the executable; keep a real file, not a development symlink.
cp "$ROOT/.build/metal/mlx.metallib" "$APP/Contents/MacOS/mlx.metallib"
cp "$ROOT/.build/metal/mlx.metallib" "$BIN/mlx.metallib"
# Preserve any SwiftPM resources used by transitive dependencies.
for bundle in "$BIN"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done
plutil -lint "$APP/Contents/Info.plist"

# Supply a persistent Developer ID/Apple Development identity to preserve TCC
# identity across rebuilds. Ad-hoc signatures work locally but may need reapproval.
IDENTITY="${CODE_SIGN_IDENTITY:--}"
SIGN_ARGS=(--force --sign "$IDENTITY")
if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then
    SIGN_ARGS+=(--keychain "$SIGNING_KEYCHAIN")
fi
if [[ "$IDENTITY" != - ]]; then
    SIGN_ARGS+=(--timestamp --options runtime)
fi
# Sign nested Sparkle services inside-out, without blanket --deep signing.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
while IFS= read -r -d '' service; do
    codesign "${SIGN_ARGS[@]}" "$service"
done < <(find "$FRAMEWORK" -type d \( -name '*.xpc' -o -name '*.app' \) -depth -print0)
if [[ -f "$FRAMEWORK/Versions/B/Autoupdate" ]]; then
    codesign "${SIGN_ARGS[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
fi
codesign "${SIGN_ARGS[@]}" "$FRAMEWORK"
codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/mlx.metallib"
if [[ "$IDENTITY" == - ]]; then
    codesign "${SIGN_ARGS[@]}" --identifier com.x2x3studio.talkless "$APP"
    printf '%s\n' 'Signed ad-hoc. Rebuilds may require reauthorizing Accessibility and Microphone access.'
else
    codesign "${SIGN_ARGS[@]}" --identifier com.x2x3studio.talkless \
        --entitlements "$ROOT/Resources/Talkless.entitlements" "$APP"
fi
codesign --verify --deep --strict "$APP"
printf '\nBuilt %s\nLaunch: open "%s"\n' "$APP" "$APP"
