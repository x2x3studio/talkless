# Talkless

macOS voice input using native Swift 6 and local Qwen3-ASR through MLX.

## Build and launch

Requires Apple Silicon, macOS 26+, Xcode with Swift 6.4 and the Metal Toolchain.

```sh
swift package resolve
bash scripts/build-app.sh
open dist/Talkless.app
```

Open **Settings > Models** to download and manage local speech models. **Qwen3-ASR 0.6B, MLX 4-bit** is recommended and selected by default (712.8 MB including configuration/tokenizer files); 1.7B 4-bit is an optional larger model. Downloads start only when you click Download. No development-folder or alternate-model fallback is selected silently.

Choose Hugging Face, HF Mirror, or a custom Hugging Face-compatible HTTPS mirror. HF Mirror can redirect to Hugging Face and is not guaranteed to provide independent regional access. ModelScope is not listed until matching MLX artifacts are verified; SpeakMore's GGUF Q8 files are not compatible with this MLX runtime.

The manager supports progress, cancel/resume, retries, Use and confirmed Delete. Every file has a pinned revision, byte size and SHA-256; the model becomes usable only after verification. Verified files and partial downloads survive restarts. Installed models live in `~/Library/Application Support/Talkless/Models/`. Deletion affects only managed files and waits for runtime unload; downloads cannot delete arbitrary imported folders. Advanced settings retain an explicit custom-folder override.

The application icon is original artwork; regenerate it with `swift scripts/generate-icon.swift`. Model weights are not included in the app or its updates.

Grant microphone and Accessibility permissions in macOS System Settings. Fn is the default trigger: hold to speak, release to finish; a quick tap toggles hands-free recording. Configure the system Globe-key action to do nothing to avoid conflicts, or choose another trigger in Talkless settings. No VAD, silence gate or automatic pause-based recording stop is enabled. Polishing and selection editing are off by default for new users.

For local testing with the release identity and a fixed installation path, quit Talkless and run `bash scripts/install-local.sh`. It uses the configured signing references, builds with the same Developer ID as releases, verifies the signature, backs up any existing app and installs `/Applications/Talkless.app`. Launch that copy rather than changing build-directory apps; the initial switch from ad-hoc signing may require one permission grant. This local install is not notarized or published.

The basic `build-app.sh` fallback is ad-hoc signed and **not notarized** unless `CODE_SIGN_IDENTITY` is supplied. Such builds may need permission reapproval and are not distribution releases. CI Beta/Stable artifacts are signed and notarized separately.

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
bash experiments/model-tests/run-tests.sh
bash experiments/fixtures/generate.sh

dist/Talkless.app/Contents/MacOS/Talkless \
  --test-audio "$PWD/experiments/fixtures/mandarin.wav" \
  --test-output /tmp/talkless-result.txt --test-keep-open
```

The file test drives the same native Qwen adapter and controller with real-time-paced 16 kHz mono PCM. It deliberately bypasses microphone permissions and external paste. Results and timing logs are in `experiments/native-integration-results/`. Synthetic fixtures do not establish human speech accuracy. `--test-output` writes to the specified file; choose an unused path.

Local ASR state tests cover sample preservation across windows, tail delivery, replaceable preview, cancellation/stale callbacks, bounded backlog, finish completion races, and boundary selection.
