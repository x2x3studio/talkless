# Recording diagnostics

This page describes the implementation accompanying **2026.1031.18018**. **Settings > System > Diagnostics** offers **Export diagnostics…**, **Open logs** and **Open crash reports**. Export creates a local ZIP; Talkless does not upload it. Relaunch after an unexpected exit before exporting so the previous-session marker is recorded.

## What is collected

Logs live in `~/Library/Application Support/Talkless/Diagnostics/`: `diagnostics.ndjson` plus two rotated files, each limited to 5,000,000 bytes. New events rotate out the oldest file; this is a size limit, not a retention period. Logging is best-effort and does not prevent startup on a full or unwritable disk.

Each event contains a millisecond UTC timestamp, random session ID, session-local sequence number and monotonic elapsed milliseconds. Random operation IDs link recording, audio startup, recognition, AI processing and insertion attempts. Use sequence/elapsed time for ordering within a session; the wall clock can change. Critical pre-native-work and failure checkpoints are flushed synchronously. The realtime audio tap does not write or enqueue log events; first-buffer and summary data are collected outside it.

Approved events and metadata describe:

- Startup, missing localization resources, permissions and unavailable/busy models.
- Recording mode, physical hotkey timing, stage durations, sample/frame/buffer counts and first-buffer latency.
- Audio configuration notifications, engine state, numeric formats and route-change flags, not device names or stable device identifiers.
- Startup recovery, interruption, no-audio timeout and explicit cancellation reasons such as Escape, shortcut combinations or recognition failure.
- Empty recognition, polishing fallback and insertion attempts. `paste_returned` means the insertion call returned, not that another app confirmed accepting text.

Only allowlisted event names and metadata are retained. Logs omit audio, transcripts, selected text, prompts, API keys, request URLs, response bodies and arbitrary error descriptions. Interface labels follow the selected UI language; event identifiers do not.

## Export and error interpretation

The ZIP includes a snapshot of the rotating logs, `system.json` and explanatory `README.txt`. The system summary includes app/OS versions, hardware model, architecture, CPU count and memory, not serial numbers, user names or host names.

**Include recent macOS crash reports** is off by default. Opting in copies raw `Talkless*.ips` reports modified in the last seven days: at most 10 reports, 10 MB each and 25 MB total. These reports are not sanitized and may contain local paths or other personal metadata. Inspect the archive before sharing. Reports can take time to appear; their absence does not rule out a crash.

`session.previous_unclean_exit` means the prior session marker was not removed. Force Quit, power loss or interrupted shutdown can cause it; it does not prove a crash. Talkless leaves fatal signals and Objective-C exceptions to macOS rather than installing its own crash handler. A user-facing error and a structured diagnostic reason are also different: for example, the interruption message mentions a changed/disconnected device, while the recorded cause may be a stopped engine or changed format.

For a report, include the failure time, app version/build, recording mode and visible error, without private dictated text. For update problems also include the channel and displayed status in **Settings > System > Updates**; Last checked records an attempt, not necessarily success. AI connection receipts are a separate, explicit copy action described in [AI service](ai-polish.md#test-connection-and-its-receipt).

## Startup and packaged resources

Normal launch starts diagnostics before resolving localization or constructing application settings/controllers. A missing localization bundle records `startup_resource_error` with `reason=localization_missing`, not a filesystem path.

A separate read-only packaging probe runs before normal app initialization:

```sh
/Applications/Talkless.app/Contents/MacOS/Talkless --verify-bundle
```

It prints one JSON report and exits `0` for success or `1` for failure. It checks packaged English/Chinese strings, permission strings, the SwiftPM resource manifest/bundles and resource containment, MLX Metal library, icon and Sparkle binary. On successful inspection it also exercises Hub's local resource accessor. It does not initialize app settings, diagnostics, permissions or models, and does not download a model or make an API request. The report includes resolved app/resource paths: it is not a sanitized diagnostics receipt. Passing this probe does not test microphone capture, inference or paste.

## Audio startup and recovery

The audio tap explicitly uses a Sendable callback so it does not inherit MainActor isolation when Core Audio invokes it on a background thread. Before constructing the engine, the app checks that the requested input device exists and has input channels. It reacquires a coherent route/format and checks again immediately before installing the tap. Device-disconnection races in the native API remain possible; Swift guards cannot catch an Objective-C exception.

**System default** leaves the engine's default route alone. An explicit microphone is assigned to that engine only, not made the system-wide default; an unavailable selected device is not silently replaced. A configuration notification triggers validation, not automatic cancellation. Healthy unchanged capture continues.

A stopped/reconfigured engine may be rebuilt **once, before any audio has been delivered**. Recovery does not stitch a new route onto an existing recording. After capture begins, a real interruption discards partial audio; Stop also validates native state so key release cannot bypass an interruption handler still in the queue. Stale callbacks from earlier attempts/sessions are ignored.

Each successfully started attempt receives a three-second first-buffer allowance, checked by a periodic monitor. A permitted pre-audio recovery gets its own allowance. A running microphone that delivers no buffers reports **The microphone did not deliver audio** rather than retrying indefinitely. Silence still supplies buffers and is not this timeout. Conversion failures and missing/invalid input formats have distinct failure paths.

Recording mode is captured at startup: Hold finishes on release; Toggle finishes on the next press. Release timing uses the physical event timestamp, not delayed callback processing after cold startup. See [dictation and shortcuts](user-guide.md#dictation-and-shortcuts).

## Regression checks and hardware probe

```sh
python3 -I Tests/AudioTests/run-tests.py
python3 -I Tests/HotkeyTests/run-tests.py
bash Tests/DiagnosticsTests/run-tests.sh
python3 -I Tests/LocalizationTests/run-bundle-tests.py
```

Audio tests use synthetic callbacks and simulated native-device state, including optimized callback isolation and a negative control for the old MainActor defect, resampling, bounded recovery, stale callbacks, stop races and no-buffer timeout. Diagnostics tests cover schema filtering, rotation, write failures, queued export snapshots and opt-in crash filtering. These checks do not establish that a particular microphone/driver problem is fixed.

For an explicit hardware smoke test with an installed app:

```sh
open -n -W --stdout /tmp/talkless-mic.stdout --stderr /tmp/talkless-mic.stderr \
  /Applications/Talkless.app --args --test-microphone
```

This requires existing microphone permission and uses the system-default input. It captures for three seconds without saving audio, running ASR or pasting. Success prints `Microphone test passed: <count> background audio callbacks.` Failure prints `Microphone test failed: <error>` and the app exits nonzero. This mode takes the app's startup path; unlike `--verify-bundle`, it is not isolated from normal settings initialization. It does not exercise the configured hotkey or an explicitly selected microphone.
