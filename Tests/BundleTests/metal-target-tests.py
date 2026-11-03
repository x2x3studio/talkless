#!/usr/bin/env python3
"""Compile a tiny shader with the production script; never load models or alter installed apps."""
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="talkless-metal-target-") as temporary:
    root = Path(temporary)
    source = root / ".build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
    source.mkdir(parents=True)
    (root / "Resources").mkdir()
    minimum = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())["LSMinimumSystemVersion"]
    assert minimum == "26.0", "Update the expected Metal compatibility baseline when changing supported macOS"
    (root / "Resources/Info.plist").write_bytes(plistlib.dumps({"LSMinimumSystemVersion": minimum}))
    (source / "probe.metal").write_text("#include <metal_stdlib>\nusing namespace metal;\nkernel void probe(device float* x [[buffer(0)]], uint i [[thread_position_in_grid]]) { x[i] += 1; }\n")
    output = root / ".build/metal"
    output.mkdir()
    # Simulate the old cache key that omitted the deployment target.
    version = subprocess.check_output(["xcrun", "-sdk", "macosx", "metal", "--version"], text=True)
    (output / "compiler-version.txt").write_text(version)
    (output / "mlx.metallib").write_bytes(b"old incompatible library")
    def build():
        subprocess.run(["bash", str(ROOT / "scripts/build-metal.sh"), str(root)], check=True, timeout=60)
    build()
    library = output / "mlx.metallib"
    assert library.read_bytes()[:4] == b"MTLB"
    key = (output / "compiler-version.txt").read_text()
    assert "-mmacosx-version-min=26.0" in key
    versions = subprocess.check_output(["xcrun", "metal-objdump", "--metallib", "--air-version", str(library)], text=True)
    assert "probe: 2.8" in versions, versions
    stamp = library.stat().st_mtime_ns
    build()
    assert library.stat().st_mtime_ns == stamp, "Matching deployment target should reuse cached shaders"
print("PASS Metal targets macOS 26, invalidates the old cache, and reuses a matching cache")
