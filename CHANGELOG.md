# Changelog

## Unreleased

### Fixed
- Quickly starting and stopping Doubao dictation now closes quietly when the service returns empty-audio code 45000002, without showing a recognition error or retrying offline. Other service errors still report normally.

## 2026.1102.9321

### Fixed
- Doubao dictation now closes quietly when recognition finishes successfully without any text, such as when you press the dictation key but do not speak. Malformed responses and service failures still report an error.

## 2026.1101.64760

### Changed
- Automatic update checks now run every 6 hours on the Beta channel and every 48 hours on Stable, instead of every 30 minutes.
- AI service settings are laid out as one block for provider, address, key and model, with the refresh button that fetches models right beside the model. Protocol and authentication sit in their own Advanced section with a short note, instead of a disclosure squeezed into the list.

## 2026.1101.63169

### Changed
- The overlay's text is one point larger (14 pt) and its status icon now has the same size, sitting level with the first line of text instead of above it.
- The dictionary shows learning as it happens: corrections still being watched appear with how many more times they need to be seen, a learning log lists what was learned or retired and when, and a note explains when learning is paused because smart text cleanup is off.

## 2026.1101.60758

### Fixed
- Opening Settings no longer crashes Talkless. The responsiveness monitor added in 2026.1101.51474 tripped a Swift concurrency check on its background timer, so the app quit as soon as Settings appeared, and again on every relaunch that opened Settings.

### Added
- Two formatting options in Dictation settings, applied to every dictation with or without smart text cleanup: Punctuation (keep all, no punctuation at sentence end, or spaces instead of punctuation) and Spaces around numbers and English (none or before and after). Defaults keep all punctuation and add no spaces.
- The setup guide lets you choose Offline or Doubao online in place: download the offline model, or paste and test the Doubao key, right in the guide. The optional Smart text cleanup step turns it on and sets up the AI provider and key there too.

### Changed
- AI polishing is now described as Smart text cleanup: after you speak, it lays out, corrects and polishes the text.

## 2026.1101.57885

### Changed
- Pip now stays in one place in the menu bar: the slot is laid out for the widest mark, and only the mark changes. Idle shows "?", dictation shows "!" until the words are recognized, and AI polishing or voice editing shows "@".

## 2026.1101.57034

### Changed
- The menu bar icon is back to Pip with its "?" (listening), "!" (recognizing) and "@" (AI polishing or voice editing) marks, now centered in its slot so it no longer leans left. The slot keeps one width, so nothing beside it shifts.

## 2026.1101.54169

### Changed
- The menu bar icon showed each state as its own glyph (later reverted).

## 2026.1101.51474

### Changed
- History and the dictionary now page through entries 50 at a time with previous and next buttons and a "Page x of n" indicator, instead of a Show more button or one long list.
- Diagnostics record how long the interface stopped responding while Settings is open (over 150 ms), how often Settings redraws, and which page was showing. No text is recorded. Export diagnostics after Settings feels slow so the cause can be found.

## 2026.1101.49916

### Changed
- Settings › History shows 50 entries at a time with a Show more button, instead of drawing all 500 at once. Opening History, and Settings updates after each dictation or translation, are several times faster. Hovering the activity calendar redraws only the affected days, and the microphone list redraws only when devices change.
- Speech recognition choices are now named Offline (the local model) and Doubao online, and the fallback switch reads "Allow falling back to offline recognition", with a note on when it applies.

## 2026.1101.46792

### Fixed
- Dictating into a field that selects its contents on focus, such as Chrome's address bar, no longer turns your words into an edit of that text. With voice editing on, a selection made the next dictation an AI edit instruction, so words could vanish or old text reappear.

### Changed
- Voice editing now has its own gesture, like the command mode in other voice-input tools: hold the dictation key with Control (Option when Right Control is the dictation key), or press Control after you start speaking. The dictation key alone always types. Without a selection, the words are typed as dictation and the overlay says so.
- Pasting sends a complete Command-V key sequence after a short settle, and pastes run one at a time. Reading a selection for voice editing or translation trusts an explicit empty selection, and otherwise uses the app's own Copy menu item (or Command-C sent only to that app) before restoring your clipboard.

## 2026.1101.45326

### Changed
- Diagnostics now record, at each paste, which system action the Globe key has and whether an input method is active, without any text. This helps find why some dictations do not appear in Chrome.

