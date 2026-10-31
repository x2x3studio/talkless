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
# Build the owned compiler adapter before setting SWIFT_EXEC (never wrap itself).
if [[ -z "${TALKLESS_RELEASE_TOOL:-}" ]]; then
    swift build --package-path "$ROOT/Tools/ReleaseTool" --build-system native -c release
    TOOL_BIN="$(swift build --package-path "$ROOT/Tools/ReleaseTool" --build-system native -c release --show-bin-path)"
    export TALKLESS_RELEASE_TOOL="$TOOL_BIN/ReleaseTool"
fi
# A unique compiler identity also invalidates old unadapted SwiftPM objects.
# No personal paths in the compiler's location or generated replacement sources.
COMPILER_STAGE="$(mktemp -d /tmp/talkless-compiler.XXXXXX)"
trap 'rm -rf "$COMPILER_STAGE"' EXIT
mkdir -p "$COMPILER_STAGE/bin" "$COMPILER_STAGE/inputs"
cp "$TALKLESS_RELEASE_TOOL" "$COMPILER_STAGE/bin/swiftc"
REAL_SWIFTC="$(xcrun --find swiftc)"
BUILD_FLAGS=()
for prefix in "$ROOT" "$HOME" "$COMPILER_STAGE" "$(cd "$COMPILER_STAGE" && pwd -P)"; do
    BUILD_FLAGS+=(-Xswiftc -debug-prefix-map -Xswiftc "$prefix=/source")
    BUILD_FLAGS+=(-Xswiftc -file-prefix-map -Xswiftc "$prefix=/source")
    BUILD_FLAGS+=(-Xcc "-fdebug-prefix-map=$prefix=/source" -Xcc "-ffile-prefix-map=$prefix=/source")
    BUILD_FLAGS+=(-Xcxx "-fdebug-prefix-map=$prefix=/source" -Xcxx "-ffile-prefix-map=$prefix=/source")
done
BUILD_FLAGS+=(-Xlinker -oso_prefix -Xlinker "$ROOT/")
# Native SwiftPM avoids the current MLX shader issue in the default backend.
# The adapter substitutes app-aware inputs at the actual compiler invocation;
# SwiftPM DerivedSources and dependency checkouts are never patched.
SWIFT_EXEC="$COMPILER_STAGE/bin/swiftc" TALKLESS_RESOURCE_COMPILER=1 \
    TALKLESS_REAL_SWIFTC="$REAL_SWIFTC" TALKLESS_RESOURCE_INPUTS="$COMPILER_STAGE/inputs" \
    swift build --package-path "$ROOT" --build-system native -c "$CONFIGURATION" \
    --product Talkless -j "$JOBS" --disable-automatic-resolution "${BUILD_FLAGS[@]}"
BIN="$(swift build --package-path "$ROOT" --build-system native -c "$CONFIGURATION" --show-bin-path)"
bash "$ROOT/scripts/build-metal.sh" "$ROOT"

# Start clean so removed bundles, signatures, or old root aliases cannot survive.
[[ ! -L "$APP" ]] || { printf '%s\n' 'App output must not be a symlink.' >&2; exit 1; }
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Talkless" "$APP/Contents/MacOS/Talkless"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
bash "$ROOT/scripts/release-tool.sh" configure-bundle "$APP/Contents/Info.plist"
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
# Preserve every transitive SwiftPM resource bundle and record its manifest.
bash "$ROOT/scripts/release-tool.sh" package-resources "$BIN" "$APP"
bash "$ROOT/scripts/release-tool.sh" prepare-app-executable "$APP/Contents/MacOS/Talkless"
# Permission prompts are localized by macOS from the main app, not the SwiftPM bundle.
for language in en zh-Hans; do
    # SwiftPM canonicalizes localization directory names to lowercase.
    PACKAGED_LANGUAGE="$(printf '%s' "$language" | tr '[:upper:]' '[:lower:]')"
    LOCALIZED="$APP/Contents/Resources/Talkless_Talkless.bundle/$PACKAGED_LANGUAGE.lproj/Localizable.strings"
    if [[ ! -f "$LOCALIZED" ]]; then
        printf 'Missing packaged localization: %s\n' "$LOCALIZED" >&2
        exit 1
    fi
    mkdir -p "$APP/Contents/Resources/$language.lproj"
    cp "$ROOT/Sources/Talkless/Resources/$language.lproj/InfoPlist.strings" \
        "$APP/Contents/Resources/$language.lproj/InfoPlist.strings"
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
bash "$ROOT/scripts/release-tool.sh" verify-relocated-bundle "$APP" "$ROOT/.build" "$COMPILER_STAGE"
printf '\nBuilt %s\nLaunch: open "%s"\n' "$APP" "$APP"
