# Talkless

macOS voice input using native Swift 6 and local Qwen3-ASR through MLX.

## Build and launch

Requires Apple Silicon, macOS 26+, Xcode with Swift 6.4 and the Metal Toolchain.

```sh
swift package resolve
bash scripts/build-app.sh
open dist/Talkless.app
```

Open **Settings > Models** to download and manage local speech models. **Qwen3-ASR 0.6B, MLX 4-bit** is the single built-in model (712.8 MB including configuration/tokenizer files). Downloads start only when you click Download. No development-folder or alternate-model fallback is selected silently.

Choose Hugging Face, HF Mirror, or a custom Hugging Face-compatible HTTPS mirror. HF Mirror can redirect to Hugging Face and is not guaranteed to provide independent regional access. ModelScope is not listed until matching MLX artifacts are verified; SpeakMore's GGUF Q8 files are not compatible with this MLX runtime.

The manager supports progress, cancel/resume, retries, Use and confirmed Delete. Every file has a pinned revision, byte size and SHA-256; the model becomes usable only after verification. Verified files and partial downloads survive restarts. Installed models live in `~/Library/Application Support/Talkless/Models/`. Deletion affects only managed files and waits for runtime unload; downloads cannot delete arbitrary imported folders. Advanced settings retain an explicit custom-folder override.

The application icon is original artwork; regenerate it with `swift scripts/generate-icon.swift`. Model weights are not included in the app or its updates.

Grant microphone and Accessibility permissions in macOS System Settings. Fn is the default trigger: hold to speak, release to finish; a quick tap toggles hands-free recording. Configure the system Globe-key action to do nothing to avoid conflicts, or choose another trigger in Talkless settings. No VAD, silence gate or automatic pause-based recording stop is enabled. Polishing and selection editing are off by default for new users.

For local testing with the release identity and a fixed installation path, quit Talkless and run `bash scripts/install-local.sh`. It uses the configured signing references, builds with the same Developer ID as releases, verifies the signature and installs `/Applications/Talkless.app`. The old app is held only during replacement for failure rollback, then removed automatically; successful installs retain no backup. Launch that copy rather than changing build-directory apps; the initial switch from ad-hoc signing may require one permission grant. This local install is not notarized or published.

The basic `build-app.sh` fallback is ad-hoc signed and **not notarized** unless `CODE_SIGN_IDENTITY` is supplied. Such builds may need permission reapproval and are not distribution releases. CI Beta/Stable artifacts are signed and notarized separately.

## Recognition

Dictation is silent: no start/stop sounds or routine success/empty-result messages. A compact HUD shows up to two lines of live words with a small recording dot or processing indicator; there is no separate microphone/waveform bar. It follows the text insertion caret when the target app exposes accessibility geometry, preferring an 8-point gap below the current line or above when needed. Unsupported apps fall back to the bottom of the active display. The HUD never takes focus and hides immediately on completion. Actionable errors remain visible; diagnostic events are retained locally.

- Qwen runs in-process, not through Python or a CLI subprocess. The selected installed model is prepared at startup and after download/selection, then kept in memory between dictations. Stopping recording does not unload weights; model changes, deletion or process exit release them.
- Raw Qwen language/control headers are parsed before display. Incomplete headers never become transcript text; malformed final headers produce an error rather than inserting metadata. Literal words such as `language English` inside the transcript remain untouched.
- Audio callbacks copy PCM into a background queue. One actor serializes MLX model access.
- Live text is a replaceable snapshot of the current acoustic window, decoded approximately every two seconds of new audio.
- Windows are up to 30 seconds. Long dictations commit at a nearby low-energy boundary when available, retaining all remaining audio without acoustic overlap. Silence is not removed and does not stop recording.
- Stopping finishes the active window only. Previously committed windows are not decoded again.
- This is not a complete port of `mlx-qwen3-asr`'s encoder/KV prefix cache. Long uninterrupted speech may still split a word at a window boundary.
- Completed dictation is pasted directly at the current input cursor using the clipboard and Command-V. It does not require reading or matching the original accessibility element or selection, and does not force focus back to the original app. Cancellation still prevents stale results from being pasted. Clipboard restoration and local history remain enabled.

## AI polishing

Optional polishing supports DeepSeek, OpenAI (Responses or Chat Completions), native Gemini, native Anthropic, and a custom API endpoint. Provider settings are independent; keys are stored in macOS Keychain. Fetch Models fills a picker when the endpoint supports discovery, with manual model IDs as a fallback. Connection testing sends only an explicit fixed test. See [provider configuration and privacy](docs/ai-polish.md).

## Reproducible checks

Model weights, generated recordings, local results, dependencies, and build products are excluded from Git. Swift packages are locked in `Package.resolved`; third-party source is fetched rather than committed. All first-party source, documentation, and UI copy is English; Mandarin recognition remains supported.

```sh
bash scripts/test.sh
bash Tests/Fixtures/generate.sh

dist/Talkless.app/Contents/MacOS/Talkless \
  --test-audio "$PWD/Tests/Fixtures/mandarin.wav" \
  --test-output /tmp/talkless-result.txt --test-keep-open
```

The file test drives the same native Qwen adapter and controller with real-time-paced 16 kHz mono PCM. It deliberately bypasses microphone permissions and external paste. Synthetic fixtures do not establish human speech accuracy. `--test-output` writes to the specified file; choose an unused path.

Local ASR state tests cover sample preservation across windows, tail delivery, replaceable preview, cancellation/stale callbacks, bounded backlog, finish completion races, and boundary selection.
