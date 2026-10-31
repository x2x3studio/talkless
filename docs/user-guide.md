# Talkless user guide

[Back to Talkless](../README.md)

Talkless puts spoken words into the app you are using. It runs in the macOS menu bar, not as an input method, and is distributed directly rather than through the Mac App Store.

## Install and set up

Requires **Apple Silicon and macOS 26 or later**. You do not need Xcode to use a release build.

1. Download the DMG from [Releases](https://github.com/x2x3studio/talkless/releases). Beta builds are marked **Pre-release**.
2. Drag Talkless to **Applications** and open that copy.
3. Follow the **Setup guide** to learn the controls and allow **Microphone** and **Accessibility** access. Microphone records your voice; Accessibility enables global shortcuts and text insertion.
4. Open **Settings > Speech recognition**, download the local Qwen model, and wait for it to finish verifying and preparing.
5. Click a text field in another app, hold **Fn**, speak, and release. Wait for recognition to finish and the text to appear.

Permissions and downloads require your action. You can continue past any setup step or choose **Skip setup**, but unfinished essentials still need attention before dictation works. AI polishing is optional and off by default; the guide does not test providers or send audio or text. Its optional **Launch at login** step uses the same macOS login-item setting as System preferences. Enable it explicitly to start Talkless when you sign in; continuing or skipping does not change it. Existing login-item choices are preserved, and macOS approval or registration errors remain visible.

Reopen the guide from **Settings > System > Setup guide** without resetting your preferences. It shows your current shortcuts and readiness. Apple recognition, cloud recognition, and custom model folders are not verified by the guide; review those in Speech recognition settings. Existing installations are not forced through setup after an update.

If macOS opens the emoji panel when you press Fn, set the Globe-key action to **Do Nothing** in **System Settings > Keyboard**, or choose another dictation key.

## Find your settings

Click Talkless's menu bar icon and choose **Settings…**. The menu also offers **Check for Updates…** and **Quit Talkless**. **Start Dictation** starts hands-free dictation into the app you were using; its subtitle shows your actual key and gesture, such as **Hold Fn / Globe** or **Tap Fn / Globe**. While recording it becomes **Finish Dictation**. **Translate selection** translates the selected text in the frontmost app; its subtitle shows the translation shortcut when one is set. If Accessibility or Microphone permission is missing, or the selected local speech model is not downloaded, a warning row appears at the top of the menu; click it to open the right setting. Trying to dictate or translate while a permission is missing also opens that System Settings pane; dictated text is copied so you can paste it with ⌘V. Opening Talkless again while it is running shows Settings (or the setup guide if setup is unfinished). AI polishing controls are in Dictation settings, not a separate menu row.

| Settings page | What you can change |
| --- | --- |
| **Dictation** | Microphone, recording mode and keys, AI polishing, output language, app-aware tone, additional instructions, voice editing |
| **Translation** | Source and target languages, automatic direction, preferred languages, translation shortcut |
| **Speech recognition** | Recognition engine, local model downloads, Apple recognition language, cloud recognition connection |
| **AI service** | Shared provider, credentials and model for polishing, voice editing and translation |
| **Dictionary** | Confirmed terms and suggested spelling corrections |
| **Overlay** | Preview, backdrop, opacity, animations and cursor following |
| **History** | Saved results and daily dictation activity |
| **System** | Interface language, permissions, setup guide, launch at login and diagnostics |
| **About** | Installed version/build, updates, website and source-code links |

### Interface language and startup

**System > Language > Interface language** offers **Follow System** (the default), **English**, and **Simplified Chinese**. Changes apply without restarting. They do not change recognition, dictation output or translation languages. Follow System uses the first supported macOS language, falling back to English; a Traditional Chinese preference is not treated as Simplified Chinese.

**System > Startup > Launch at login** starts Talkless when you sign in. It is not enabled automatically. If macOS requires approval, use **Open Login Items**; the displayed state follows macOS's login-item setting.

## Dictation and shortcuts

### Recording controls

Choose **Settings > Dictation > Recording**:

| Control | Behavior |
| --- | --- |
| **Hold to talk** — default | Hold the dictation key to record; release to finish. |
| **Tap to toggle** | Press once to start; press again to finish. |
| **Escape** | Cancel recording or processing without inserting the pending result. |
| **AI polishing shortcut** | Finish recording and use or skip AI polishing for this input only, without changing your default. |

Talkless does not stop recording when you pause. There is no timing-based automatic recording mode. Recording mode and the default polishing choice are captured when you start.

Local Qwen and Apple recognition show live text in the overlay; cloud recognition transcribes after you finish. The final text is pasted using the clipboard and Command-V. Keep the intended text field focused until it arrives: dictation uses the **current cursor**, rather than restoring focus to the app where you started. The previous clipboard contents are restored unless you copied something else in the meantime. If you need the result again, use History.

### One-off AI polishing

There are two choices: **Use AI polishing** or **Skip AI polishing**. Finishing with your dictation key follows the default captured when recording starts.

By default, **Fn** records and **Right Option** is the **AI polishing shortcut**. While recording, press Right Option to end the recording and choose the action shown next to that key:

- With polishing **off** by default, the key shows **Use AI polishing** and requests polishing for this input.
- With polishing **on** by default, the key shows **Skip AI polishing** and uses the original transcript for this input.

Press it by itself in toggle mode, or while still holding the dictation key in hold mode. This affects **only the current input** and never changes your saved default. **Dictation > Recording** and the setup guide name the action directly; the overlay does not show shortcut instructions or a polishing-toggle footer. The shortcut does nothing while idle and is unavailable during selected-text voice editing. If polishing fails or is not configured, Talkless keeps the original transcript.

### Change or reset shortcuts

In **Dictation > Recording**, click a shortcut field, press and release **Fn**, **Right Option**, **Right Command**, or **Right Control**. The dictation key and AI polishing shortcut support only these single keys, not combinations. Escape cancels capture; Delete or Backspace clears the AI polishing shortcut. The dictation key cannot be cleared, and the two keys cannot be the same.

The AI polishing shortcut's **Automatic** default uses Right Option, or Right Command if Right Option is your dictation key. Each row has its own **Reset**. **Reset recording shortcuts** restores Fn and Automatic without changing recording mode, translation or other settings. A reset that conflicts with the other custom key is rejected rather than overwriting it. Shortcut changes are unavailable during dictation.

Use the AI polishing shortcut without unrelated keys already held. Its key event also passes through to the foreground app.

### Choose a microphone

**Dictation > Audio > Microphone** defaults to **System default**. You can choose a specific input device without changing the Mac's system-wide microphone. Changes apply to the next recording; **Reset** restores System default.

An unavailable chosen microphone is not silently replaced. Reconnect it or choose another. If the input route changes or disconnects during an established recording, Talkless stops and discards that interrupted recording; check the microphone and start again. A microphone that supplies no audio reports an error rather than recording indefinitely.

## Choose speech recognition

Open **Settings > Speech recognition**:

- **Qwen3-ASR (local, offline)** is the default. The built-in model is **Qwen3 ASR · 0.6B**, in MLX 4-bit format, with an approximately **713 MB** download. It runs on your Mac and stays loaded between dictations. Model weights are not included in the app or app updates.
- **Apple on-device recognition (offline)** offers a recognition **Language** picker and **Download Speech Model**. Required language assets may also be downloaded on first use.
- **Cloud Whisper-compatible API** uses a separate API URL, API key and model. Presets are available for OpenAI, Groq and SiliconFlow. It uploads the full recording after you finish, along with dictionary hints, and may incur provider charges. These settings are separate from **AI service**.

Local model downloads support progress, cancel/resume, retry, selection with **Use**, and confirmed deletion. Choose Hugging Face, HF Mirror, or a custom Hugging Face-compatible HTTPS mirror. HF Mirror may redirect to Hugging Face; availability depends on your network. Files are verified before use. Advanced settings also allow an explicit custom MLX model folder.

See [model management](model-management.md) for download sources, storage and custom-folder requirements.

## Optional AI processing

Configure **Settings > AI service** with your provider, credentials and model. This connection is shared by polishing, voice editing and translation; configuring it does **not** enable the first two features. Translation works independently of the polishing toggle. Requests use your own provider and may incur charges. See [AI providers and privacy](ai-polish.md) for supported services, connection testing and exactly what is sent.

### Polish dictation

In **Dictation > AI processing**, enable **Polish dictation with AI** to clean up recognized text before insertion. It is off by default.

- **Output language:** Keep original language, Simplified Chinese, English, or Japanese. This applies only when polishing runs, including when you choose **Use AI polishing** for one input. It is not a recognition-language setting.
- **Adapt tone to the current app:** tailor polished text to chat, email, code or documents. This is on by default, but only has an effect when polishing runs.
- **Additional instructions:** add writing preferences, such as “Always use digits for numbers.”

If polishing fails, the raw transcript is inserted instead, with a brief error message.

### Edit selected text by voice

1. Enable **Dictation > Voice editing > Edit selected text with your voice**. It is off by default and works with polishing off.
2. Select text in the foreground app.
3. Use your dictation key and speak an instruction, such as “Make this shorter.” Finish normally.
4. Keep the selection and text field in place while Talkless processes and pastes the edited result.

Voice editing requires a configured AI service and a selection readable through Accessibility. Some apps do not expose selections this way. If Talkless cannot read the selection, it records ordinary dictation instead; unlike translation, voice editing does not use a Copy fallback. A voice-editing request that fails shows an error rather than pasting the spoken instruction as a replacement.

## Selected-text translation

1. Configure **AI service**.
2. Select text in another app and press **Control-Option-T**.
3. Review the translation panel, then choose **Copy** or **Replace Original**. Keep the original selection in place if replacing it.

Talkless reads the selection through Accessibility, falling back to Copy when needed. Translation does not record audio. **Close**, Escape, or clicking outside the panel dismisses it and cancels pending work. Copy and Replace Original also close the panel. Replacement is blocked if the foreground app has changed. Completed provider translations are saved in History even if you do not copy or replace them.

### Languages and automatic direction

**Settings > Translation** and the translation panel share remembered **Source language** and **Target language** choices. Both start at **Auto**, independently of interface language and dictation output language.

- **Source Auto** detects language locally. For short, mixed or uncertain text, choose an explicit source if needed.
- **Target Auto** translates into your **Primary language**, or into your **Secondary language** when the source already belongs to the primary language's family. An uncertain source uses the primary language.
- **Primary Auto** follows the first supported macOS language, falling back to English. **Secondary Auto** uses English, or Simplified Chinese when primary is English. An explicitly duplicated primary/secondary language uses that same alternate fallback.
- Simplified and Traditional Chinese count as one family for automatic direction. Explicit targets still allow script conversion. Choosing an explicit source and the exact same target returns the original text without a provider request; an AI service must still be configured.

Language menus offer **50 named languages**, with 13 preferred by default and the rest under **More languages**. **Manage languages…** lets you search, select preferred languages, restore defaults, and save or cancel changes. Primary, secondary and selected languages remain accessible even if unchecked. The target menu also has **Custom language…** for a language name outside the list. Availability in a menu does not guarantee your AI model's support or quality.

Changing a language in the panel or using **Swap languages** translates the **original selection again**, not the previous result. These actions update your saved choices and may make another chargeable request. Swap is unavailable for an unknown source, a custom target, or identical resolved languages. Changing settings alone does not start a translation.

### Translation shortcut

Under **Translation > Keyboard shortcut**, click the shortcut field and record a combination containing Command, Control or Option plus a supported non-modifier key. Reserved macOS combinations are rejected. Escape cancels capture; Delete or Backspace clears and disables the shortcut. **Reset** restores Control-Option-T without changing recording shortcuts. Disabled translation shortcuts are omitted from the menu bar reference.

## Personal dictionary

Open **Settings > Dictionary**:

- **My terms:** search, add, edit or delete preferred spellings for names, projects and technical terms. Capitalization and spaces within a term are preserved. Confirmed terms are hints for recognition and AI processing.
- **Often heard as:** when editing a term, list spellings recognition keeps producing instead (one per line), such as `talk less` or a Chinese transliteration for **Talkless**. After recognition, and before any AI polishing, those exact spellings are replaced with the term—so fixes work with polishing off, show in the live preview, and appear under the term as **Fixes**. Matching ignores case and full-width forms; Latin spellings match whole words only, Chinese spellings match anywhere. A spelling must be at least two characters, cannot be a confirmed term, and can fix only one term. Deleting a term removes its fixes.
- **Import… / Export…** (the **⋯** menu) use plain UTF-8 text: one term per line, optionally followed by `= heard, heard`. Lines starting with `#` are ignored. Import only adds new terms and fixes; it never deletes or changes existing ones, and reports skipped entries.
- **Review:** choose **Scan history** for a one-time local comparison of raw dictation and saved polished output, or enable **Automatically find suggestions in local history**. Automatic scanning is off by default.

Review shows small spelling changes with **Heard** and **Polished** evidence and the number of distinct dictations. **Accept** adds the spelling to My terms. **Always fix** also adds the heard spelling as a fix, so it is replaced every time. **Dismiss** hides it until you explicitly reset dismissals. Nothing is accepted automatically: AI edits can be wrong, so accept only spellings you recognize.

Scanning considers up to 500 recent history entries and shows up to 100 suggestions, excluding voice-edit and translation entries and most large rewrites. It compares original and final dictation text locally, looking for short spelling substitutions rather than insertions, deletions, punctuation-only edits or common inflections. Suggestions are ranked by how many distinct dictations contain the candidate, then by recency. Dictation polished into another language is still a dictation entry, so the heuristics are not proof of a correct spelling. It makes no network or additional AI requests. Talkless does not monitor corrections you make in other apps after pasting.

### Dictionary words in live transcription

During ordinary dictation, words matching your confirmed dictionary have a **blue underline and subtle background** in the overlay. Matching continues through recognition, polishing, insertion and the brief completed-result display. This means **the spelling appears in the displayed text**, not that the recognizer or AI used a dictionary hint to correct a mistake. The dictionary is captured when recording starts; edits apply to the next recording. Unaccepted review suggestions are not highlighted.

Matching respects capitalization and word boundaries for Latin terms, and uses direct character matching for Chinese terms. Longer overlapping terms take precedence. Highlights update as provisional recognition or final output changes. To keep long recordings responsive, dictionary highlighting scans the latest 1,024 characters; terms starting before that window are not annotated. The full transcript, paste output and saved history are unchanged.

Live highlighting requires an engine that supplies partial text (local Qwen or Apple). Cloud recognition has no live partials, but its final transcript can be annotated after recognition. Voice-editing text, empty-state labels and errors are not annotated. Amber AI-change highlighting is separate from dictionary matching; a changed dictionary term can have both an amber background and a blue underline. Dictionary Review still provides saved before/after spelling evidence.

## Overlay

The overlay keeps your latest transcript visible through recognition and AI processing instead of replacing it with a status message. Long dictation shows the latest lines. A small icon on the left indicates the phase: recording and final recognition share a waveform and the accessible label **Dictating**; polishing uses sparkles and voice editing uses a pencil. A text status appears only when there is no transcript yet. There are no start/stop sounds or shortcut-hint footer.

The final text appears with a checkmark during insertion, which stays with dismissal scheduled after **50 ms**. This is best-effort scheduling, not an exact real-time duration. The confirmation does not delay insertion or block another recording; starting again replaces the completed result. Empty recognition and cancellation dismiss the overlay without a completed result. Errors replace the text briefly and **disappear after about three seconds**.

### Final AI changes

After ordinary dictation is polished or dictionary fixes apply, **amber backgrounds** mark literal additions and replacements in the final output compared with the finalized recognition transcript (before dictionary fixes, so fixes are marked too)—not changes between live recognition partials. Dictionary matches retain their blue underline. These are text differences, **not grammar or spelling judgments**, and there are no grammar/spelling wavy underlines. Voice-editing results are not annotated this way.

Whitespace-only changes and whole-word deletions leave no colored span in the result. A shortened word such as “colour” → “color” is a replacement and is highlighted as a whole word. For responsiveness, revision highlighting is skipped if either input exceeds **512 visible comparison tokens or 64 KiB of UTF-8 text**. These are local comparison tokens, not provider billing tokens. The output is never truncated or changed by this limit. Review History for the full result and raw transcript.

### Appearance and preview

By default the overlay stays at the bottom center of the active display through recording and processing. It never takes focus, and clicks pass through. The menu bar icon adds a filled dot while recording and an outlined dot while processing.

**Settings > Overlay** includes a sample-only live preview with **Dictating**, **Polishing**, **Editing** and **Completed** stages. Dictating represents recording and final recognition together. Choose **Short**, **Long** or **Dictionary match** text; Completed demonstrates final changes in the short and dictionary samples. The dictionary sample uses a fixed demo word, not your saved terms. No audio is recorded and no provider is contacted by the preview.

- Choose **Translucent** or **Solid** backdrop.
- Set translucent background opacity from **20% to 100%**; text and icons stay opaque. Solid is always opaque.
- Toggle **Animate status indicators**.
- Enable **Follow text cursor** to position the overlay near the caret when available, falling back to the screen bottom.
- Use **Reset appearance** to restore defaults: translucent, 90% background opacity, animations on, cursor following off.

Changes apply immediately. macOS **Reduce Transparency** and **Reduce Motion** take priority over the corresponding appearance preferences.

## History and daily activity

### Recover or delete text

**Settings > History > Recent history** keeps up to **500** recent dictations, voice edits and translations, with the app name and date. Dictation entries also show raw text when it differs from the result.

Search filters entries by result, raw text or app name. The copy button on each entry copies its result; right-click an entry for **Copy Result**, **Copy Raw Transcript**, or **Delete**. After a dictation in this session, the menu bar menu also offers **Copy Last Result**. For a voice edit, the raw text is the spoken instruction; for a translation, it is the original selection. **Clear history…** deletes all saved entries after confirmation. History contains text, not audio.

### View activity

The **Activity** section above history counts completed **dictations only**, not voice edits or translations:

- Click **Characters**, **Dictations**, or **Minutes** to choose the calendar metric. Characters are final-text characters, not words or model tokens; minutes are recorded audio time.
- Choose **Last 3 months**, **Last 6 months**, or **Last year** (13, 26 or 52 weeks).
- Hover, focus or click a day for details. The **Activity options** menu offers **Show daily table**, **About these statistics**, and **Clear activity…**.

Activity records new dictations from its tracking start date; older history is not imported. Days before tracking began are **Not recorded**, not zero. The first day and today may be partial. Daily totals stay on your Mac for 400 calendar days, using the time zone captured when tracking began, without transcript text or audio.

**Clearing or deleting history does not clear activity.** Clear activity separately confirms deletion of totals and starts a new baseline; it does not delete transcripts or import older history.

## Updates and troubleshooting

**Settings > About > Updates** shows the installed version/build, update channel and last check attempt. Choose **Stable** or **Beta**; returning to Stable does not downgrade an installed beta. **About > Project** links to the [website](https://typeless.x2x3.com) and source repository. The website hosts the [guide](https://typeless.x2x3.com/guide), [privacy details](https://typeless.x2x3.com/privacy) and [updates](https://typeless.x2x3.com/updates).

Automatic checks are on by default for new preferences and run every **30 minutes** while Talkless is running. Checks during dictation or an active update session wait until a later interval. You choose when to download and install. Turning automatic checks off does not cancel an update in progress. **Last checked** is the time of the last attempt, not proof that you are up to date. Use **Check for Updates…**, or **Show update…** when an update window is already available.

For permission problems, open **System > Permissions**. Allow Talkless in macOS **Privacy & Security > Microphone** and **Accessibility**, then return to Talkless. If macOS asks you to quit and reopen the app, do so. Check the chosen microphone and speech model if recording still cannot start.

**System > Diagnostics** offers **Export diagnostics…**, **Open logs**, and **Open crash reports**. Exports create a local ZIP; nothing is uploaded automatically. Optional macOS crash reports may contain personal information and file paths. See [troubleshooting and diagnostics](diagnostics.md) before sharing an export.

## Local data and privacy

Local Qwen recognition does not upload audio. Apple recognition runs on-device after its required assets are available. Cloud recognition uploads recorded audio; optional AI features send the text and context needed for their requests. Review [AI providers and privacy](ai-polish.md) for details.

Talkless stores:

- **App preferences:** settings, provider endpoints/model IDs, dictionary terms, dictionary fixes and dismissed suggestions in macOS UserDefaults.
- **AI service credentials:** API keys in macOS Keychain. The separate **cloud speech-recognition key is stored in plaintext in UserDefaults**, not Keychain.
- **`~/Library/Application Support/Talkless/`:** managed models in `Models/`, text history in `history.json`, text-free daily totals in `activity.json`, and rotating event logs in `Diagnostics/`.

Logs exclude audio, transcripts, API keys and request contents. Use History's deletion controls for saved text and **Clear activity** for daily totals. Talkless does not use a `~/.talkless` configuration folder.

For building and testing from source, see the [README's development section](../README.md#development); signing and distribution are covered in [release documentation](releasing.md).
