# Talkless user guide

[Back to Talkless](../README.md)

macOS voice input using native Swift 6 and local Qwen3-ASR through MLX. Talkless runs as a menu bar app, not an input method, and is distributed directly rather than through the Mac App Store.

This guide describes the current source checkout, not necessarily the latest published release.

## Build and launch

Requires Apple Silicon, macOS 26+, Xcode with Swift 6.4 and the Metal Toolchain.

```sh
swift package --build-system native resolve --force-resolved-versions
bash scripts/build-app.sh
open dist/Talkless.app
```

On a fresh installation, Setup Guide introduces the recording controls and walks through microphone access, Accessibility, speech recognition, and optional AI processing. Permission requests and downloads wait for an explicit action; optional steps can be skipped. Existing installations are not forced through onboarding after an update. Reopen it from **Settings > System > Setup Guide** without resetting preferences.

Open **Settings > Speech recognition** to download and manage local speech models. **Qwen3-ASR 0.6B, MLX 4-bit** is the single built-in model (712.8 MB including configuration/tokenizer files). Downloads start only when you click Download. No development-folder or alternate-model fallback is selected silently.

Choose Hugging Face, HF Mirror, or a custom Hugging Face-compatible HTTPS mirror. HF Mirror can redirect to Hugging Face and is not guaranteed to provide independent regional access. ModelScope is not listed until matching MLX artifacts are verified; SpeakMore's GGUF Q8 files are not compatible with this MLX runtime.

The manager supports progress, cancel/resume, retries, Use and confirmed Delete. Every file has a pinned revision, byte size and SHA-256; the model becomes usable only after verification. Verified files and partial downloads survive restarts. Installed models live in `~/Library/Application Support/Talkless/Models/`. Deletion affects only managed files and waits for runtime unload; downloads cannot delete arbitrary imported folders. Advanced settings retain an explicit custom-folder override.

The application icon is original artwork; regenerate it with `swift scripts/generate-icon.swift`. Model weights are not included in the app or its updates.

The basic `build-app.sh` build is ad-hoc signed unless `CODE_SIGN_IDENTITY` is supplied; it is **not notarized** in either case. Such builds may need permission reapproval and are not distribution releases. The release pipeline signs and notarizes Beta/Stable artifacts separately.

For local testing with the release identity and a fixed installation path, quit Talkless and run `bash scripts/install-local.sh`. It uses the configured signing references, builds with the same Developer ID as releases, verifies the signature and installs `/Applications/Talkless.app`. The old app is held only during replacement for failure rollback, then removed automatically; successful installs retain no backup. Launch that copy rather than changing build-directory apps; the initial switch from ad-hoc signing may require one permission grant. This local install is not notarized or published. See [release setup](releasing.md) for prerequisites and signing references.

## Settings

Settings opens to **Dictation**. The sidebar is organized by task:

- **Dictation:** microphone, recording mode and keys, AI polishing, output language, app-aware tone, selected-text voice editing, and additional instructions.
- **Translation:** selected-text source/target languages, automatic direction, preferred languages and shortcut, separate from dictation's output language.
- **Speech recognition:** recognition engine and local speech models.
- **AI service:** shared provider, protocol, credentials and model for polishing, translation and voice editing; no master AI enable toggle.
- **Dictionary**, **Overlay**, and **History:** terms and review, HUD appearance, and saved text.
- **System:** interface language, permissions, launch at login, updates and diagnostics.

**Settings > System > Language > Interface language** offers Follow System (the default), English and Simplified Chinese. Changes apply without restarting and affect the interface only, not speech recognition, dictation output, translation languages or provider settings. Follow System chooses a supported interface language from macOS preferences, falling back to English; it does not treat Traditional Chinese as Simplified Chinese.

The menu bar menu lists the current dictation, alternate-finish, and enabled translation shortcuts as informational rows. Its only actions are Settings, Check for Updates, and Quit; recording and translation are invoked using their shortcuts.

**Settings > System > Startup > Launch at login** uses macOS login-item registration. It is not enabled automatically. Turning it on starts Talkless when you sign in, not before login. If macOS requires approval, the page offers Open Login Items; the displayed state follows the system setting rather than a separate preference. Opening Settings never registers or unregisters a login item.

## Dictation and shortcuts

