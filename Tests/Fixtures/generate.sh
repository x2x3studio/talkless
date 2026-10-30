#!/bin/bash
# Generate synthetic fixtures locally; never record or upload user audio.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR}"
if (( $# > 1 )); then
  printf 'Usage: %s [output-directory]\n' "$0" >&2
  exit 2
fi
for tool in say ffmpeg python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Required local tool not found: %s\n' "$tool" >&2
    exit 1
  fi
done
if ! say -v '?' | grep '^Tingting[[:space:]]' >/dev/null; then
  printf 'Install the Tingting speech voice in macOS settings before generating fixtures.\n' >&2
  exit 1
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd)"
for name in mandarin mixed short silence mandarin-pause mandarin-long; do
  if [[ -e "$OUTPUT_DIR/$name.wav" || -L "$OUTPUT_DIR/$name.wav" ]]; then
    printf 'Refusing to replace existing fixture: %s/%s.wav\n' "$OUTPUT_DIR" "$name" >&2
    exit 1
  fi
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/talkless-fixtures.XXXXXX")"
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Keep the original Mandarin utterances as ASCII source, with English meanings
# in README.md. Python decodes the escapes only into temporary local TTS input.
python3 -I - "$WORK_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
texts = {
    "mandarin": (
        "\u6211\u4eec\u5148\u505a\u4e00\u4e2a\u9ea6\u514b\u98ce\u5f55\u97f3\u7684\u9884\u89c8\u7a97\u53e3\u3002"
        "\u8bf4\u8bdd\u7684\u65f6\u5019\uff0c\u6587\u5b57\u5b9e\u65f6\u663e\u793a\u5728\u7a97\u53e3\u91cc\u9762\u3002"
        "\u7b49\u6211\u8bf4\u5b8c\u4ee5\u540e\uff0c\u518d\u81ea\u52a8\u7c98\u8d34\u5230\u539f\u6765\u7684\u8f93\u5165\u6846\uff0c"
        "\u4e0d\u9700\u8981\u505a\u8f93\u5165\u6cd5\u3002"
    ),
    "mixed": (
        "\u8fd9\u4e2a\u9879\u76ee\u4e3b\u8981\u652f\u6301 macOS\uff0c\u754c\u9762\u7528 SwiftUI\uff0c"
        "\u8bed\u97f3\u8bc6\u522b\u7528 Qwen ASR\u3002\u6211\u4eec\u5148\u6d4b\u8bd5 API \u7684\u5ef6\u8fdf\u3002"
        "\u5468\u4e09\u4e0a\u7ebf\uff0c\u4e0d\u5bf9\uff0c\u6539\u6210\u5468\u56db\u4e0a\u7ebf\u3002"
        "\u4e0d\u8981\u81ea\u52a8\u56de\u7b54\u6211\u8bf4\u7684\u8bdd\u3002"
    ),
}
for name, text in texts.items():
    (root / f"{name}.txt").write_text(text, encoding="utf-8")
PY

say -v Tingting -r 175 -f "$WORK_DIR/mandarin.txt" -o "$WORK_DIR/mandarin.aiff"
say -v Tingting -r 170 -f "$WORK_DIR/mixed.txt" -o "$WORK_DIR/mixed.aiff"
for name in mandarin mixed; do
  ffmpeg -nostdin -hide_banner -loglevel error -n \
    -i "$WORK_DIR/$name.aiff" -ac 1 -ar 16000 -c:a pcm_s16le "$WORK_DIR/$name.wav"
done

# Derive sample-exact variants without re-encoding or changing the originals.
python3 -I - "$WORK_DIR" <<'PY'
from pathlib import Path
import sys
import wave

root = Path(sys.argv[1])
with wave.open(str(root / "mandarin.wav"), "rb") as source:
    assert (source.getnchannels(), source.getsampwidth(), source.getframerate()) == (1, 2, 16000)
    speech = source.readframes(source.getnframes())
bytes_per_second = 16000 * 2
silence = bytes(3 * bytes_per_second)
splice = 5 * bytes_per_second
if len(speech) <= splice:
    raise SystemExit("Mandarin synthesis is too short for the five-second pause splice")
variants = {
    "short": speech[:3 * bytes_per_second],
    "silence": silence,
    "mandarin-pause": speech[:splice] + silence + speech[splice:],
    "mandarin-long": speech * 3,
}
for name, audio in variants.items():
    with wave.open(str(root / f"{name}.wav"), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16000)
        output.writeframes(audio)
PY

# Exclusive creation also protects against fixtures appearing during synthesis.
python3 -I - "$WORK_DIR" "$OUTPUT_DIR" <<'PY'
from pathlib import Path
import shutil
import sys
import wave

source, destination = map(Path, sys.argv[1:])
for path in sorted(source.glob("*.wav")):
    target = destination / path.name
    with path.open("rb") as src, target.open("xb") as dst:
        shutil.copyfileobj(src, dst)
    with wave.open(str(target), "rb") as audio:
        duration = audio.getnframes() / audio.getframerate()
    print(f"Generated {target.name}: {duration:.6f} seconds")
print(f"Local fixtures saved to {destination}")
PY
