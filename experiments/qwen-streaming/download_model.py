#!/usr/bin/env python3
"""Run with python3 -I; raw assets each enter a fresh empty directory."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.request

root = Path(sys.argv[1]).resolve()
model = root / "model"
model.mkdir(exist_ok=True)
raw = root / "downloads"
raw.mkdir(exist_ok=True)
repo = "mlx-community/Qwen3-ASR-1.7B-4bit"
started = time.monotonic()
with urllib.request.urlopen(f"https://huggingface.co/api/models/{repo}") as response:
    revision = json.load(response)["sha"]
files = ["config.json", "tokenizer_config.json", "vocab.json", "merges.txt", "preprocessor_config.json", "generation_config.json", "chat_template.json", "model.safetensors"]
receipt = {"model": repo, "revision": revision, "files": [], "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
for name in files:
    if (model / name).exists():
        raise RuntimeError(f"Refusing redundant download: {model / name}")
    destination = Path(tempfile.mkdtemp(prefix=name + "-", dir=raw)) / name
    before = time.monotonic()
    subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3", "--output", str(destination), f"https://huggingface.co/{repo}/resolve/{revision}/{name}"], check=True)
    elapsed = time.monotonic() - before
    if destination.stat().st_size == 0:
        raise RuntimeError("Empty download")
    digest = hashlib.file_digest(destination.open("rb"), "sha256").hexdigest()
    if name == "model.safetensors" and digest != "9848eaf7a5c1589c671b35035ac27b72e248dd0c604eacae547e7e403d29db45":
        raise RuntimeError("Model SHA256 mismatch")
    os.symlink(destination, model / name)
    entry = {"name": name, "bytes": destination.stat().st_size, "seconds": elapsed, "sha256": digest}
    receipt["files"].append(entry)
    print(json.dumps({"event": "download_file", **entry}), flush=True)
receipt["downloadSeconds"] = time.monotonic() - started
receipt["bytes"] = sum(f["bytes"] for f in receipt["files"])
(root / "download-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps({"event": "download_complete", **receipt}), flush=True)