Grant microphone and Accessibility permissions in macOS System Settings; **Settings > System > Permissions** provides the permission controls. Fn is the default trigger and Hold to talk is the default mode: hold to speak, release to finish. Select Tap to toggle if you prefer pressing once to start and again to finish. Escape cancels. Configure the system Globe-key action to Do Nothing to avoid conflicts, or choose another trigger in Talkless settings. No VAD, silence gate or automatic pause-based recording stop is enabled. Polishing and selected-text voice editing are off by default for new users.

**Settings > Dictation > Recording > Recording mode** has two choices: Hold to talk (release always finishes), or Tap to toggle (the next press finishes, regardless of how long the first press lasted). There is no timing-based automatic mode. The mode is captured at recording start. Reset restores Hold to talk without changing other preferences. Older Automatic recording preferences migrate to Hold to talk.

For a one-off AI choice, press the **alternate finish key** while recording:

| AI polish at recording start | Normal release or tap finish | Alternate finish |
| --- | --- | --- |
| On | Polish | Use original transcript |
| Off | Use original transcript | Request polishing |

This captures the dictation polishing default at recording start; the alternate key does not change it. The HUD shows the captured default and alternate action. Alternate finish never starts recording while idle and is unavailable during selected-text voice editing. If requested polishing fails or no provider is configured, the original transcript is retained.

**Settings > Dictation > Recording** lets you click either shortcut field and press then release **Fn, Right Option, Right Command, or Right Control** to save it without starting dictation. Only these single keys are supported, not key combinations. Escape cancels shortcut capture; Delete or Backspace clears the alternate binding. Conflicting bindings are rejected. Automatic (the default for unset preferences) uses Right Option unless that is the dictation key, then Right Command, until you record an explicit binding.

Each shortcut shows its default and has a **Reset** button. Reset affects that binding only; an explicit conflicting binding is left unchanged and reported. **Reset recording shortcuts** resets the dictation key to Fn and alternate finish to Automatic, without touching translation, recording mode, AI settings, microphone, or other preferences. Reset cancels any active shortcut capture before changing bindings; buttons are disabled when already at their defaults or while dictation is active.

Press the alternate key by itself or while holding the primary dictation key. It finishes immediately, even if you then add another key for an application shortcut. Already-held unrelated modifiers or non-modifier keys prevent alternate finish; alternate-key events still pass through to the focused app.

## Selected-text translation

Select text in the foreground app, then use the configurable translation shortcut (default Control-Option-T). Talkless reads the selection through Accessibility, falling back to Copy, sends it to the configured AI provider, and shows a panel with Copy and Replace Original actions. Translation requires a configured **AI service**, not the dictation polishing toggle. The shortcut supports recorded modifier-plus-key combinations and an independent **Reset** to Control-Option-T; clearing it disables the shortcut and removes its menu reference row.

**Settings > Translation** and the translation panel share remembered source and target choices, both initially **Auto**. They are independent of the interface and dictation output languages:

- Source Auto detects the language locally. Short, mixed or uncertain text may remain unidentified; target Auto then uses the primary language. Choose an explicit source to correct detection.
- Target Auto translates into the primary language, or into the secondary language when the source already belongs to the primary language's family. Primary Auto follows the first supported macOS language, falling back to English. Secondary Auto uses English, or Simplified Chinese when primary is English. A duplicated primary/secondary family uses that same alternate fallback.
- Simplified and Traditional Chinese count as one family for Auto direction. Explicit targets still allow script conversion. An exact source/target match returns the original text without a provider request.

Language menus offer 50 curated choices, with 13 preferred by default, plus **More languages**. In Settings, **Manage languages…** lets you search and save a preferred list; Cancel discards edits, and primary, secondary and currently selected languages stay accessible even when unchecked. This is a menu catalog, not a guarantee of provider language support or translation quality.

Changing a language or using Swap languages in the panel remembers the choices and translates the **original selection** again, not the previous result. These explicit actions can make another provider request and incur charges; opening settings or changing the interface language does not. Closing the panel or making a newer request cancels pending work and discards stale results. Swap is unavailable when the source is unknown or both resolved languages are identical.

## Recognition

**Settings > Dictation > Audio > Microphone** defaults to System default, or can target a named input device. Selection is saved by stable device UID and applied to the next recording without changing the system-wide microphone. The list refreshes while settings are visible. A missing explicit device stops recording setup with an error rather than silently using another microphone. Audio configuration notifications are checked rather than automatically treated as disconnections. A healthy unchanged microphone keeps recording; an actual route/format change or stopped engine interrupts an established recording and discards partial audio. Before any audio arrives, Talkless can retry startup once. If no audio arrives within three seconds of an engine starting, it reports an error instead of appearing to record indefinitely; a permitted startup retry receives its own three-second allowance. Reset restores System default.

