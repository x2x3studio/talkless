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

For a one-off AI choice, press the alternate finish key while recording: it ends this dictation with the opposite of the AI polish setting captured at recording start. With AI on it uses the original transcript; with AI off it requests polishing. Normal release/tap/menu finish keeps the captured default. Settings > General > Keyboard shortcuts lets you click either shortcut field and press then release Fn or a supported right-side modifier to record it, without starting dictation. Escape cancels; the alternate binding can be cleared. Conflicting bindings are rejected. Existing Automatic preferences use Right Option unless that is the dictation key, then Right Command, until you record an explicit binding. The HUD shows the current default and alternate action. The alternate key never starts recording while idle, does not alter global settings, and is unavailable during selected-text voice editing. Press the alternate key by itself (or while holding the primary dictation key). It finishes immediately, even if you then add another key for an application shortcut. Already-held unrelated modifiers or non-modifier keys prevent alternate finish; keyboard events still pass through to the focused app.

For local testing with the release identity and a fixed installation path, quit Talkless and run `bash scripts/install-local.sh`. It uses the configured signing references, builds with the same Developer ID as releases, verifies the signature and installs `/Applications/Talkless.app`. The old app is held only during replacement for failure rollback, then removed automatically; successful installs retain no backup. Launch that copy rather than changing build-directory apps; the initial switch from ad-hoc signing may require one permission grant. This local install is not notarized or published.

The basic `build-app.sh` fallback is ad-hoc signed and **not notarized** unless `CODE_SIGN_IDENTITY` is supplied. Such builds may need permission reapproval and are not distribution releases. CI Beta/Stable artifacts are signed and notarized separately.

## Recognition

Dictation is silent: no start/stop sounds or routine success/empty-result messages. A translucent HUD sizes itself to the live text, wraps long sentences, and grows up to 380 by 174 points before keeping the latest lines visible in a bounded preview. Its background uses native behind-window blur; Reduce Transparency uses an opaque background. A small recording dot breathes gently; there is no separate microphone/waveform bar. After recording stops, it replaces the live preview with "Recognizing" and a spinner, then "Polishing" with a pulsing blue sparkle only while AI polishing runs. Voice editing shows "Editing" instead. The recording dot and sparkle stay still when Reduce Motion is enabled. The HUD follows the text insertion caret when the target app exposes accessibility geometry, preferring an 8-point gap below the current line or above when needed. Unsupported apps fall back to the bottom of the active display. It never takes focus and hides immediately on completion. Actionable errors remain visible; diagnostic events are retained locally.

- Qwen runs in-process, not through Python or a CLI subprocess. The selected installed model is prepared at startup and after download/selection, then kept in memory between dictations. Stopping recording does not unload weights; model changes, deletion or process exit release them.
- Raw Qwen language/control headers are parsed before display. Incomplete headers never become transcript text; malformed final headers produce an error rather than inserting metadata. Literal words such as `language English` inside the transcript remain untouched.
- Audio callbacks copy PCM into a background queue. One actor serializes MLX model access.
- Live text is a replaceable snapshot of the current acoustic window, decoded approximately every two seconds of new audio.
- Windows are up to 30 seconds. Long dictations commit at a nearby low-energy boundary when available, retaining all remaining audio without acoustic overlap. Silence is not removed and does not stop recording.
- Stopping finishes the active window only. Previously committed windows are not decoded again.
- This is not a complete port of `mlx-qwen3-asr`'s encoder/KV prefix cache. Long uninterrupted speech may still split a word at a window boundary.
- Completed dictation is pasted directly at the current input cursor using the clipboard and Command-V. It does not require reading or matching the original accessibility element or selection, and does not force focus back to the original app. Cancellation still prevents stale results from being pasted. Clipboard restoration and local history remain enabled.

Settings > Overlay provides a live sample preview with recording, recognizing, and polishing stages and short or long text. Choose a translucent or solid backdrop, adjust background-only opacity from 20% to 100%, and toggle indicator animations. Changes persist and apply immediately to the real overlay without recording audio or contacting a provider. Text and icons stay fully legible as the backdrop fades; macOS Reduce Transparency and Reduce Motion take priority. Reset appearance restores the defaults. The real overlay remains click-through and never takes focus.

The menu bar uses the app's own waveform-and-caret mark in every state, without the colored app tile. A filled dot indicates recording and an outlined dot indicates processing. Template rendering adapts to light, dark, and selected menu bar appearances; accessible labels describe the current state.

## AI polishing

Optional polishing supports DeepSeek, OpenAI (Responses or Chat Completions), native Gemini, native Anthropic, and a custom API endpoint. Provider settings are independent; keys are stored in macOS Keychain. Fetch Models fills a picker when the endpoint supports discovery, with manual model IDs as a fallback. Connection testing sends only an explicit fixed test. See [provider configuration and privacy](docs/ai-polish.md).

Dictionary has separate My terms and Review sections. Search, add, edit, or delete confirmed spellings in My terms; existing newline-based terms are retained and capitalization is preserved. Only confirmed terms are passed to local Qwen, Apple and API speech recognition, and to AI polishing. They are hints rather than forced replacements.

Review compares saved raw dictation with polished output locally to suggest small spelling corrections, including Chinese and Latin terms. Each candidate shows the heard/polished evidence and the number of distinct dictations. Accept adds that spelling to My terms; Dismiss stays hidden until an explicit reset. Suggestions are never accepted automatically. Scan history runs once on demand; automatic local suggestions are opt-in and off by default. Scanning uses up to 500 recent history entries, excludes edits/translations and large rewrites, displays up to 100 candidates, and makes no network or additional AI requests. AI changes are evidence, not ground truth: review each spelling before accepting. Talkless does not monitor edits made in other apps after pasting.

## Updates

Settings > General > Updates offers Stable and Beta channels. "Automatically check for updates" is enabled by default for new preferences and checks the selected channel every 30 minutes while Talkless is running. Existing automatic-check preferences are preserved. Checks are skipped during dictation or another update session; manual checking remains available when idle. Updates ask before installation rather than downloading or installing silently. Turning off automatic checks leaves manual checking available. Local builds without valid signed update feeds cannot check for updates.

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
