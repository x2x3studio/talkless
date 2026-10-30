# Recording diagnostics

Settings > System provides **Export Diagnostics**, **Open Logs**, and **Open Crash Reports**. Exporting creates a local ZIP and never uploads it. Relaunch after a crash before exporting so the previous unclean-session marker is recorded.

Local structured event logs retain up to three 5 MB files. Events cover application start/stop, hotkey press/release, recording start/stop/errors, model loading, recognition completion, cancellation and paste decisions. Critical lifecycle checkpoints are flushed synchronously. Audio callbacks do not write per-frame logs.

Only approved event names and metadata are accepted. Audio, transcript text, API keys, prompt contents, arbitrary error descriptions and request URLs are not recorded. The exported system summary omits serial numbers and user identifiers. **Include recent macOS crash reports** is opt-in: these raw system reports contain backtraces and may include local paths or other metadata. Inspect them before sharing. An unclean-session marker can also indicate Force Quit or power loss; it does not prove a crash.

## Recording startup fixes

The Swift 6 audio tap previously inherited MainActor isolation from its setup method. Core Audio delivers samples on a background thread, causing an executor assertion before processing. An explicit Sendable tap removes that inherited actor requirement.

A second preflight checks that the default Core Audio input device exists and exposes input channels before constructing AVAudioEngine. Without a microphone, an apparently valid fallback format can otherwise reach exception-prone tap installation. The app now reports the missing device instead. Device disconnection races in the older macOS audio API remain a limitation.

Tap/hold classification uses the physical Core Graphics event timestamps, not callback-processing time. Cold audio initialization must not turn a short tap into a long hold. Release diagnostics record only the physical duration in milliseconds; a 100 ms tap with 450 ms delayed startup remains hands-free in the regression harness.

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