**Settings > Speech recognition** selects local Qwen (the default), Apple on-device recognition, or a cloud Whisper-compatible API. Qwen requires an explicitly downloaded model; Apple may download its required speech assets on first use. Cloud recognition uploads recorded audio and dictionary hints to the configured provider and may incur charges. The local Qwen pipeline works as follows:

- Qwen runs in-process, not through Python or a CLI subprocess. The selected installed model is prepared at startup and after download/selection, then kept in memory between dictations. Stopping recording does not unload weights; model changes, deletion or process exit release them.
- Raw Qwen language/control headers are parsed before display. Incomplete headers never become transcript text; malformed final headers produce an error rather than inserting metadata. Literal words such as `language English` inside the transcript remain untouched.
- Audio callbacks copy PCM into a background queue. One actor serializes MLX model access.
- Live text is a replaceable snapshot of the current acoustic window, decoded approximately every two seconds of new audio.
- Windows are up to 30 seconds. Long dictations commit at a nearby low-energy boundary when available, retaining all remaining audio without acoustic overlap. Silence is not removed and does not stop recording.
- Stopping finishes the active window only. Previously committed windows are not decoded again.
- This is not a complete port of `mlx-qwen3-asr`'s encoder/KV prefix cache. Long uninterrupted speech may still split a word at a window boundary.
- Completed dictation is pasted directly at the current input cursor using the clipboard and Command-V. It does not require reading or matching the original accessibility element or selection, and does not force focus back to the original app. Cancellation still prevents stale results from being pasted. Clipboard restoration and local history remain enabled.

## Overlay

Dictation is silent: no start/stop sounds or routine success/empty-result messages. The HUD wraps live text within a maximum of 380 by 174 points, keeping the latest lines visible. After recording stops, it shows **Recognizing**, then **Polishing** only while AI polishing runs, or **Editing** for selected-text voice editing. By default it stays at the bottom center of the active display, keeping the same display through recording and processing without reading caret geometry. Enable **Follow text cursor** in Overlay settings to opt into caret tracking; unavailable caret geometry falls back to the screen bottom. It hides on completion; actionable errors remain visible.

**Settings > Overlay** provides a live sample preview with recording, recognizing, and polishing stages and short or long text. Choose a translucent or solid backdrop, adjust translucent background-only opacity from 20% to 100%, and toggle indicator animations. Solid is always opaque. Changes persist and apply immediately without recording audio or contacting a provider. Text and icons are not faded; macOS Reduce Transparency and Reduce Motion take priority. Reset appearance restores the defaults. The real overlay remains click-through and never takes focus.

The menu bar uses the app's own waveform-and-caret mark in every state, without the colored app tile. A filled dot indicates recording and an outlined dot indicates processing. Template rendering adapts to light, dark, and selected menu bar appearances; accessible labels describe the current state.

## AI polishing

**Settings > Dictation > AI processing** holds the polishing toggle, output language, app-aware tone, and additional instructions. Output language applies when dictation uses AI polishing, including a one-off alternate finish. Selected-text voice editing has its own **Voice editing** section on the same page. **Settings > AI service** configures their shared provider, also used by translation; configuring it does not turn on dictation polishing or voice editing.

The shared AI service supports DeepSeek, OpenAI (Responses or Chat Completions), OpenRouter, native Gemini, native Anthropic, and a custom API endpoint. Provider settings are independent; keys are stored in macOS Keychain. Fetch Models fills a picker when the endpoint supports discovery, with manual model IDs as a fallback. Connection testing sends only an explicit fixed test. See [provider configuration and privacy](ai-polish.md).

