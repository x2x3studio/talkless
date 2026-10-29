# Native Qwen streaming measurement CLI

Historical standalone probe, not the current product's recognition path. Tested on 2026-10-29 with Swift 6.4, Swift 6 language mode, M4 16 GiB, macOS 27.0.1. Later native integration results are documented [separately](../native-integration-results/README.md). Full report: [Qwen streaming measurements](../../docs/research/06-qwen-streaming-measurement.md).

## Rebuild

From the project root:

```sh
swift build --package-path experiments/qwen-streaming \
  --build-system native -c release --product qwen-streaming -j 6
python3 -I experiments/qwen-streaming/build_metal.py "$PWD/experiments/qwen-streaming"
```

The native build backend avoids the Swift 6.4 default backend's Metal build failure observed on the test host; it does not downgrade the compiler. The Metal shader helper requires the Xcode Metal Toolchain. SwiftPM fetches the upstream `Blaizzy/mlx-audio-swift` package at commit `fe2c182f4da8115fe2b6b99c9a4d2048fbf9b1e6`, pinned in `Package.swift`, with no ASR source modifications. `Package.resolved` records the resolved dependency graph. No manually vendored checkout is required.

## Prepare local inputs

Generated fixtures, downloaded models and raw results are not included in the repository. Generate audio with [the local fixture script](../fixtures/README.md). To download the model directly from its upstream Hugging Face repository, run this explicitly from the project root:

```sh
python3 -I experiments/qwen-streaming/download_model.py "$PWD/experiments/qwen-streaming"
```

The download helper records a revision, file hashes and timings locally and refuses to replace existing model files. It verifies the model weights against the experiment's expected SHA-256; if upstream weights change, verification fails rather than silently accepting different weights. Talkless does not host model weights. This download requires network access; inference does not upload audio.

## Run

```sh
experiments/qwen-streaming/.build/release/qwen-streaming \
  --audio "$PWD/experiments/fixtures/mandarin.wav" \
  --model-dir "$PWD/experiments/qwen-streaming/model" \
  --frame-ms 50 --language Chinese --repetitions 2
```

Only 16 kHz mono audio is accepted. Once the model is downloaded and verified, no network is needed for inference. The colocated `mlx.metallib` means execution does not depend on the working directory.

- `--decode-interval 1.0`: seconds between decode passes.
- `--language Chinese|English|auto`: language hint.
- `--repetitions 2`: retain one model and create two sequential sessions, measuring warm-session behavior.

Stdout is JSONL, stderr contains dependency diagnostics. `displayUpdate` provides `confirmedText`, `provisionalText`, and combined `fullText`. `ended` contains final `fullText`; `summary` contains timings, queue metrics and memory. Per-frame `audio_frame` and `audio_fed` events establish real-time pacing and input completeness. A watchdog exits nonzero if finalization fails to complete within the source duration plus 90 seconds.

## Verified results and limitations

- Relevant first words: roughly 1.1–1.2 seconds after first-frame availability.
- End-of-input to final: roughly 0.3–0.6 seconds for speech fixtures.
- Peak footprint: about 3.04 GB for longer samples.
- **Failure in this experimental adapter**: window boundaries repeat fragments. Digital silence generates a Mandarin affirmative meaning "yes." An early nonempty Mandarin hesitation meaning "um" is a hallucination, not a valid first-word result.
- All audio is synthetic Tingting TTS. This is not a human speech quality benchmark.
- No microphone, polishing or cross-app paste is tested here.

`results/*-realtime.jsonl` are the corrected absolute-clock measurements. The earlier `mandarin.jsonl` baseline accumulated relative sleep drift and must not be used as the strict real-time result. Adjacent `.stderr` files include `/usr/bin/time -l` memory footprint.

Validate from the project root:

```sh
python3 -I experiments/test_validate_timeline.py
python3 -I experiments/validate_timeline.py experiments/qwen-streaming/results/mandarin-realtime.jsonl
```