## 2026.1101.43798

### Added
- The dictionary now learns on its own. When AI polish keeps making the same spelling fix (twice, or three times for two-character Chinese words), the fix takes effect automatically and its word becomes a recognition and polish hint. Fixes unused for 30 days retire on their own, and a fix that polish undoes retires at once. Existing local history is read once to get started. Learning is local, on by default and can be turned off.

### Changed
- The dictionary lists every entry as "heard → written", split into Learned automatically and Added by you. Learned rows show how often the mishearing was seen and fixed, with Keep (never retire) and delete (never learn again). The Review tab and its manual Accept/Always fix steps are gone.

## 2026.1101.41567

### Fixed
- Settings now opens on the first click from the menu bar. Talkless takes activation for explicit window requests instead of asking for it, so the window no longer opens hidden behind the frontmost app.

## 2026.1101.36907

### Fixed
- With Doubao cloud and "Use this Mac if Doubao fails" on, a missing local model no longer blocks dictation; Doubao recordings simply run without fallback until the model is downloaded. A model download or deletion in progress no longer blocks Doubao either.
- With the switch on and a local model ready, Doubao that cannot start (for example, no key saved) now records locally instead of stopping. Local mode still only uses local recognition.

### Changed
- The fallback switch is now named "Use this Mac if Doubao fails" and warns when no local model is available. Docs describe the two modes and when fallback applies.

## 2026.1101.36007

### Fixed
- Update checks no longer install an intermediate release. Automatic checks now only look for a new version and show "Update to …" in the menu and About; clicking it fetches the feed again and offers the newest build.
- The AI service page no longer shows the Provider row three times when a custom provider is selected.
- Request app activation before creating Settings and explicitly wake deferred window presentation after menu tracking. Settings follows the active desktop; closing a window cancels pending presentation requests.

### Changed
- Speech recognition is now a choice between two cards, "On this Mac" and "Doubao cloud". The Doubao key field has an inline Test button and a "Get a key" link; billing plan and privacy notes live under More options. The Ark-key hint now appears only when Doubao rejects a key.
- The AI service page drops the status block, adds a "Get a key" link for each provider, and moves protocol and authentication under Advanced.

## 2026.1101.31817

### Added
- Optional local Qwen fallback for failed online recognition. Enabling it preloads and keeps the local model in memory; failed online sessions replay the complete recording locally once, without mixing partial transcripts.

### Improved
- Settings use short feature names and one-line descriptions, with cleanup preferences and connection details in expandable sections. The local fallback switch explicitly says it switches recognition to local after an online failure.
- Online recognition without fallback releases local model memory when idle. Connection/upload stalls fail after 10 seconds, and the final response has a 15-second deadline after recording ends. AI polishing is unchanged.

## 2026.1101.28606

### Fixed
- Clipboard automation no longer cancels a recording started by a modifier key. Physical keyboard combinations still retain their normal cancellation behavior.

### Improved
- Doubao and AI service key fields show paste instructions inside the input, plus visible credential guidance. Doubao now offers an explicit connection check that sends configuration only, not microphone audio; changing credentials clears its result.

## 2026.1101.27458

### Fixed
- Settings and setup windows are shown after menu tracking ends, independently of asynchronous app activation, and restored when minimized. Focus is applied again once the app becomes active.

## 2026.1101.25885

### Added
- Doubao streaming ASR 2.0 provides live online recognition using your own Speech API key, stored separately in Keychain. Duration billing is selected by default.

### Changed
- Speech recognition now offers only local offline Qwen and online Doubao. Apple and generic Whisper-compatible options are removed; existing retired selections fall back to local recognition without reusing their credentials. AI polishing providers remain separate and unchanged.

## 2026.1101.23885

### Improved
- Microphone controls now align with recording controls. Translation's shortcut is at the top of its settings page, and AI connection tests and update checks use trailing action placement.
- Model actions and dictionary review actions have dedicated rows so longer status and app names do not crowd buttons. History search and filters stack when the window is narrow.

## 2026.1101.20949

### Improved
- Microphone selection is the first section on the Dictation page again. Recording mode and dictation key controls share aligned value and reset columns; instructions sit beside the setting instead of occupying a separate row.

## 2026.1101.364