OpenRouter starts with `https://openrouter.ai/api/v1` and `openrouter/free`; add your own OpenRouter API key. The free router selects from changing free models, not a guaranteed DeepSeek endpoint. Free-tier limits and availability vary. Talkless does not configure paid fallbacks; manually choosing another model may incur charges. See [OpenRouter's free router](https://openrouter.ai/openrouter/free).

Dictionary has separate My terms and Review sections. Search, add, edit, or delete confirmed spellings in My terms; existing newline-based terms are retained and capitalization is preserved. Only confirmed terms are passed to local Qwen, Apple and API speech recognition, and to AI polishing. They are hints rather than forced replacements.

Review compares saved raw dictation with polished output locally to suggest small spelling corrections, including Chinese and Latin terms. Each candidate shows the heard/polished evidence and the number of distinct dictations. Accept adds that spelling to My terms; Dismiss stays hidden until an explicit reset. Suggestions are never accepted automatically. Scan history runs once on demand; automatic local suggestions are opt-in and off by default. Scanning uses up to 500 recent history entries, excludes edits/translations and large rewrites, displays up to 100 candidates, and makes no network or additional AI requests. AI changes are evidence, not ground truth: review each spelling before accepting. Talkless does not monitor edits made in other apps after pasting.

## Daily activity

**Settings > History** shows a calendar heatmap of completed dictation, starting with this feature's first launch. Older transcript history is not imported. Click the character, dictation, or recorded-time summary to choose the calendar metric. The period selector shows approximately three months, six months, or a year (13, 26, or 52 weeks). Hover, focus, or click a day for its details; the Activity options menu provides the exact daily table, tracking information, and Clear activity. Fixed intensity thresholds keep colors consistent when changing the date range. Edits and translations are excluded; characters count final output graphemes, not words or model tokens.

Daily totals are retained for 400 calendar days in local `activity.json`, using the time zone captured when tracking starts. The file contains counts, durations, dates, and a bounded set of recent entry IDs, not transcript text or audio. Dates before tracking began are shown as Not recorded; the initial day counts only since tracking began. Clear history removes saved transcripts but keeps daily totals. Clear activity separately confirms deletion of totals and starts a fresh baseline without importing older history.

## Updates

**Settings > System > Updates** offers Stable and Beta channels. Returning to Stable does not downgrade an installed beta. "Automatically check for updates" is enabled by default for new preferences and checks the selected channel every 30 minutes while Talkless is running. Existing automatic-check preferences are preserved. Checks during dictation or another update session wait until the next interval; manual checking remains available when idle. You choose when to download and install. Turning off automatic checks does not cancel an update already in progress. Local builds without valid update feed URLs and a signing public key cannot check for updates.

The page also shows the installed version/build and **Last checked**, which records the last attempt, including unsuccessful checks, not proof that the app is current. **Show update…** returns to an active update window when available. Sparkle retains its standard release-note, download and install UI; new releases provide versioned English and Simplified Chinese notes.

The [release workflow](releasing.md) defaults to Beta for trusted pushes to `main`; Stable requires an explicit version tag. Both require reviewed [English](../CHANGELOG.md) and [Simplified Chinese](../CHANGELOG.zh-Hans.md) changelog entries. Publication still depends on a successful release job.

## Local data and privacy

Talkless does not use a `~/.talkless` configuration directory:

- **UserDefaults:** app preferences, provider endpoints/model IDs, confirmed dictionary terms and dismissed suggestions.
- **macOS Keychain:** AI polishing keys. The separate legacy **cloud ASR key is still stored in plaintext in UserDefaults**, not Keychain.
- **`~/Library/Application Support/Talkless/`:** managed models in `Models/`, up to 500 text-only history entries in `history.json`, text-free daily totals in `activity.json`, and rotating event logs in `Diagnostics/`. History includes raw and final text, the app name, and timing metadata, not audio. Delete entries or clear them in Settings > History.

Local Qwen recognition does not upload audio. Optional cloud recognition sends audio; AI polishing, voice editing and translation send the text/context needed for those requests. See [provider privacy](ai-polish.md) and [diagnostics export](diagnostics.md) before sharing data.

## Reproducible checks

Model weights, generated recordings, local results, dependencies, and build products are excluded from Git. Swift packages are locked in `Package.resolved`; third-party source is fetched rather than committed. First-party source, tests and documentation stay English, except approved `Localizable.strings` and `InfoPlist.strings` under `Sources/Talkless/Resources/en.lproj/` and `zh-Hans.lproj/`, and the root `CHANGELOG.zh-Hans.md`. UI translations belong in those catalogs, not inline source text; Mandarin recognition remains supported.

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

Local ASR state tests cover sample preservation across windows, tail delivery, replaceable preview, cancellation/stale callbacks, bounded backlog, finish completion races, and boundary selection. Optional [live polishing tests](ai-polish.md#optional-live-polishing-smoke-tests) are separate, explicitly opt-in, and may incur API charges.
