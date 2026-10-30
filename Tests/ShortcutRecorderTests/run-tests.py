#!/usr/bin/env python3
"""Offline recorder tests: compile the actual enums/control, without app settings or microphone."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
settings = (root / "Sources/Talkless/Settings.swift").read_text()
# Extract real enum definitions, not a duplicate test implementation or live preferences.
enums = settings[settings.index("enum TriggerKey:"):settings.index("enum ASREngine:")]
with tempfile.TemporaryDirectory(prefix="talkless-recorder-tests-") as work:
    directory = Path(work)
    enum_file = directory / "ShortcutKeys.swift"
    enum_file.write_text("import Foundation\n" + enums)
    binary = directory / "shortcut-recorder-tests"
    subprocess.run([
        "swiftc", "-swift-version", "6", "-parse-as-library",
        str(enum_file), str(root / "Sources/Talkless/ShortcutRecorder.swift"),
        str(root / "Tests/ShortcutRecorderTests/ShortcutRecorderTests.swift"),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary), *sys.argv[1:]], check=True)
