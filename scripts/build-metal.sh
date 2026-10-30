#!/bin/bash
set -euo pipefail
ROOT="${1:?Usage: build-metal.sh PROJECT_ROOT}"
SOURCE="$ROOT/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
OUTPUT="$ROOT/.build/metal"
[[ -d "$SOURCE" ]] || { printf '%s\n' 'MLX shaders not found; build the package first.' >&2; exit 1; }
mkdir -p "$OUTPUT"
VERSION="$(xcrun -sdk macosx metal --version)"
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
        xcrun -sdk macosx metal -std=metal3.1 -O2 -I "$SOURCE" -c "$file" -o "$target" &
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
