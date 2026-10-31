# Changelog

## Unreleased

### Documentation
- Archived the icon design studies and documented the selected Pip silhouette and published startup fix.

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
