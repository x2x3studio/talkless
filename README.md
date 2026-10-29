# Talkless

macOS voice input using native Swift 6 and local Qwen3-ASR through MLX.

## Build and launch

Requires Apple Silicon, macOS 26+, Xcode with Swift 6.4 and the Metal Toolchain.

```sh
swift package resolve
bash scripts/build-app.sh
open dist/Talkless.app
```

The development build uses the downloaded `experiments/qwen-streaming/model` weights when available. In Settings > Speech Recognition, select Qwen and a local Qwen3-ASR model directory containing configuration, tokenizer and safetensors files. The tested model is Qwen3-ASR-1.7B 4-bit. A portable installation should place it in `~/Library/Application Support/Talkless/Models/Qwen3-ASR-1.7B-4bit`, or choose another local directory in settings. The model is not embedded in the 55 MB app bundle.

Grant microphone and Accessibility permissions in macOS System Settings. Fn is the default trigger: hold to speak, release to finish; a quick tap toggles hands-free recording. Configure the system Globe-key action to do nothing to avoid conflicts, or choose another trigger in Talkless settings. No VAD, silence gate or automatic pause-based recording stop is enabled. Polishing and selection editing are off by default for new users.

The default build is ad-hoc signed and **not notarized**. Rebuilding may require removing and re-adding its Accessibility permission. Set `CODE_SIGN_IDENTITY` to a stable development/Developer ID identity when available. Do not expect the ad-hoc build to be distributable to other machines as a signed release.

## Recognition

- Qwen runs in-process, not through Python or a CLI subprocess. Model state is reused between dictations.
- Audio callbacks copy PCM into a background queue. One actor serializes MLX model access.
- Live text is a replaceable snapshot of the current acoustic window, decoded approximately every two seconds of new audio.
- Windows are up to 30 seconds. Long dictations commit at a nearby low-energy boundary when available, retaining all remaining audio without acoustic overlap. Silence is not removed and does not stop recording.
- Stopping finishes the active window only. Previously committed windows are not decoded again.
- This is not a complete port of `mlx-qwen3-asr`'s encoder/KV prefix cache. Long uninterrupted speech may still split a word at a window boundary.
- Automatic paste requires the original application, focused accessibility element and observable selection to match. Otherwise the result is retained in history and a copyable result panel; the app does not force focus back.

## Reproducible checks

Model weights, generated recordings, local results, dependencies, and build products are excluded from Git. Swift packages are locked in `Package.resolved`; third-party source is fetched rather than committed. All first-party source, documentation, and UI copy is English; Mandarin recognition remains supported.

```sh
swift experiments/native-tests/run-qwen-state-tests.swift
bash experiments/fixtures/generate.sh

dist/Talkless.app/Contents/MacOS/Talkless \
  --test-audio "$PWD/experiments/fixtures/mandarin.wav" \
  --test-output /tmp/talkless-result.txt --test-keep-open
```

The file test drives the same native Qwen adapter and controller with real-time-paced 16 kHz mono PCM. It deliberately bypasses microphone permissions and external paste. Results and timing logs are in `experiments/native-integration-results/`. Synthetic fixtures do not establish human speech accuracy. `--test-output` writes to the specified file; choose an unused path.

Local ASR state tests cover sample preservation across windows, tail delivery, replaceable preview, cancellation/stale callbacks, bounded backlog, finish completion races, and boundary selection.
