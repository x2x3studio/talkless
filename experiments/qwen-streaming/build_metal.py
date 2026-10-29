#!/usr/bin/env python3
"""Supplement swift build -c release with Xcode's Metal shader compiler.
Run this from outside any raw download directory using python3 -I.
"""
from pathlib import Path
import concurrent.futures
import subprocess
import sys
import time

root = Path(sys.argv[1]).resolve()
source = root / ".build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
output = root / "metal-build"
output.mkdir(exist_ok=True)
started = time.monotonic()
files = sorted(source.rglob("*.metal"))
if not files:
    raise RuntimeError("No SwiftPM MLX generated Metal shaders found")

def compile_shader(path):
    destination = output / (str(path.relative_to(source)).replace("/", "_") + ".air")
    subprocess.run(["xcrun", "-sdk", "macosx", "metal", "-std=metal3.1", "-O2", "-I", str(source), "-c", str(path), "-o", str(destination)], check=True)
    return destination

with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    objects = list(pool.map(compile_shader, files))
library = output / "default.metallib"
subprocess.run(["xcrun", "-sdk", "macosx", "metallib", *map(str, objects), "-o", str(library)], check=True)
# Native SwiftPM output on the tested Apple Silicon host; MLX looks for
# colocated mlx.metallib before falling back to bundles or working directory.
product = root / ".build/arm64-apple-macosx/release/mlx.metallib"
product.parent.mkdir(parents=True, exist_ok=True)
if product.is_symlink():
    product.unlink()
if product.exists():
    raise RuntimeError(f"Refusing to replace existing library: {product}")
product.symlink_to(library)
print(f"Built {len(files)} Metal sources in {time.monotonic() - started:.3f}s: {library}; linked {product}")
