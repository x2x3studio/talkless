# Talkless user guide

[Back to Talkless](../README.md)

Talkless puts spoken words into the app you are using. It runs in the macOS menu bar, not as an input method, and is distributed directly rather than through the Mac App Store.

## Install and set up

Requires **Apple Silicon and macOS 26 or later**. You do not need Xcode to use a release build.

1. Download the DMG from [Releases](https://github.com/x2x3studio/talkless/releases). Beta builds are marked **Pre-release**.
2. Drag Talkless to **Applications** and open that copy.
3. Follow the **Setup guide** to learn the controls and allow **Microphone** and **Accessibility** access. Microphone records your voice; Accessibility enables global shortcuts and text insertion.
4. In the guide's **Speech recognition** step, choose **Offline** and click **Download** for the local model (recommended), or choose **Doubao online** and paste your Speech API key. The optional **AI polishing** step turns on AI cleanup and sets up your provider and key in place.
5. Click a text field in another app, hold **Fn**, speak, and release. Wait for recognition to finish and the text to appear.

Permissions and downloads require your action. You can continue past any setup step or choose **Skip setup**, but unfinished essentials still need attention before dictation works. AI polishing is optional and off by default; the guide sends audio or text only when you click a Test button. Its optional **Launch at login** step uses the same macOS login-item setting as System preferences. Enable it explicitly to start Talkless when you sign in; continuing or skipping does not change it. Existing login-item choices are preserved, and macOS approval or registration errors remain visible.

Reopen the guide from **Settings > System > Setup guide** without resetting your preferences. It shows your current shortcuts and readiness. A saved Doubao key counts as set up without a test request; custom model folders are reviewed under **Voice input > Speech recognition**. Existing installations are not forced through setup after an update.

If macOS opens the emoji panel when you press Fn, set the Globe-key action to **Do Nothing** in **System Settings > Keyboard**, or choose another dictation key.

## Find your settings

Click Talkless's menu bar icon and choose **Settings...**. The menu also offers **Check for Updates...** (shown as **Update to VERSION...** when a new version was found) and **Quit Talkless**. **Start Dictation** starts hands-free dictation into the app you were using; its subtitle shows your actual key and gesture, such as **Hold Fn / Globe** or **Tap Fn / Globe**. While recording it becomes **Finish Dictation**. **Translate selection** translates the selected text in the frontmost app; its subtitle shows the translation shortcut when one is set. If Accessibility or Microphone permission is missing, or the selected local speech model is not downloaded, a warning row appears at the top of the menu; click it to open the right setting. Trying to dictate or translate while a permission is missing also opens that System Settings pane. If insertion is blocked after recognition, the result is saved in History rather than replacing your clipboard. Opening Talkless again while it is running shows Settings (or the setup guide if setup is unfinished). AI polishing controls have their own Settings page, not a separate menu row.

Settings pages are grouped in the sidebar: **Voice input** (Voice input, AI polishing, Text formatting, Dictionary, Overlay), **Tools** (History, Translation) and **General** (System, Labs, About). Speech recognition is a section of Voice input, not a separate page.

| Settings page | What you can change |
| --- | --- |
| **Voice input** | Microphone first, then recording mode and key, followed by local Qwen or online Doubao recognition, model downloads and Speech credentials |
| **AI polishing** | Polishing and voice-editing switches, output language, app-aware tone, additional instructions, and the shared AI provider, credentials and model |
| **Text formatting** | Local punctuation and spacing rules, independent of AI |
| **Dictionary** | Confirmed terms, heard-as fixes, import/export and suggested spelling corrections |
| **Overlay** | Preview, backdrop, opacity, animations and cursor following |
| **History** | Daily dictation activity, and saved results grouped by day with search and type filters |
| **Translation** | Source and target languages, automatic direction, preferred languages, translation shortcut |
| **System** | Interface language, permissions, setup guide, launch at login and diagnostics |
| **Labs** | Independent experimental enhanced-recognition and sentence-alternatives switches, plus candidate wait time |
| **About** | Installed version/build, updates, website and source-code links |

### Interface language and startup

**System > Language > Interface language** offers **Follow System** (the default), **English**, and **Simplified Chinese**. Changes apply without restarting. They do not change recognition, dictation output or translation languages. Follow System uses the first supported macOS language, falling back to English; a Traditional Chinese preference is not treated as Simplified Chinese.

**System > Startup > Launch at login** starts Talkless when you sign in. It is not enabled automatically. If macOS requires approval, use **Open Login Items**; the displayed state follows macOS's login-item setting.

## Dictation and shortcuts

### Recording controls

Choose **Settings > Voice input > Recording**:

| Control | Behavior |
| --- | --- |
| **Hold to talk** — default | Hold the dictation key to record; release to finish. |
| **Tap to toggle** | Press once to start; press again to finish. |
| **Escape** | Cancel recording or processing without inserting the pending result. |

Talkless does not stop recording when you pause. There is no timing-based automatic recording mode. Recording mode, AI/provider preferences, dictionary and local formatting are captured when you start; changes apply to the next recording. Ordinary dictation uses AI when **AI polishing** is on and configured, or when Labs **Enhanced recognition** is enabled. Otherwise it skips AI polishing.

Local Qwen and online Doubao both show live text in the overlay; Doubao streams audio while you speak and waits for its final response after recording ends. The final text is pasted using the clipboard and Command-V. Keep the **original app and intended text field** focused until it arrives. Talkless does not restore focus or pin the original cursor position; switching apps blocks insertion and saves the result in History.

Clipboard operations are serialized. After posting Command-V, Talkless waits a fixed **two-second compatibility grace period**, then restores the previous clipboard contents only if nothing else changed the clipboard. Cancellation after posting still lets that transaction settle. The wait is finite, does not depend on observing a clipboard read, and does not leave a permanent unresolved-paste lock. It is not proof that the destination accepted the text; a very slow app may miss the temporary contents. Use History to recover the result, and check the destination before pasting again.

### Change or reset shortcuts

In **Voice input > Recording**, click the **Dictation key** field, then press and release **Fn**, **Right Option**, **Right Command**, or **Right Control**. Only these single keys are supported, not combinations. Escape cancels capture, and the dictation key cannot be cleared. **Reset** restores Fn without changing recording mode, translation or other settings. Shortcut changes are unavailable during dictation.

### Choose a microphone

**Voice input > Microphone**, at the top of the page, defaults to **System default**. You can choose a specific input device without changing the Mac's system-wide microphone. Changes apply to the next recording; **Reset** restores System default.

An unavailable chosen microphone is not silently replaced. Reconnect it or choose another. If the input route changes or disconnects during an established recording, Talkless stops and discards that interrupted recording; check the microphone and start again. If audio buffers never arrive or stop arriving for about three seconds, Talkless cancels quietly rather than recording indefinitely. This is not a silence detector: a quiet microphone still supplies buffers.

## Choose speech recognition

Open **Settings > Voice input > Speech recognition**:

Pick one of two cards. With Labs **Enhanced recognition** off, your choice is the primary engine; Offline does not contact Doubao. Enhanced recognition instead uses both engines for ordinary dictation, regardless of the selected card.

- **Offline** (local Qwen3-ASR model on your Mac) is the default. The built-in model is **Qwen3 ASR · 0.6B**, in MLX 4-bit format, with an approximately **713 MB** download. It runs on your Mac and stays loaded between dictations. Model weights are not included in the app or app updates.
- **Doubao online** streams audio directly to Doubao's bidirectional ASR 2.0 service with live previews. Enter a Speech API key from the new Doubao Speech console, not an Ark/chat-model key. The endpoint and model are built in. Under **More options**, choose duration-based (default) or concurrent billing to match your enabled resource. The key stays in Keychain; these credentials are separate from **AI polishing**. Without local fallback, connection failure cancels recognition rather than inserting a partial transcript. The connection/upload stall limit is 10 seconds, and final recognition has a 15-second deadline after recording ends. Enable **Allow falling back to offline recognition** to keep an installed Qwen model in memory: when Doubao is unavailable (no key, network, rejected key, quota or timeout), that recording is recognized locally; the next recording still tries Doubao first. Without a downloaded model, the switch has no effect and Doubao recordings run without fallback. Selecting online with both fallback and Labs enhanced recognition off releases local model memory when idle, not model files.
- Retired Apple/Whisper-compatible selections fall back to local Qwen on upgrade. Old cloud keys are not reused or sent to Doubao; existing saved credentials are left untouched.

Local model downloads support progress, cancel/resume, retry, selection with **Use**, and confirmed deletion. Choose Hugging Face, HF Mirror, or a custom Hugging Face-compatible HTTPS mirror. HF Mirror may redirect to Hugging Face; availability depends on your network. Files are verified before use. Advanced settings also allow an explicit custom MLX model folder.

See [model management](model-management.md) for download sources, storage and custom-folder requirements.

## Optional AI processing

Configure **Settings > AI polishing** with your provider, credentials and model. This connection is shared by polishing, voice editing and translation; configuring it does **not** enable the first two features. Translation works independently of the polishing toggle. Requests use your own provider and may incur charges. See [AI providers and privacy](ai-polish.md) for supported services, connection testing and exactly what is sent.

### Polish dictation

In **Settings > AI polishing**, enable **AI polishing** to send recognized text to your provider for correction and polishing. It is off by default. Open **AI polishing preferences** for the options below. History keeps the pre-AI transcript after local dictionary fixes (**Copy Raw Transcript**); it is not an untouched recognizer output.

- **Output language:** Keep original language, Simplified Chinese, English, or Japanese. This applies only when polishing runs. It is not a recognition-language setting.
- **Adapt tone to the current app:** tailor polished text to chat, email, code or documents. This is on by default, but only has an effect when polishing runs.
- **Additional instructions:** add writing preferences, such as “Always use digits for numbers.”

Polishing requests have a **five-second deadline**, including enhanced recognition's AI comparison and sentence-alternatives requests. A timeout quietly falls back to the recognized text after dictionary fixes; other polishing failures also fall back but show a brief error. Local formatting still applies. This is not a five-second limit on recording, recognition, candidate review or the full insertion process. Voice editing and translation use separate error paths.

### Local text formatting

Two options in **Settings > Text formatting** apply on this Mac to every dictation, with or without AI polishing, as the last step before insertion. They do not need an AI service:

- **Punctuation:** Keep all punctuation (default), No punctuation at sentence end (drops a final period or comma on each line; question and exclamation marks stay), or Spaces instead of punctuation. Decimals, versions and URLs are never changed.
- **Spaces around numbers and English:** No spaces (default) or Spaces before and after, between Chinese and Latin words or numbers, for example around “Python” or “3” in a Chinese sentence.

### Edit selected text by voice

1. Enable **AI polishing > Edit text by voice**. It is off by default and is independent of the AI polishing switch.
2. Select text in the foreground app.
3. Hold your dictation key **together with Control** (Option when Right Control is your dictation key) and say how to change it, such as “Make this shorter” or “Translate into English.” You can also press Control after you start speaking. The overlay shows a blue pencil while editing. Finish normally.
4. Keep the selection and text field in place while Talkless processes and pastes the edited result.

Only this gesture edits. The dictation key alone always types your words, replacing a selection the way typing does, so fields that select their contents when focused (such as a browser address bar) are never mistaken for an edit. This follows the separate "command mode" shortcut that other voice-input tools use.

Voice editing requires a configured AI service. Talkless reads the selection through Accessibility. When an app does not report its selection, Talkless asks that app to copy (its own Edit › Copy menu item, or Command-C sent only to that app) and then restores your clipboard. Editors that copy the whole line when nothing is selected (such as VS Code) are recognized. If nothing is selected, the overlay says so and your words are typed as ordinary dictation. A voice-editing request that fails shows an error rather than pasting the spoken instruction as a replacement.

## Labs: enhanced recognition and sentence alternatives

**Settings > Labs** contains two independent switches, both off by default. These are experimental options, not proven improvements to recognition accuracy.

- **Enhanced recognition** requires an installed local Qwen model, configured Doubao Speech credentials and a configured AI service. For ordinary dictation it runs Qwen and Doubao together, even when **Offline** is selected, then asks AI to compare the available transcripts. Audio is sent to Doubao and text is sent to the AI provider. This path uses AI even if the separate **AI polishing** switch is off; it does not change that saved switch. It uses more memory and may take longer. The explicit voice-edit gesture uses the selected recognition engine instead.
- If one recognizer fails, enhanced recognition can continue with the other. After recording ends, it waits at most 20 seconds for recognition; once a nonempty result arrives, it allows at most two more seconds for the other recognizer, within that deadline. A nonempty online result received in time is primary; otherwise the local result is used. Both failing produces an error, not invented text. The subsequent AI request has the separate five-second deadline described above.
- **Sentence alternatives** requires AI polishing or enhanced recognition, plus an AI service. It can be used without enhanced recognition. The provider is asked for one conservative complete-text result, with up to three candidates only for unresolved ambiguity. One candidate inserts without a chooser; multiple candidates open **Choose a sentence**. Enabling the switch does not guarantee alternatives will appear.
- Click a complete candidate to use it. Differences from the default are emphasized for comparison, not marked as verified corrections. The nonactivating panel does not take keyboard focus. **Candidate wait** defaults to **5 seconds**, adjustable from **2 to 15 seconds**. Hovering inside pauses the countdown; leaving resumes it, and expiry uses the first/default candidate. Escape cancels the pending input. The countdown is separate from the AI request timeout.

## Selected-text translation

1. Configure **AI polishing**.
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

Open **Settings > Dictionary**. Every row reads **heard → written**: what recognition wrote by mistake, then the spelling you meant. Rows come from two places.

- **Learned automatically:** with **Learn from my dictations** on (the default), Talkless compares each dictation's recognized text with its AI-polished text on this Mac. When polish makes the same short spelling fix again, that fix takes effect: two dictations for most spellings, three for two-character Chinese words. A fix that has not been needed for 30 days retires on its own, for example once recognition starts getting the word right. If polish later changes a learned fix back, the fix retires immediately. Each row shows how often the mishearing was seen, how many dictations it fixed and when it was last needed. **Keep** moves the fix to your own entries so it never retires; the trash button deletes it and Talkless never learns that pair again. Corrections seen fewer times appear under **Watching** with how many more times they need, and **Learning log** lists what was learned or retired and when. Learning needs a successful same-language AI result, through polishing or enhanced recognition. When a sentence chooser appears, only an explicit click supplies learning evidence; the automatically chosen default does not. Existing local history is read once, the first time learning runs. Voice edits, translations and dictation polished into another language are never used. Nothing is sent anywhere and no extra AI request is made. Talkless does not watch corrections you make in other apps after pasting.
- **Added by you:** **Add…** creates an entry with **Heard as** (optional, one per line) and **Write as**. An entry with no heard spelling is a recognition hint only. Capitalization and spaces are preserved. Your entries never retire, and a learned fix never overrides them.

Learned and hand-written entries work the same way. After recognition, and before any AI polishing, heard spellings are replaced with the written form, so fixes work with polishing off and appear in the live preview. Matching ignores case and full-width forms; Latin spellings match whole words only, Chinese spellings match anywhere. A heard spelling must be at least two characters and can fix only one entry. The written forms are also sent as recognition hints to local Qwen and as context to AI polishing. These mechanisms do not establish an accuracy improvement; retirement means a learned fix has not been needed recently, not that recognition has been proven better.

**Import… / Export…** (the **⋯** menu) cover your own entries as plain UTF-8 text: one term per line, optionally followed by `= heard, heard`. Lines starting with `#` are ignored. Import only adds new terms and fixes; it never deletes or changes existing ones, and reports skipped entries.

### Dictionary words in live transcription

During ordinary dictation, words matching your confirmed dictionary have a **blue underline and subtle background** in the overlay. Matching continues through recognition, polishing, insertion and the brief completed-result display. This means **the spelling appears in the displayed text**, not that the recognizer or AI used a dictionary hint to correct a mistake. The dictionary is captured when recording starts; edits apply to the next recording. Spellings still being watched (not yet learned) are not highlighted.

Matching respects capitalization and word boundaries for Latin terms, and uses direct character matching for Chinese terms. Longer overlapping terms take precedence. Highlights update as provisional recognition or final output changes. To keep long recordings responsive, dictionary highlighting scans the latest 1,024 characters; terms starting before that window are not annotated. The full transcript, paste output and saved history are unchanged.

Both Qwen and Doubao supply live previews for dictionary highlighting. Qwen receives recognition hints; Doubao currently uses the local heard-as fixes and optional AI polishing dictionary, without uploading a separate hotword list. Voice-editing text, empty-state labels and errors are not annotated. Amber AI-change highlighting is separate from dictionary matching; a changed dictionary term can have both an amber background and a blue underline. Dictionary Review still provides saved before/after spelling evidence.

## Overlay

The overlay keeps your latest transcript visible through recognition and AI processing instead of replacing it with a status message. Long dictation shows the latest lines. A small icon on the left indicates the phase: recording and final recognition share a waveform and the accessible label **Dictating**; polishing uses sparkles; voice editing shows a blue pencil from the start of recording. A text status appears only when there is no transcript yet. There are no start/stop sounds or shortcut-hint footer.

The final text appears with a checkmark during insertion, which stays with dismissal scheduled after **50 ms**. This is best-effort scheduling, not an exact real-time duration. The confirmation does not delay insertion or block another recording; starting again replaces the completed result. Empty recognition and cancellation dismiss the overlay without a completed result. Errors replace the text briefly and **disappear after about three seconds**.

### Final AI changes

After ordinary dictation is polished or dictionary fixes apply, **amber backgrounds** mark literal additions and replacements in the final output compared with the finalized recognition transcript (before dictionary fixes, so fixes are marked too)—not changes between live recognition partials. Dictionary matches retain their blue underline. These are text differences, **not grammar or spelling judgments**, and there are no grammar/spelling wavy underlines. Voice-editing results are not annotated this way.

Whitespace-only changes and whole-word deletions leave no colored span in the result. A shortened word such as “colour” → “color” is a replacement and is highlighted as a whole word. For responsiveness, revision highlighting is skipped if either input exceeds **512 visible comparison tokens or 64 KiB of UTF-8 text**. These are local comparison tokens, not provider billing tokens. The output is never truncated or changed by this limit. Review History for the full result and raw transcript.

### Appearance and preview

By default the overlay stays at the bottom center of the active display through recording and processing. It never takes focus, and clicks pass through. Next to the menu bar cat, **?** means Talkless is listening, **!** means it is recognizing what you said, and **@** means the AI service is polishing or editing. The mark disappears when Talkless is idle.

**Settings > Overlay** includes a sample-only live preview with **Dictating**, **Polishing**, **Editing** and **Completed** stages. Dictating represents recording and final recognition together. Choose **Short**, **Long** or **Dictionary match** text; Completed demonstrates final changes in the short and dictionary samples. The dictionary sample uses a fixed demo word, not your saved terms. No audio is recorded and no provider is contacted by the preview.

- Choose **Translucent** or **Solid** backdrop.
- Set translucent background opacity from **20% to 100%**; text and icons stay opaque. Solid is always opaque.
- Toggle **Animate status indicators**.
- Enable **Follow text cursor** to position the overlay near the caret when available, falling back to the screen bottom.
- Use **Reset appearance** to restore defaults: translucent, 90% background opacity, animations on, cursor following off.

Changes apply immediately. macOS **Reduce Transparency** and **Reduce Motion** take priority over the corresponding appearance preferences.

## History and daily activity

### Recover or delete text

**Settings > History > Recent history** keeps up to **500** recent dictations, voice edits and translations, with the app name and date. Dictation entries also show raw text when it differs from the result. Entries are shown 50 per page; use the previous and next buttons below the list to turn pages. Searching or changing the type filter returns to the first page. The dictionary pages the same way.

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

Automatic checks are on by default for new preferences. While Talkless is running, the Beta channel checks every **6 hours** and Stable every **48 hours**, counted from the last check. Automatic checks only look for a new version; they never open a window. When one is found, the menu item and the About page change to **Update to VERSION…**. Clicking it fetches the update feed again, so you always get the newest build even if more releases shipped since the check. Checks during dictation or an active update session wait until a later interval. You choose when to download and install. Turning automatic checks off does not cancel an update in progress. **Last checked** is the time of the last attempt, not proof that you are up to date. Use **Check for Updates…**, or **Show update…** when an update window is already available.

For permission problems, open **System > Permissions**. Allow Talkless in macOS **Privacy & Security > Microphone** and **Accessibility**, then return to Talkless. If macOS asks you to quit and reopen the app, do so. Check the chosen microphone and speech model if recording still cannot start.

**System > Diagnostics** offers **Export diagnostics…**, **Open logs**, and **Open crash reports**. Exports create a local ZIP; nothing is uploaded automatically. Optional macOS crash reports may contain personal information and file paths. See [troubleshooting and diagnostics](diagnostics.md) before sharing an export.

## Local data and privacy

Local Qwen recognition does not upload audio. Doubao online recognition streams recorded audio directly to Doubao; optional AI features send the text and context needed for their requests. Labs enhanced recognition uses both recognizers and sends available transcripts to AI even when Offline is selected and the separate polishing switch is off. Review [AI providers and privacy](ai-polish.md) for details.

Talkless stores:

- **App preferences:** settings, provider endpoints/model IDs, dictionary terms, dictionary fixes and dismissed suggestions in macOS UserDefaults.
- **Credentials:** AI service keys and the dedicated Doubao Speech key are stored in macOS Keychain. Failed saves remain usable for the session and show an error in settings. Keys for retired cloud services are not imported into Doubao.
- **`~/Library/Application Support/Talkless/`:** managed models in `Models/`, text history in `history.json`, text-free daily totals in `activity.json`, and rotating event logs in `Diagnostics/`.

Logs exclude audio, transcripts, API keys and request contents. Use History's deletion controls for saved text and **Clear activity** for daily totals. Talkless does not use a `~/.talkless` configuration folder.

For building and testing from source, see the [README's development section](../README.md#development); signing and distribution are covered in [release documentation](releasing.md).
