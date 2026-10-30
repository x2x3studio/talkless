# Talkless

**Speak, and your words appear where you type.**

Talkless is a macOS menu bar app for voice input. Hold a key, speak, and release to insert the text into your current app.

## What it does

- **Dictation:** local speech recognition with live text. Hold to talk or tap to toggle.
- **Optional AI:** polish dictation, edit selected text by voice, or translate a selection using your own provider.
- **Personal dictionary:** keep names and specialist terms consistent.
- **Simple setup:** a guided first run, English and Simplified Chinese interfaces, and configurable shortcuts.

## Get started

Requires **Apple Silicon and macOS 26 or later**.

1. Download the DMG from [Releases](https://github.com/x2x3studio/talkless/releases). Beta builds are marked **Pre-release**.
2. Move Talkless to Applications and open it. Follow the setup guide to grant permissions and download the speech model.
3. Click a text field, hold **Fn**, speak, and release. **Escape** cancels.

Talkless lives in the menu bar. Open **Settings** there to change the microphone, shortcuts, recognition engine, or AI provider. Set the macOS Globe-key action to **Do Nothing** if it conflicts with Fn.

## Your data

Local Qwen recognition runs on your Mac; it does not upload audio. The speech model is downloaded separately. AI features are optional and use your own provider and API key; they send the text needed for the request. Cloud speech recognition, if selected, sends audio to that provider.

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

Run model-free tests with `bash scripts/test.sh`. Local builds are not notarized. See [release documentation](docs/releasing.md) for signing and distribution.