### Improved
- AI polishing now explicitly addresses homophones, accent-related recognition errors, and phonetic spellings of technical terms, with examples of corrections and words that should be preserved. Dictionary hints still require matching context rather than overriding ordinary words.

## 2026.1031.65045

### Improved
- All clipboard use now follows one set of rules: pasting results, reading a selection for voice editing or translation, and every Copy button. Copying AI connection diagnostics no longer lets a pending paste restore overwrite what you just copied.

## 2026.1031.64297

### Fixed
- Voice editing now works in apps that do not expose selected text to Accessibility. Like translation, Talkless briefly copies the selection in the background and restores your clipboard; when it finds text, the recording switches to voice editing and the overlay shows the pencil. VS Code's whole-line copy with nothing selected is not treated as a selection.

## 2026.1031.63476

### Fixed
- With the menu bar menu open, Command-Comma opens Settings and Command-Q quits, as the menu shows.

### Improved
- The ?, ! and @ status marks sit closer to the menu bar cat.
- Voice editing shows a blue pencil from the moment recording starts, so you can tell it will replace the selected text and press Esc if you only meant to dictate. Its settings now explain how it works and warn when no AI service is configured.

## 2026.1031.62571

### Improved
- The menu bar cat keeps its original size and proportions. The ?, ! and @ status marks are smaller and sit at its top-right corner, where the old dot was.

## 2026.1031.61355

### Improved
- The menu bar status mark now sits right beside the cat, so the icon stays compact instead of stretching wide.

## 2026.1031.59966

### Improved
- The menu bar icon shows what Talkless is doing: ? while listening, ! while recognizing, and @ while AI polishes or edits. The marks are larger and easier to see than the old dots.

## 2026.1031.58935

### Changed
- Removed the per-dictation AI polishing shortcut. AI polishing now simply follows the Polish dictation with AI switch: on polishes every dictation, off polishes none. The dictation key is the only recording shortcut.

## 2026.1031.54783

### Improved
- Settings pages are grouped: Voice input (Dictation, Speech recognition, Dictionary, AI service, Overlay) first, then Tools (History, Translation) and General.
- The History page groups results by day, with search, type filters, kind icons and a copy button on each entry.
- On the Dictation page, the AI polishing shortcut now sits with the polishing switch, and microphone selection moves to the end.

## 2026.1031.53892

### Added
- Search history by result, raw text or app, and copy any entry with one click.
- The menu bar menu offers Copy Last Result after a dictation.

### Improved
- Translation starts connecting to the AI service while the selected text is read.

### Security
- The cloud speech-recognition API key is now stored in Keychain. A key saved in plaintext by an earlier version is moved on first launch and the plaintext copy is deleted.

## 2026.1031.53079

### Added
- Dictionary terms can list spellings they are often heard as. Talkless replaces those exact spellings after recognition, before AI polishing, so fixes also work with polishing off and appear in the live preview.
- Review suggestions offer Always fix, which adds the term and turns the heard spelling into an automatic fix.
- Import and export the dictionary as plain text, one term per line with optional heard spellings after “=”.

### Improved
- AI polishing is told which misrecognitions belong to each term, so close variants are corrected too.
- Keyboard shortcuts come back automatically when Accessibility is granted again, even with no Settings window open.

## 2026.1031.51406

### Improved
- When a missing permission blocks dictation or translation, Talkless opens the matching System Settings page (Accessibility or Microphone). Microphone access restricted by a management profile only shows a message.

## 2026.1031.50025

### Fixed
- Without Accessibility permission, dictation started from the menu no longer loses its text: Talkless copies it and explains the missing permission. Translating from the menu also names the missing permission instead of only saying no text was selected.

## 2026.1031.47871

### Improved
- The overlay shows a checkmark while inserting text instead of a download-like arrow.
- When Accessibility or Microphone permission is missing, or the local speech model is not downloaded, the menu bar menu shows a warning row that opens the right setting.
- Opening Talkless again while it is running now shows Settings, or the setup guide if setup is unfinished.

## 2026.1031.44580

### Improved
- Start Dictation and Translate selection are clickable again in the menu bar menu, with your shortcuts shown underneath; while recording, the menu offers Finish Dictation.
- Menu bar menu rows now share one icon column, so every title lines up.

## 2026.1031.43249

### Fixed
- If you switch to another app before the text is ready, Talkless copies it and asks you to press ⌘V instead of pasting into the wrong app.

