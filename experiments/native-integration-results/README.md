# Native product integration results — 2026-10-29

Historical observations from a local development build, not a claim that the current checkout has been rebuilt or reverified. Generated transcripts, logs and binaries are retained locally and excluded from repository source. See the [project README](../../README.md) for current product status.

Tested product executable: `dist/Talkless.app/Contents/MacOS/Talkless`, Swift 6.4 / Swift 6 release. Qwen3-ASR-1.7B 4-bit is loaded directly in-process through MLX; no CLI/Python recognizer subprocess, VAD, silence rejection or pause-based stopping.

## Passed

- Native release build, resource/Metal packaging and `codesign --verify --deep --strict`.
- Nine native state/lifecycle regression checks: `swift experiments/native-tests/run-qwen-state-tests.swift`.
- `mandarin.txt`: complete 14.098s utterance; the old duplicated phrase meaning "inside the window" is absent.
- `mixed.txt`: complete 17.994s utterance including spoken correction; API and Swift UI recognized, Qwen transcribed as Quinn. Synthetic English pronunciation limits accuracy conclusions.
- `short.txt`: three-second truncated input produces text and completes.
- `pause-final.txt`: a three-second zero-PCM pause inserted into Mandarin speech does not terminate the session or drop the remaining speech.
- `long-verified.txt`: final build, 42.295s (three repeats). Normalizing punctuation/whitespace yields exactly three copies of the short Mandarin result, with no extra boundary fragment.
- CUA observed partial text change and final text in the actual product test window. The normal app's settings were inspected: Qwen selected, development model path resolves correctly.

## Recorded regression and fix

`long.txt` and `long-final.txt` are earlier failed boundary outputs: the Mandarin word for "microphone" was split, with its opening syllables repeated as a separate fragment. A weak syllable was selected as a pause by the overly permissive relative energy threshold. The final tested build used a stricter low-energy boundary criterion; no audio was removed. `long-verified.txt` is the passing retest. These earlier failed outputs remain locally for auditability.

## Process-level timing (not first-token or stop latency)

`/usr/bin/time -l` measures full launch, model loading, paced input, inference, and application exit:

| Fixture | Wall time | Peak physical footprint |
|---|---:|---:|
| Mandarin | 16.04s | 3.26GB |
| Mixed | 19.37s | 3.50GB |
| Short | 3.67s | 2.86GB |
| Pause | 18.38s | 3.51GB |
| Long, final build | 44.08s | 3.82GB |

Do not reuse the old experimental streaming adapter's first-token or stop-to-final numbers for this new implementation. The new adapter redecodes a bounded active window; Python audio-prefix/KV caching has not been ported. Continuous speech with no safe long-window boundary remains a potential word-split case.

The first `pause` GUI run used `--test-keep-open` and was terminated **after** the successful result to close its window; its shell exit 143 is not counted as a clean process test. `pause-final` was rerun without keep-open and exited 0.

## Permissions at the time of testing

The development app's UI reported that Microphone and Accessibility permissions were not granted. These settings were not changed automatically. Real microphone capture, physical hotkeys and cross-application paste were implemented but were not end-to-end verified by these tests. The file-test path deliberately bypassed microphone/AX permission and external paste. The tested ad-hoc build was not notarized; permissions may need renewal after rebuilds.
