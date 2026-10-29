#!/usr/bin/env python3
"""Check tracked source for non-English prose and accidental local artifacts."""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
han_ranges = [(0x3400, 0x4DBF), (0x4E00, 0x9FFF), (0xF900, 0xFAFF), (0x20000, 0x323AF)]
han = re.compile("[" + "".join(chr(start) + "-" + chr(end) for start, end in han_ranges) + "]")
private_key = re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")
credential = re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk-[A-Za-z0-9_-]{32,}|AKIA[A-Z0-9]{16})\b")
forbidden_suffixes = {".safetensors", ".gguf", ".ggml", ".onnx", ".wav", ".aiff", ".pcm", ".metallib", ".air", ".pyc", ".log", ".stdout", ".stderr", ".jsonl", ".p12", ".pem", ".key"}
errors = []
for name in filter(None, paths):
    path = root / name
    if path.is_symlink():
        errors.append(f"{name}: tracked symlink needs explicit review")
        continue
    if not path.is_file():
        continue
    if path.suffix.lower() in forbidden_suffixes or any(part in {".build", "dist", "Vendor", "__pycache__", ".venv", "downloads", "xcuserdata"} for part in path.parts):
        errors.append(f"{name}: generated, downloaded, or sensitive artifact")
    if path.name == ".env" or path.name.startswith(".env.") and path.name != ".env.example":
        errors.append(f"{name}: local environment file")
    if path.stat().st_size > 2 * 1024 * 1024:
        errors.append(f"{name}: file exceeds 2 MiB source limit")
    if name in {"Resources/AppIcon.png", "Resources/AppIcon.icns"}:
        signature = path.read_bytes()[:8]
        expected = b"\x89PNG\r\n\x1a\n" if path.suffix == ".png" else b"icns"
        if not signature.startswith(expected):
            errors.append(f"{name}: invalid icon format")
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeError:
        errors.append(f"{name}: binary source needs explicit review")
        continue
    for number, line in enumerate(text.splitlines(), 1):
        if han.search(line):
            errors.append(f"{name}:{number}: literal Han text; use English prose or escaped test data")
        if private_key.search(line) or credential.search(line):
            errors.append(f"{name}:{number}: possible credential")
        if re.search(r"/(?:Users|home)/[A-Za-z0-9._-]+/", line):
            errors.append(f"{name}:{number}: machine-specific home path")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"Repository hygiene passed for {len(list(filter(None, paths)))} tracked files.")