### Improved
- You can start the next dictation right after text is inserted; the original clipboard is still restored in the background.

## 2026.1031.40954

### Improved
- AI polishing, voice editing, and translation reuse warm connections, and Talkless starts connecting to the AI service while you speak, so results arrive sooner.
- Saving history no longer blocks the interface after each dictation.

## 2026.1031.38693

### Added
- Setup Guide now offers an optional Launch at login step using the same macOS-controlled setting as System preferences. Nothing is enabled automatically.

## 2026.1031.36630

### Improved
- Dictionary review merges suggestions without regard to case, skips capitalization-only changes, and avoids recommending existing terms again while preserving saved spellings.
- Removed the explanatory language-change hint from the translation panel.
- Translation shortcut capture now asks for a key combination, while dictation capture still asks for a single key.
- The completion checkmark now stays for 50 milliseconds after insertion instead of two seconds.

## 2026.1031.34156

### Fixed
- Microphone startup and teardown no longer block the interface. Healthy recordings reuse their audio engine instead of repeatedly rebinding the same microphone.
- Unresponsive native audio operations time out without accumulating replacement workers or inserting partial text.

### Improved
- Dictation keeps text visible through processing and uses one waveform for listening and final recognition. Icons indicate polishing and completion without replacing the transcript.
- Final AI additions and changed words are highlighted separately from dictionary matches; results remain briefly visible without delaying text insertion.
- The menu shows the configured hold or tap key, restores the Settings gear, and removes the AI-polishing shortcut row.
- Version information and update controls move to About, separate from system preferences.
- The website keeps help, privacy and release information onsite, with a single repository entry and stable download link.

## 2026.1031.26846

### Fixed
- System-default microphones no longer fail startup solely because Core Audio uses a separate aggregate device. Explicit microphone selection remains strict.
- Microphone startup errors distinguish an unavailable device from an unready format or audio route.

### Improved
- Shortcuts and setup now say Use AI polishing or Skip AI polishing, with plain instructions for the current input.

## 2026.1031.22578

### Added
- Live dictation highlights exact dictionary spellings with a subtle background and underline. Highlights indicate text matches, not proof of a dictionary-caused correction.
- Overlay settings include a dictionary-match preview; each recording uses a fixed dictionary snapshot for recognition hints and highlights.

### Documentation
- Archived the icon design studies and documented the selected Pip silhouette and published startup fix.
- Updated the user, AI, model, diagnostic, and release guides against current behavior, including shortcuts, translation, history, and privacy boundaries.

## 2026.1031.18018

### Fixed
- Fixed startup failure on Macs without the developer build directory by resolving all packaged resources inside the app.
- Release builds no longer embed personal build-machine paths and verify resource loading independently of the source checkout.

### Improved
- A new Pip silhouette unifies the app icon and menu bar, with clear recording and processing indicators in light and dark appearances.

## 2026.1030.68911

### Fixed
- Recording no longer treats every audio configuration notification as a disconnected microphone. Real interruptions still stop incomplete recordings.

### Added
- A first-run guide for shortcuts, permissions, speech recognition, and optional AI. Reopen it from System settings; existing users are not forced through setup.
- Expandable connection-test details with the test input, response, model, timing, and copyable redacted diagnostics.

### Improved
- Client logs distinguish cancellation, audio interruptions, and processing failures, with millisecond timing and audio startup details. Audio, text, and credentials remain excluded.
- The dictation overlay stays at the bottom of the screen by default. Following the text cursor is optional.
- A shorter README explains what Talkless does and how to start; detailed instructions live in the user guide.

## 2026.1030.65502

### Added
- English and Simplified Chinese interface language packs, with a System setting to follow macOS or choose a language explicitly.
- Version-specific release notes in the update window and on the release download page.
- Source and target language controls in the translation panel, with remembered choices and automatic direction based on primary and secondary languages.
- A searchable preferred-language list that keeps frequently used languages at the top of translation menus.

### Fixed
- Standard keyboard editing commands work in settings text fields, including pasting API URLs and keys.

### Improved
- Clearer update status, installed-version information, and last-check feedback without silent installation.
- Consistent localized menus, settings, dictation feedback, dictionary review, and daily activity labels.

### Unchanged
- Interface language is separate from dictation output and translation target languages.
- Existing provider keys, model choices, shortcuts, history, and local models are preserved.
