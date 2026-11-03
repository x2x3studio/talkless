#!/bin/bash
set -euo pipefail
ROOT="${1:?Usage: build-metal.sh PROJECT_ROOT}"
SOURCE="$ROOT/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
OUTPUT="$ROOT/.build/metal"
[[ -d "$SOURCE" ]] || { printf '%s\n' 'MLX shaders not found; build the package first.' >&2; exit 1; }
mkdir -p "$OUTPUT"
MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/Resources/Info.plist")"
[[ "$MINIMUM_OS" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { printf '%s\n' 'Invalid minimum macOS version.' >&2; exit 1; }
METAL_FLAGS=(-std=metal3.1 "-mmacosx-version-min=$MINIMUM_OS" -O2)
VERSION="$(xcrun -sdk macosx metal --version)
flags: ${METAL_FLAGS[*]}"
REBUILD=false
[[ -f "$OUTPUT/compiler-version.txt" && "$(<"$OUTPUT/compiler-version.txt")" == "$VERSION" ]] || REBUILD=true
if [[ ! -f "$OUTPUT/mlx.metallib" ]] || [[ -n "$(find "$SOURCE" -type f -newer "$OUTPUT/mlx.metallib" -print -quit 2>/dev/null)" ]]; then
    REBUILD=true
fi
if [[ "$REBUILD" == true ]]; then
    objects=()
    pids=()
    while IFS= read -r -d '' file; do
        relative="${file#"$SOURCE/"}"
        target="$OUTPUT/${relative//\//_}.air"
        xcrun -sdk macosx metal "${METAL_FLAGS[@]}" -I "$SOURCE" -c "$file" -o "$target" &
        pids+=("$!")
        objects+=("$target")
        if [[ ${#pids[@]} -eq 4 ]]; then
            for pid in "${pids[@]}"; do wait "$pid"; done
            pids=()
        fi
    done < <(find "$SOURCE" -name '*.metal' -type f -print0)
    for pid in "${pids[@]}"; do wait "$pid"; done
    [[ ${#objects[@]} -gt 0 ]] || { printf '%s\n' 'No Metal shaders found.' >&2; exit 1; }
    xcrun -sdk macosx metallib "${objects[@]}" -o "$OUTPUT/mlx.metallib"
    printf '%s\n' "$VERSION" > "$OUTPUT/compiler-version.txt"
fi
printf 'MLX Metal library: %s\n' "$OUTPUT/mlx.metallib"
