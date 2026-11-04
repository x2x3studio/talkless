# Recording diagnostics

**Settings > System > Diagnostics** offers **Export diagnostics…**, **Open logs** and **Open crash reports**. Export creates a local ZIP; Talkless does not upload it. Relaunch after an unexpected exit before exporting so the previous-session marker is recorded.

## What is collected

Logs live in `~/Library/Application Support/Talkless/Diagnostics/`: `diagnostics.ndjson` plus two rotated files, each limited to 5,000,000 bytes. New events rotate out the oldest file; this is a size limit, not a retention period. Logging is best-effort and does not prevent startup on a full or unwritable disk.

Each event contains a millisecond UTC timestamp, random session ID, session-local sequence number and monotonic elapsed milliseconds. Random operation IDs link recording, audio startup, recognition, AI processing and insertion attempts. Use sequence/elapsed time for ordering within a session; the wall clock can change. Critical pre-native-work and failure checkpoints are flushed synchronously. The realtime audio tap does not write or enqueue log events; first-buffer and summary data are collected outside it.

Approved events and metadata describe:

- Startup, missing localization resources, permissions and unavailable/busy models.
- Recording mode, physical hotkey timing, stage durations, sample/frame/buffer counts and first-buffer latency.
- Audio configuration notifications, engine state, numeric formats and route-change flags, not device names or stable device identifiers.
- Startup failures, interruption, no-audio or stalled-audio timeout and explicit cancellation reasons such as Escape, shortcut combinations or recognition failure.
- While Settings is open: interface stalls longer than 150 ms (`ui_stall`, duration only), bursts of Settings redraws (`settings_renders`, a count per 10 seconds), and which Settings page was showing.
- Empty recognition, polishing fallback and insertion attempts. `paste_returned` means the insertion call returned, not that another app confirmed accepting text.

Only allowlisted event names and metadata are retained. Logs omit audio, transcripts, selected text, prompts, API keys, request URLs, response bodies and arbitrary error descriptions. Interface labels follow the selected UI language; event identifiers do not.

## Export and error interpretation

The ZIP includes a snapshot of the rotating logs, `system.json` and explanatory `README.txt`. The system summary includes app/OS versions, hardware model, architecture, CPU count and memory, not serial numbers, user names or host names.

**Include recent macOS crash reports** is off by default. Opting in copies raw `Talkless*.ips` reports modified in the last seven days: at most 10 reports, 10 MB each and 25 MB total. These reports are not sanitized and may contain local paths or other personal metadata. Inspect the archive before sharing. Reports can take time to appear; their absence does not rule out a crash.

`session.previous_unclean_exit` means the prior session marker was not removed. Force Quit, power loss or interrupted shutdown can cause it; it does not prove a crash. Talkless leaves fatal signals and Objective-C exceptions to macOS rather than installing its own crash handler. A user-facing error and a structured diagnostic reason are also different: for example, the interruption message mentions a changed/disconnected device, while the recorded cause may be a stopped engine or changed format.

