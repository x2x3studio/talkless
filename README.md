# Talkless

**Speak, and your words appear where you type.**

Talkless is a macOS menu bar app for voice input. Hold a key, speak, and release to insert the text into your current app.

Website: [typeless.x2x3.com](https://typeless.x2x3.com)

## What it does

- **Dictation:** local Qwen or online Doubao speech recognition with live text that stays visible through processing. Hold to talk or tap to toggle, with a quiet, customizable overlay.
- **Optional AI:** polish dictation, edit selected text by voice, or translate a selection using your own provider.
- **Labs:** opt-in enhanced recognition compares local and online transcripts with AI; sentence alternatives can offer complete-text choices. These are experimental, not verified accuracy improvements.
- **Self-learning dictionary:** learns the words recognition keeps getting wrong from your own dictations, retires fixes that are no longer needed, and lets you add your own.
- **History and activity:** copy past results and see daily dictation totals.
- **Simple setup:** a guided first run, English and Simplified Chinese interfaces, and configurable shortcuts.

## Get started

Requires **Apple Silicon and macOS 26 or later**.

1. Download the DMG from [Releases](https://github.com/x2x3studio/talkless/releases). Beta builds are marked **Pre-release**.
2. Move Talkless to Applications and open it. Follow the setup guide to allow Microphone and Accessibility access, then download the local speech model in **Settings > Voice input > Speech recognition**.
3. Click a text field, hold **Fn**, speak, and release. **Escape** cancels recording or processing.

Talkless lives in the menu bar, not the Dock or input-source menu. **Settings > Voice input** puts the microphone first, followed by recording controls and speech recognition. **AI polishing** has its own page for the provider and AI features; **Text formatting** runs locally without AI. **Labs** holds enhanced recognition and sentence alternatives, both off by default. Set the macOS Globe-key action to **Do Nothing** if it conflicts with Fn. AI polishing and voice editing are also off by default.

AI polishing has a five-second request deadline; a timeout quietly uses the recognized text, with dictionary fixes and local formatting still applied. Insertion temporarily borrows the clipboard, posts Command-V, then waits a fixed two-second grace period before restoring the old contents if the clipboard is unchanged. It does not wait indefinitely for paste confirmation. Keep the original app and text field focused; recover a result from History if insertion is skipped.

## Your data

Local Qwen recognition runs on your Mac; it does not upload audio. The speech model is downloaded separately. AI features are optional and use your own provider and API key; they send the text needed for the request. Online recognition uses Doubao Speech with its own API key and streams audio directly to Doubao for live previews. With Labs enhanced recognition enabled, ordinary dictation uses both recognizers even if Offline is selected, then sends their available transcripts to the AI provider. Local Qwen and online Doubao are the only recognition engines; AI polishing providers are configured separately.

History and diagnostic logs stay on your Mac. Logs exclude audio, transcripts, API keys, and prompts. Exporting diagnostics creates a local ZIP; nothing is uploaded automatically.

## More

- [User guide](docs/user-guide.md)
- [AI providers and privacy](docs/ai-polish.md)
- [Troubleshooting and diagnostics](docs/diagnostics.md)
- [Changelog](CHANGELOG.md) · [Simplified Chinese](CHANGELOG.zh-Hans.md)

## Development

Requires Xcode with Swift 6.4 and the Metal Toolchain.

```sh
swift package --build-system native resolve --force-resolved-versions
bash scripts/build-app.sh
open dist/Talkless.app
```

Run model-free tests with `bash scripts/test.sh`; pass words to run matching suites only (for example `bash scripts/test.sh dictionary hud`), or set `TALKLESS_TEST_VERBOSE=1` for full output. Every selected suite runs, and a summary lists any failures. Write new unit tests in `Tests/TalklessTests` with Swift Testing and `@testable import Talkless` (`swift test`); the older scripts under `Tests/` extract and recompile source text and should not be extended for logic that can be tested directly. Local builds are not notarized. See [release documentation](docs/releasing.md) for signing and distribution.
