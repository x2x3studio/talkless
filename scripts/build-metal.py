#!/usr/bin/env python3
"""Build MLX Metal resources for native SwiftPM builds (Xcode Metal Toolchain required)."""
import concurrent.futures
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
source = root / ".build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
output = root / ".build/metal"
output.mkdir(parents=True, exist_ok=True)
files = sorted(source.rglob("*.metal"))
if not files:
    raise SystemExit("MLX shaders not found; run the native Swift build first.")

# Include changes invalidate every shader, not just directly edited .metal files.
inputs = [p for p in source.rglob("*") if p.is_file()]
newest_input = max(p.stat().st_mtime for p in inputs)
compiler = subprocess.check_output(["xcrun", "-sdk", "macosx", "metal", "--version"], text=True)
stamp = output / "compiler-version.txt"
compiler_changed = not stamp.exists() or stamp.read_text() != compiler


def compile_shader(path):
    destination = output / (str(path.relative_to(source)).replace("/", "_") + ".air")
    if compiler_changed or not destination.exists() or destination.stat().st_mtime < newest_input:
        subprocess.run([
            "xcrun", "-sdk", "macosx", "metal", "-std=metal3.1", "-O2",
            "-I", str(source), "-c", str(path), "-o", str(destination),
        ], check=True)
    return destination


with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    objects = list(pool.map(compile_shader, files))
library = output / "mlx.metallib"
if compiler_changed or not library.exists() or any(p.stat().st_mtime > library.stat().st_mtime for p in objects):
    subprocess.run(["xcrun", "-sdk", "macosx", "metallib", *map(str, objects), "-o", str(library)], check=True)
stamp.write_text(compiler)
print(f"MLX Metal library: {library} ({len(files)} shaders)")
