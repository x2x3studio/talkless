# Recording diagnostics

**Settings > System > Diagnostics** provides **Export diagnostics…**, **Open logs**, and **Open crash reports**. Exporting creates a local ZIP and never uploads it. Relaunch after a crash before exporting so the previous unclean-session marker is recorded.

These labels follow **Settings > System > Language** (Follow System, English or Simplified Chinese); structured event names and metadata remain stable, not translated. For interface or translation issues, report the interface choice and the separate translation source/target and primary/secondary choices without sharing private text. For update issues, include the installed version/build, channel and displayed status from **Settings > System > Updates**. **Last checked** means the last attempt, not necessarily a successful check; release notes appear in Sparkle's standard update window.

Local structured event logs retain up to three 5 MB files. Events cover application start/stop, hotkey press/release, recording start/stop/errors, model loading, recognition completion, cancellation and paste decisions. Critical lifecycle checkpoints are flushed synchronously. Audio callbacks do not write per-frame logs.

Only approved event names and metadata are accepted. Audio, transcript text, API keys, prompt contents, arbitrary error descriptions and request URLs are not recorded. The exported system summary omits serial numbers and user identifiers. **Include recent macOS crash reports** is opt-in: these raw system reports contain backtraces and may include local paths or other metadata. Inspect them before sharing. An unclean-session marker can also indicate Force Quit or power loss; it does not prove a crash.

## Recording startup fixes

The Swift 6 audio tap previously inherited MainActor isolation from its setup method. Core Audio delivers samples on a background thread, causing an executor assertion before processing. An explicit Sendable tap removes that inherited actor requirement.

A second preflight checks that the default Core Audio input device exists and exposes input channels before constructing AVAudioEngine. Without a microphone, an apparently valid fallback format can otherwise reach exception-prone tap installation. The app now reports the missing device instead. Device disconnection races in the older macOS audio API remain a limitation.

Recording uses an explicit Hold to talk or Tap to toggle mode captured at startup, not duration-based tap/hold classification. Hold always finishes on release; Toggle finishes on the next press. Release diagnostics use physical Core Graphics event timestamps rather than callback-processing time, so cold audio initialization does not inflate the recorded key duration. See [recording modes](../README.md#dictation-and-shortcuts).

## Regression checks

```sh
python3 -I Tests/AudioTests/run-tests.py
python3 -I Tests/HotkeyTests/run-tests.py
bash Tests/DiagnosticsTests/run-tests.sh
```

Audio tests check optimized Swift isolation, a negative control restoring the original defect, actual stereo resampling from synthetic background callbacks, repeated start/stop, and missing-device rejection. They do not claim hardware microphone coverage.

A signed installed app provides an explicit hardware-only smoke test:

```sh
open -n -W --stdout /tmp/talkless-mic.stdout --stderr /tmp/talkless-mic.stderr \
  /Applications/Talkless.app --args --test-microphone
```

This requires previously granted microphone permission, captures for three seconds without saving audio, and does not run ASR or paste. On the development Mac mini with no available input device, the fixed build returned a normal missing-microphone error rather than raising the prior audio exception. The background-callback assertion fix still needs confirmation with the reporter's actual microphone and hotkey setup.