For a report, include the failure time, app version/build from **Settings > About > Updates**, recording mode and visible error, without private dictated text. For update problems also include the channel and displayed status there; Last checked records an attempt, not necessarily success. AI connection receipts are a separate, explicit copy action described in [AI service](ai-polish.md#test-connection-and-its-receipt).

## Overlay feedback and timing

Recording and final recognition share the waveform and user-facing **Dictating** label. Their controller states and diagnostic events remain distinct: the shared visual does not mean the microphone is still recording after you finish. The latest transcript stays visible through recognition and AI processing, with a phase icon on the left instead of replacing existing text with a status label. There is no shortcut-hint footer.

After insertion returns, the final result briefly shows a checkmark with dismissal scheduled after **50 ms**. Scheduling is best effort, not an exact real-time duration. The controller is already idle; this display does not delay insertion or the next recording. As with `paste_returned`, the checkmark does not independently confirm that the destination app accepted the paste. Error text replaces the transcript and disappears after about **three seconds**. Empty recognition and cancellation dismiss without a completed result.

Blue underlines mark dictionary spellings present in the displayed text; amber backgrounds mark literal final AI additions/replacements relative to finalized recognition. Neither is proof of a dictionary-caused correction or a grammar/spelling check. Revision decoration is skipped above 512 visible comparison tokens or 64 KiB per input; no decoration does not establish that text was unchanged. No additional text or highlight ranges are added to diagnostics. See the [overlay guide](user-guide.md#overlay) for display limits and examples.

## Polishing fallback and clipboard timing

Dictation polishing, including Labs enhanced comparison and sentence alternatives, has a **five-second AI request deadline**. Timeout quietly falls back to the recognized text after dictionary fixes; local formatting still applies. Other polishing failures show a brief fallback error. This deadline does not limit recording, speech recognition or candidate review, and is not silence detection.

Paste operations and selection-copy fallback share a serial clipboard queue. Insertion snapshots the clipboard, writes temporary text, briefly settles the write, posts Command-V to the intended app, and waits a fixed **two-second compatibility grace period**. It then releases the transaction and restores the snapshot only if the clipboard is still unchanged. Cancellation after posting does not skip settlement; a newer user copy wins. There is no clipboard-read confirmation gate or permanent unresolved-paste lock. The grace period is not proof of document insertion, and slow destinations can still miss the temporary text. `paste_returned` with `reason=keys_posted` records submission, not acceptance. Results remain available in History when insertion is skipped.

## Startup and packaged resources

Normal launch starts diagnostics before resolving localization or constructing application settings/controllers. A missing localization bundle records `startup_resource_error` with `reason=localization_missing`, not a filesystem path.

A separate read-only packaging probe runs before normal app initialization:

```sh
/Applications/Talkless.app/Contents/MacOS/Talkless --verify-bundle
```

It prints one JSON report and exits `0` for success or `1` for failure. It checks packaged English/Chinese strings, permission strings, the SwiftPM resource manifest/bundles and resource containment, MLX Metal library, icon and Sparkle binary. On successful inspection it also exercises Hub's local resource accessor. It does not initialize app settings, diagnostics, permissions or models, and does not download a model or make an API request. The report includes resolved app/resource paths: it is not a sanitized diagnostics receipt. Passing this probe does not test microphone capture, inference or paste.

## Audio startup, stop and failures

One serial background queue owns the audio engine, device queries, configuration, start, stop and teardown. These native calls never run inside the UI/event-tap callback. Healthy recordings with the same route reuse their engine instead of assigning the same microphone on every press; capture is stopped between recordings. Cancellation returns immediately, while native cleanup remains serialized behind any in-flight operation.

Startup has a five-second deadline; stop, monitoring and queued cleanup have three-second deadlines independent of the native worker. If a native call never returns, its queue is marked unusable and further capture is refused until Talkless restarts. A deadline cannot safely terminate a Core Audio call: the app does not create replacement queues or accumulate parallel HAL operations. `audio_operation_timeout` distinguishes this failure from first-buffer timeout; `audio_engine_reused` records healthy reuse.

The audio tap explicitly uses a Sendable callback so it does not inherit MainActor isolation when Core Audio invokes it on a background thread. It copies into a bounded, preallocated queue (96 slots, up to 8,192 frames each), using atomic admission and coalesced worker wakeups. Conversion, sample accumulation and recognition delivery run on a separate serial processing worker, not inside the tap. Overflow, oversized buffers, overlapping callbacks or format changes fail closed rather than growing the queue or blocking capture. Before constructing the engine, the app checks that the requested input device exists and has input channels. It reacquires a coherent route/format and checks again immediately before installing the tap. Device-disconnection races in the native API remain possible; Swift guards cannot catch an Objective-C exception.

**System default** leaves the engine's default route alone. Core Audio may expose a process-local aggregate rather than the physical microphone as the engine's current device; a different ID alone is not an error. Startup still requires an available default input, readable current route, stable snapshots and compatible formats. An explicit microphone must match the selected device and is assigned to that engine only, not made the system-wide default; an unavailable selected device is not silently replaced. A configuration notification triggers validation, not automatic cancellation. Healthy unchanged capture continues.

Startup diagnostics distinguish device discovery, current-device query failure, explicit route mismatch, unready formats and unstable configuration. `route_matches_requested` means the route satisfies the default/explicit selection policy, not that two device IDs are equal or aggregate membership was proved. `route_kind` is `aggregate` only when Core Audio reports that class, `direct` for a matching device, and otherwise `unknown`. An unknown class alone does not reject the default route. `selected_device_changed` compares the freshly resolved requested input—including the system default—with its baseline; `actual_device_changed` compares the engine's current route. Logs also include numeric current-device status and availability/format checks, but never raw device IDs, names or UIDs.

A stopped or invalidly reconfigured engine ends the current recording; there is no automatic pre-audio rebuild or recovery retry. The controller cancels recording interruptions quietly and discards partial audio. Stop also validates native state so key release cannot bypass an interruption handler still in the queue. Stale callbacks from earlier sessions are ignored; start a new recording after checking the microphone.

Each successfully started recording receives a three-second first-buffer allowance, checked by a periodic monitor. The allowance is not renewed by an automatic recovery attempt. After buffers start, three seconds without another buffer also counts as stalled audio. The recorder records `no_audio_timeout` or `audio_stalled_timeout`; the dictation controller cancels these interruptions quietly and discards partial audio rather than showing a recurring error. Silence still supplies buffers and is not this timeout. Conversion failures and missing/invalid input formats have distinct diagnostic paths.

Recording mode is captured at startup: Hold finishes on release; Toggle finishes on the next press. Release timing uses the physical event timestamp, not delayed callback processing after cold startup. See [dictation and shortcuts](user-guide.md#dictation-and-shortcuts).

## Regression checks and hardware probe

```sh
python3 -I Tests/AudioTests/run-tests.py
python3 -I Tests/HotkeyTests/run-tests.py
bash Tests/DiagnosticsTests/run-tests.sh
python3 -I Tests/LocalizationTests/run-bundle-tests.py
```

Audio tests use synthetic callbacks and simulated native-device state, including optimized callback isolation and a negative control for the old MainActor defect, resampling, stale callbacks, stop races and no-buffer timeout. Diagnostics tests cover schema filtering, rotation, write failures, queued export snapshots and opt-in crash filtering. These checks do not establish that a particular microphone/driver problem is fixed.

For an explicit hardware smoke test with an installed app:

```sh
open -n -W --stdout /tmp/talkless-mic.stdout --stderr /tmp/talkless-mic.stderr \
  /Applications/Talkless.app --args --test-microphone
```

This requires existing microphone permission and uses the system-default input. It captures for three seconds without saving audio, running ASR or pasting. Add `--test-repeat 20` to exercise 20 consecutive recordings with the same recorder (1–30 supported). Add `--test-selected-microphone` to use the microphone saved in Settings instead of System default. These flags are explicit opt-ins to real audio capture; they never request permission automatically.

Success prints the total background audio callbacks and completed recording count. Failure prints `Microphone test failed: <error>` and the app exits nonzero. This mode takes the app's startup path; unlike `--verify-bundle`, it is not isolated from normal settings initialization. It does not exercise the configured hotkey.
