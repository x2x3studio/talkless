# Recording diagnostics

**Settings > System > Diagnostics** provides **Export diagnostics…**, **Open logs**, and **Open crash reports**. Exporting creates a local ZIP and never uploads it. Relaunch after a crash before exporting so the previous unclean-session marker is recorded.

These labels follow **Settings > System > Language** (Follow System, English or Simplified Chinese); structured event names and metadata remain stable, not translated. For interface or translation issues, report the interface choice and the separate translation source/target and primary/secondary choices without sharing private text. For update issues, include the installed version/build, channel and displayed status from **Settings > System > Updates**. **Last checked** means the last attempt, not necessarily a successful check; release notes appear in Sparkle's standard update window.

Local structured event logs retain up to three 5 MB files. Each event has a millisecond UTC timestamp, a session-local sequence number and monotonic elapsed milliseconds. A random operation ID links a recording to its audio startup, recognition, optional AI processing and insertion attempt. Critical pre-native lifecycle checkpoints are flushed synchronously; audio callbacks never log or write files.

## What the logs show

- Recording mode, hotkey timing, permission blocks and unavailable models.
- Audio startup time, first-buffer latency, buffer/sample counts and recording duration.
- Configuration notifications, before/after sample rates and channel counts, engine state, and whether the selected route or format changed. Device names and stable device identifiers are not logged.
- A bounded startup recovery attempt, a genuine interruption, or a microphone that never delivers its first audio buffer.
- Cancellation reasons: Escape, shortcut combinations, explicit cancellation, recorder interruption, or recognition failure. These no longer collapse into an unexplained cancellation event.
- Recognition, polishing and editing timings, empty results, fallback to the original transcript, and insertion attempts. An insertion API returning does not prove that the target app accepted the text.

First-buffer and summary events are collected outside the realtime audio callback. Logging is not continuous audio tracing, and elapsed time measures lifecycle events, not speech content.

Only approved event names and metadata are accepted. Audio, transcript text, API keys, prompt contents, arbitrary error descriptions and request URLs are not recorded. The exported system summary omits serial numbers and user identifiers. **Include recent macOS crash reports** is opt-in: these raw system reports contain backtraces and may include local paths or other metadata. Inspect them before sharing. An unclean-session marker can also indicate Force Quit or power loss; it does not prove a crash.

## Recording startup fixes

The Swift 6 audio tap previously inherited MainActor isolation from its setup method. Core Audio delivers samples on a background thread, causing an executor assertion before processing. An explicit Sendable tap removes that inherited actor requirement.

A preflight checks that the requested Core Audio input device exists and exposes input channels before constructing AVAudioEngine. Without a microphone, an apparently valid fallback format can otherwise reach exception-prone tap installation. The app reports the missing device instead. Device disconnection races in the older macOS audio API remain a limitation.

System default uses the engine's default route without forcing a device assignment. An explicit microphone is still selected per engine, never by changing the system-wide input. A configuration notification triggers validation of the route, negotiated format and running state; it is not itself proof of disconnection. Healthy, unchanged capture continues. A stopped or reconfigured engine may be rebuilt once only before any audio has been delivered. After capture begins, a real interruption discards partial audio instead of stitching recordings or inserting an incomplete transcript. Stop also validates state so releasing the key cannot bypass a pending interruption. Each successfully started attempt gets a three-second first-buffer allowance; a single pre-audio recovery receives its own allowance. A microphone delivering no audio then reports an error. Silence still supplies buffers and does not trigger this timeout.

Recording uses an explicit Hold to talk or Tap to toggle mode captured at startup, not duration-based tap/hold classification. Hold always finishes on release; Toggle finishes on the next press. Release diagnostics use physical Core Graphics event timestamps rather than callback-processing time, so cold audio initialization does not inflate the recorded key duration. See [recording modes](user-guide.md#dictation-and-shortcuts).

## Regression checks

```sh
python3 -I Tests/AudioTests/run-tests.py
python3 -I Tests/HotkeyTests/run-tests.py
bash Tests/DiagnosticsTests/run-tests.sh
```

Audio tests check optimized Swift isolation, a negative control restoring the original defect, actual stereo resampling from synthetic background callbacks, repeated start/stop, missing-device rejection, startup notifications, harmless configuration notifications, bounded pre-audio recovery, true interruptions, stale callbacks, immediate stop races and first-buffer timeout. Native-device state is simulated; these tests do not establish that the reporter's hardware problem is resolved.

A signed installed app provides an explicit hardware-only smoke test:

```sh
open -n -W --stdout /tmp/talkless-mic.stdout --stderr /tmp/talkless-mic.stderr \
  /Applications/Talkless.app --args --test-microphone
```

This requires previously granted microphone permission, captures for three seconds without saving audio, and does not run ASR or paste. On the development Mac mini with no available input device, the fixed build returned a normal missing-microphone error rather than raising the prior audio exception. The background-callback assertion fix still needs confirmation with the reporter's actual microphone and hotkey setup.
