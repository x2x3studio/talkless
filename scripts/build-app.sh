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
# Metal libraries in MacOS are nested code and must be signed before the app.
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/mlx.metallib"
if [[ "$IDENTITY" == - ]]; then
    codesign --force --sign - --identifier com.x2x3studio.talkless "$APP"
    printf '%s\n' 'Signed ad-hoc (no signing identity specified). After rebuilds, macOS may require removing/re-adding Talkless in Privacy & Security > Accessibility and re-granting Microphone access.'
else
    codesign --force --sign "$IDENTITY" --identifier com.x2x3studio.talkless \
        --options runtime --entitlements "$ROOT/Resources/Talkless.entitlements" "$APP"
fi
codesign --verify --deep --strict "$APP"
printf '\nBuilt %s\nLaunch: open "%s"\n' "$APP" "$APP"
