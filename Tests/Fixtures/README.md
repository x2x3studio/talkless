# Streaming test fixtures

Originally generated locally with macOS `say`, Tingting voice, on 2026-10-29. No microphone audio or private user data is used. WAV files are mono 16 kHz signed 16-bit PCM. These fixtures validate incremental audio ingestion and preview timing, not human speech accuracy or code-switching benchmarks. English words reflect the Mandarin TTS voice's pronunciation.

## Reproduce locally

From the project root, with the Tingting voice installed and `ffmpeg` and Python 3 available:

```sh
bash Tests/Fixtures/generate.sh
```

The script locates its own directory, uses only local speech synthesis and audio conversion, and never uploads audio. It refuses to replace existing fixtures. To generate a separate set without changing locally retained evidence:

```sh
bash Tests/Fixtures/generate.sh "$(mktemp -d)"
```

The original Mandarin text is preserved as ASCII Unicode escapes in the generator, not as an untranslated prose block. Voice or OS updates can change pronunciation and duration; the durations below describe the original recordings, not a byte-for-byte reproduction guarantee.

## Fixture contents

- `mandarin.wav`: originally 14.098438 seconds, speech rate 175. English meaning: "Let's first build a preview window for microphone recordings. While I speak, display the text in the window in real time. After I finish, automatically paste it into the original input field; there is no need to build an input method."
- `mixed.wav`: originally 17.994125 seconds, speech rate 170. Mandarin with English technical names. English meaning: "This project mainly supports macOS, uses SwiftUI for the interface and Qwen ASR for speech recognition. Let's first test API latency. Launch on Wednesday; no, change that to Thursday. Do not automatically answer what I say."
- `short.wav`: first three seconds of `mandarin.wav`, intentionally cut mid-sentence; tests stop/flush before a full encoder window.
- `silence.wav`: three seconds of digital silence; tests whether the decoder invents text without speech.
- `mandarin-pause.wav`: `mandarin.wav` with three seconds of digital silence inserted at the five-second mark; tests that a pause does not end the session or discard remaining speech.
- `mandarin-long.wav`: three consecutive copies of `mandarin.wav`; tests longer-window boundaries.

The references to API testing in the spoken fixture are historical test content, not a statement of current product architecture.

Feed audio frames at wall-clock cadence, then flush the same session. A transcription emitted only after end-of-input does not count as a live preview. Record model loading separately from first-text latency, and report whether a run includes first-use GPU initialization. A nonempty first partial can still be incorrect; retain the partial text timeline rather than only its timestamp.
