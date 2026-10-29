# Talkless single-model streaming experiments

Historical feasibility probes and integration records from 2026-10-29. The standalone streaming CLI and preview runner predate the native Qwen product integration; they are not the current application's recognition path. See the [project README](../README.md) for current product status.

- `fixtures/`: locally synthesized Mandarin, mixed-language, short, silence, pause and repeated-utterance WAV files. `fixtures/generate.sh` recreates them locally; no user microphone recording is captured or uploaded.
- `qwen-streaming/`: historical Qwen3-ASR-1.7B 4-bit Swift/MLX CLI with real-time-paced audio ingestion and timestamped JSONL output. The same model/session generates partial and final text.
- `preview-runner/`: standalone AppKit app reusing the Talkless HUD, driven by the experimental Qwen CLI output.
- `native-tests/`: model-free state/lifecycle regression harness for the production Qwen adapter.
- `native-integration-results/`: historical native product integration observations and descriptions of locally retained outputs.
- `measurement-notes.md`: measurement definitions, fixture limitations and the sequence of desktop verification.
- `validate_timeline.py` and `test_validate_timeline.py`: pacing/completeness checks and model-free regression tests for CLI timelines.

## What counted as success

1. Nonempty, relevant partial text arrives **before** all audio is captured.
2. Audio is captured at wall-clock pace, not fed as a complete file instantly. Capture drift and queue backlog are measured independently of decoder speed.
3. The final transcript comes from stopping the same session, not an Apple pre-pass or a second model.
4. Model-load time, first-text latency and stop-to-final latency are reported separately; first-use GPU initialization and warm runs are distinguished.
5. GUI results are only claimed after visual observation. Insertion into the disposable local test text view does **not** validate cross-application paste.

## Scope limits and historical status

TTS fixtures cannot establish accuracy for human Mandarin/English code-switching, whispered speech, room noise or microphone hardware. These probes do not test a polishing model. Generated audio, downloaded models, dependency checkouts, builds and raw results are local artifacts, not repository source; a fresh checkout must regenerate or obtain them before running the probes.

The initial full-product release build failed on actor-isolation errors in `Sources/Talkless/Prompts.swift`. The separate preview app avoided those unrelated components. That was an early experiment limitation, not the current build status: the later [native integration record](native-integration-results/README.md) documents a successful product release build and in-process Qwen integration. The standalone probe's timings and failures must not be attributed to the later product adapter.
