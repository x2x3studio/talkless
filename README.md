# Talkless

macOS voice input using native Swift 6 and local Qwen3-ASR through MLX. Talkless runs as a menu bar app, not an input method, and is distributed directly rather than through the Mac App Store.

This README describes the current source checkout, not necessarily the latest published release.

## Build and launch

Requires Apple Silicon, macOS 26+, Xcode with Swift 6.4 and the Metal Toolchain.

```sh
swift package --build-system native resolve --force-resolved-versions
bash scripts/build-app.sh
open dist/Talkless.app
```

Open **Settings > Models** to download and manage local speech models. **Qwen3-ASR 0.6B, MLX 4-bit** is the single built-in model (712.8 MB including configuration/tokenizer files). Downloads start only when you click Download. No development-folder or alternate-model fallback is selected silently.

Choose Hugging Face, HF Mirror, or a custom Hugging Face-compatible HTTPS mirror. HF Mirror can redirect to Hugging Face and is not guaranteed to provide independent regional access. ModelScope is not listed until matching MLX artifacts are verified; SpeakMore's GGUF Q8 files are not compatible with this MLX runtime.

The manager supports progress, cancel/resume, retries, Use and confirmed Delete. Every file has a pinned revision, byte size and SHA-256; the model becomes usable only after verification. Verified files and partial downloads survive restarts. Installed models live in `~/Library/Application Support/Talkless/Models/`. Deletion affects only managed files and waits for runtime unload; downloads cannot delete arbitrary imported folders. Advanced settings retain an explicit custom-folder override.

The application icon is original artwork; regenerate it with `swift scripts/generate-icon.swift`. Model weights are not included in the app or its updates.

The basic `build-app.sh` build is ad-hoc signed unless `CODE_SIGN_IDENTITY` is supplied; it is **not notarized** in either case. Such builds may need permission reapproval and are not distribution releases. The release pipeline signs and notarizes Beta/Stable artifacts separately.

For local testing with the release identity and a fixed installation path, quit Talkless and run `bash scripts/install-local.sh`. It uses the configured signing references, builds with the same Developer ID as releases, verifies the signature and installs `/Applications/Talkless.app`. The old app is held only during replacement for failure rollback, then removed automatically; successful installs retain no backup. Launch that copy rather than changing build-directory apps; the initial switch from ad-hoc signing may require one permission grant. This local install is not notarized or published. See [release setup](docs/releasing.md) for prerequisites and signing references.

## Dictation and shortcuts

Grant microphone and Accessibility permissions in macOS System Settings. Fn is the default trigger: hold to speak, release to finish; a quick tap starts hands-free recording, and another tap finishes. Escape cancels. Configure the system Globe-key action to Do Nothing to avoid conflicts, or choose another trigger in Talkless settings. No VAD, silence gate or automatic pause-based recording stop is enabled. Polishing and selected-text voice editing are off by default for new users.

For a one-off AI choice, press the **alternate finish key** while recording:

| AI polish at recording start | Normal release, tap, or menu finish | Alternate finish |
| --- | --- | --- |
| On | Polish | Use original transcript |
| Off | Use original transcript | Request polishing |

This captures the global AI on/off default at recording start; the alternate key does not change it. The HUD shows the captured default and alternate action. Alternate finish never starts recording while idle and is unavailable during selected-text voice editing. If requested polishing fails or no provider is configured, the original transcript is retained.

**Settings > General > Keyboard shortcuts** lets you click either shortcut field and press then release **Fn, Right Option, Right Command, or Right Control** to save it without starting dictation. Only these single keys are supported, not key combinations. Escape cancels shortcut capture; Delete or Backspace clears the alternate binding. Conflicting bindings are rejected. Automatic (the default for unset preferences) uses Right Option unless that is the dictation key, then Right Command, until you record an explicit binding.

Press the alternate key by itself or while holding the primary dictation key. It finishes immediately, even if you then add another key for an application shortcut. Already-held unrelated modifiers or non-modifier keys prevent alternate finish; alternate-key events still pass through to the focused app.

## Recognition

**Settings > Models** selects local Qwen (the default), Apple on-device recognition, or a cloud Whisper-compatible API. Qwen requires an explicitly downloaded model; Apple may download its required speech assets on first use. Cloud recognition uploads recorded audio and dictionary hints to the configured provider and may incur charges. The local Qwen pipeline works as follows:

- Qwen runs in-process, not through Python or a CLI subprocess. The selected installed model is prepared at startup and after download/selection, then kept in memory between dictations. Stopping recording does not unload weights; model changes, deletion or process exit release them.
- Raw Qwen language/control headers are parsed before display. Incomplete headers never become transcript text; malformed final headers produce an error rather than inserting metadata. Literal words such as `language English` inside the transcript remain untouched.
- Audio callbacks copy PCM into a background queue. One actor serializes MLX model access.
- Live text is a replaceable snapshot of the current acoustic window, decoded approximately every two seconds of new audio.
- Windows are up to 30 seconds. Long dictations commit at a nearby low-energy boundary when available, retaining all remaining audio without acoustic overlap. Silence is not removed and does not stop recording.
- Stopping finishes the active window only. Previously committed windows are not decoded again.
- This is not a complete port of `mlx-qwen3-asr`'s encoder/KV prefix cache. Long uninterrupted speech may still split a word at a window boundary.
- Completed dictation is pasted directly at the current input cursor using the clipboard and Command-V. It does not require reading or matching the original accessibility element or selection, and does not force focus back to the original app. Cancellation still prevents stale results from being pasted. Clipboard restoration and local history remain enabled.

## Overlay

Dictation is silent: no start/stop sounds or routine success/empty-result messages. The HUD wraps live text within a maximum of 380 by 174 points, keeping the latest lines visible. After recording stops, it shows **Recognizing**, then **Polishing** only while AI polishing runs, or **Editing** for selected-text voice editing. It follows the text caret where accessibility geometry is available, falling back to the bottom of the active display. It hides on completion; actionable errors remain visible.

**Settings > Overlay** provides a live sample preview with recording, recognizing, and polishing stages and short or long text. Choose a translucent or solid backdrop, adjust translucent background-only opacity from 20% to 100%, and toggle indicator animations. Solid is always opaque. Changes persist and apply immediately without recording audio or contacting a provider. Text and icons are not faded; macOS Reduce Transparency and Reduce Motion take priority. Reset appearance restores the defaults. The real overlay remains click-through and never takes focus.

The menu bar uses the app's own waveform-and-caret mark in every state, without the colored app tile. A filled dot indicates recording and an outlined dot indicates processing. Template rendering adapts to light, dark, and selected menu bar appearances; accessible labels describe the current state.

## AI polishing

Optional polishing supports DeepSeek, OpenAI (Responses or Chat Completions), native Gemini, native Anthropic, and a custom API endpoint. Provider settings are independent; keys are stored in macOS Keychain. Fetch Models fills a picker when the endpoint supports discovery, with manual model IDs as a fallback. Connection testing sends only an explicit fixed test. See [provider configuration and privacy](docs/ai-polish.md).

Dictionary has separate My terms and Review sections. Search, add, edit, or delete confirmed spellings in My terms; existing newline-based terms are retained and capitalization is preserved. Only confirmed terms are passed to local Qwen, Apple and API speech recognition, and to AI polishing. They are hints rather than forced replacements.

Review compares saved raw dictation with polished output locally to suggest small spelling corrections, including Chinese and Latin terms. Each candidate shows the heard/polished evidence and the number of distinct dictations. Accept adds that spelling to My terms; Dismiss stays hidden until an explicit reset. Suggestions are never accepted automatically. Scan history runs once on demand; automatic local suggestions are opt-in and off by default. Scanning uses up to 500 recent history entries, excludes edits/translations and large rewrites, displays up to 100 candidates, and makes no network or additional AI requests. AI changes are evidence, not ground truth: review each spelling before accepting. Talkless does not monitor edits made in other apps after pasting.

## Updates

**Settings > General > Updates** offers Stable and Beta channels. Returning to Stable does not downgrade an installed beta. "Automatically check for updates" is enabled by default for new preferences and checks the selected channel every 30 minutes while Talkless is running. Existing automatic-check preferences are preserved. Checks during dictation or another update session wait until the next interval; manual checking remains available when idle. You choose when to download and install. Turning off automatic checks does not cancel an update already in progress. Local builds without valid update feed URLs and a signing public key cannot check for updates.

The [release workflow](docs/releasing.md) defaults to Beta for trusted pushes to `main`; Stable requires an explicit version tag. Publication still depends on a successful release job.

## Local data and privacy

Talkless does not use a `~/.talkless` configuration directory:

- **UserDefaults:** app preferences, provider endpoints/model IDs, confirmed dictionary terms and dismissed suggestions.
- **macOS Keychain:** AI polishing keys. The separate legacy **cloud ASR key is still stored in plaintext in UserDefaults**, not Keychain.
- **`~/Library/Application Support/Talkless/`:** managed models in `Models/`, up to 500 text-only history entries in `history.json`, and rotating event logs in `Diagnostics/`. History includes raw and final text, the app name, and timing metadata, not audio. Delete entries or clear them in Settings > History.

Local Qwen recognition does not upload audio. Optional cloud recognition sends audio; AI polishing, voice editing and translation send the text/context needed for those requests. See [provider privacy](docs/ai-polish.md) and [diagnostics export](docs/diagnostics.md) before sharing data.

## Reproducible checks

Model weights, generated recordings, local results, dependencies, and build products are excluded from Git. Swift packages are locked in `Package.resolved`; third-party source is fetched rather than committed. All first-party source, documentation, and UI copy is English; Mandarin recognition remains supported.

Run the model-free regression suite (no paid provider calls, microphone recording, or ASR model downloads). It requires the selected Xcode toolchain and Python 3; first-time SwiftPM dependency resolution can require network access.

```sh
bash scripts/test.sh
```

Separately, test local Qwen with a built app and an installed model. Fixture generation requires `say` with the Tingting voice installed, `ffmpeg`, and Python 3, and refuses to overwrite existing WAV files.

```sh
bash Tests/Fixtures/generate.sh

dist/Talkless.app/Contents/MacOS/Talkless \
  --test-audio "$PWD/Tests/Fixtures/mandarin.wav" \
  --test-output /tmp/talkless-result.txt --test-keep-open
```

The file test drives the same native Qwen adapter and controller with real-time-paced 16 kHz mono PCM. It uses the app's selected Qwen model and dictionary but bypasses microphone capture, polishing, history writes and external paste. Synthetic fixtures do not establish human speech accuracy. `--test-output` writes to the specified file; choose an unused path.

Local ASR state tests cover sample preservation across windows, tail delivery, replaceable preview, cancellation/stale callbacks, bounded backlog, finish completion races, and boundary selection. Optional [live polishing tests](docs/ai-polish.md#optional-live-polishing-smoke-tests) are separate, explicitly opt-in, and may incur API charges.
