# macOS Voice Input: Six Engineering Research Areas

Research date: 2026-10-29.

> **Historical engineering research, not an implementation checklist already completed.** Original source priority: Apple SDK/documentation, then open-source implementations (VoiceInk, Hex, Handy/handy-keys, OpenWhispr, InputSourcePro, Chromium), vendor help, and GitHub issues. Behavior inferred from source or issue reports requires reproduction on supported macOS versions and target applications. Permission behavior, private attributes, and compatibility are not universal guarantees. Review licenses before copying code.

## 1. Global shortcuts: Fn / Globe and left/right modifiers

### Candidate approach

- An **active session CGEventTap** using `.cgSessionEventTap`, `.headInsertEventTap`, `.defaultTap`, and a keyDown/keyUp/flagsChanged mask can observe and suppress shortcut events. The reviewed VoiceInk implementation used Accessibility permission. Verify actual TCC requirements on each supported OS rather than promising a single permission in every environment.
- `NSEvent.addGlobalMonitorForEvents` is observational and cannot suppress events; keyboard monitoring has permission requirements. HID taps, listen-only taps, and IOHIDManager have different permission behavior. [Hex issue 171](https://github.com/kitlangton/Hex/issues/171) was a lead concerning Input Monitoring. The original draft's claim that a session tap is the *only* suppressing approach was too absolute.
- **Fn detection:** check `flagsChanged` and `keyCode == kVK_Function` (63), then inspect `.maskSecondaryFn`. Do not rely solely on the flag: arrow/function-row events can carry it. [Hex issue 89](https://github.com/kitlangton/Hex/issues/89) reported accidental activation from arrow keys. OpenWhispr's `FN_INTERRUPTED` handling was a reference for cancelling a hold when another key interrupts it; valid multi-key shortcuts need separate handling.
- **System Globe action:** returning `nil` from an active tap may suppress the system action in supported cases, but this requires testing. [VoiceInk issue 983](https://github.com/Beingpax/VoiceInk/issues/983) described an emoji-panel conflict. A clearer user-controlled fallback is System Settings → Keyboard → “Press Globe key to” → “Do Nothing.” The notes recorded `com.apple.HIToolbox` / `AppleFnUsageType` values 0 none, 1 input-source switch, 2 emoji, 3 dictation. These preference details are not a stable public contract. [OpenWhispr's Globe listener](https://github.com/OpenWhispr/openwhispr/blob/main/resources/macos-globe-listener.swift) used private `TISUpdateFnUsageType(0)` and restoration; do not adopt private preference changes without a deliberate review and user consent. A dictation mapping was reported to emit keycode `0xB0`.
- **Left/right modifiers:** keycodes distinguish Command `0x37/0x36`, Option `0x3A/0x3D`, Shift `0x38/0x3C`, and Control `0x3B/0x3E`. Device masks in `IOLLEvent.h` were recorded as Command `0x08/0x10`, Option `0x20/0x40`, Shift `0x02/0x04`, Control `0x01/0x2000`. Remapped/external devices may omit those bits, requiring a generic-flag fallback; see VoiceInk `Shortcut.swift` / `requiringDeviceBit`.

### Failure modes to test

- Handle `tapDisabledByTimeout` / `tapDisabledByUserInput` by re-enabling the tap appropriately. Avoid expensive work in the callback. [Handy issue 1827](https://github.com/cjpais/Handy/issues/1827) reported a severe problem associated with repeated `CGEventTapIsEnabled` polling; treat its precise cause as an issue report, not a universal kernel diagnosis.
- A dedicated run-loop thread avoids main-thread stalls; VoiceInk's `ShortcutEventTapThread.swift` is a reference. Wake/unlock may require tap recreation; the original notes cited Hex issue 250.
- **Secure Input:** regular key events may be unavailable while some modifier events still arrive. Wispr documentation reportedly described Fn holding as working while Fn+Space/Escape were blocked. Verify this rather than relying on it for cancellation. `IsSecureEventInputEnabled()` can inform diagnostics; the `kCGSSessionSecureInputPID` dictionary key used by some tools is undocumented. Do not bypass protected fields or assume synthetic input will work there.
- Many non-Apple keyboards do not expose Fn as an ordinary host event; provide another configurable shortcut.
- Some raw-input apps may mishandle synthesized Command-V timing; [Handy issue 164](https://github.com/cjpais/Handy/issues/164) described receiving only “v.”

References: VoiceInk `Features/Shortcuts/Coordination/ShortcutMonitor.swift` and `ShortcutEventTap.swift` (GPL); Hex `Hex/Clients/KeyEventMonitorClient.swift` (MIT); handy-keys `src/platform/macos/listener.rs` (MIT). These paths belong to upstream repositories, not this repository.

## 2. Caret screen coordinates

### Proposed fallback chain

1. `AXUIElementCreateApplication(pid)` → `kAXFocusedUIElementAttribute`. Use a bounded messaging timeout, such as 0.1–0.2 seconds, and keep blocking AX IPC away from latency-sensitive work.
2. **WebKit/Chromium:** investigate `AXSelectedTextMarkerRange` and parameterized `AXBoundsForTextMarkerRange`; InputSourcePro's `findWebAreaCursor` was the reference. Some attributes are not public cross-app contracts.
3. **Native text:** obtain `kAXSelectedTextRangeAttribute`, then `kAXBoundsForRangeParameterizedAttribute` for a zero-length selection. Empty fields/line ends may return empty rectangles; adjacent-character geometry can be a fallback, with care at wrapped lines and grapheme boundaries.
4. **JetBrains:** the notes reported JBR merging zero-length ranges with the preceding character. InputSourcePro's `JavaCursorGeometry`, keyed by `com.jetbrains.` bundle IDs, was a compatibility reference, not a guarantee for all JBR versions.
5. Fall back to focused-element position/size, then pointer position, then a stable window/screen-relative location. Large web-area bounds are not caret bounds. Convert AX's top-origin coordinates carefully for multiple displays; do not assume every display uses a single main-screen height transform.
6. **Electron/Chromium accessibility activation:** investigate `AXManualAccessibility` on the app element and Chrome's `AXEnhancedUserInterface`. [Electron documentation](https://www.electronjs.org/docs/latest/tutorial/accessibility) describes accessibility activation. Attribute availability and side effects require testing.

Expected compatibility in the original notes, **not measured success rates**:
- AppKit and Safari were promising native/TextMarker paths.
- Chrome and Electron apps such as VS Code, Slack, Notion, and Feishu/Lark may need accessibility activation.
- WeChat's custom views, Office, Terminal/iTerm, and Ghostty were unverified or inconsistent.
- JetBrains may require special geometry handling.

References: InputSourcePro `Utilities/Accessibility/AXSwift.swift`; Sentient-OS `CaretLocator.swift`; CopilotForXcode `WidgetPositionStrategy.swift`.

## 3. Text insertion

| Method | Research observations | Caveats |
|---|---|---|
| Clipboard + Command-V | Common default in the reviewed Superwhisper, Wispr, VoiceInk, Hex, and Handy implementations | Clipboard restoration, clipboard history, target-app paste semantics, focus changes |
| CGEvent Unicode injection | Some products offer simulated keypresses for compatibility | Target apps may ignore Unicode payloads, interpret keycodes, split undo, or reject synthetic input. Secure fields are not guaranteed to accept it. |
| AX `kAXSelectedTextAttribute` assignment | Potential AppKit fast path | Some WebKit targets may report success without applying it; Chromium/Electron web content and Gecko behavior vary. Verify actual insertion, not only API return status. |

The old proposal used clipboard paste by default and considered Unicode injection for terminals. **Do not treat Secure Input as a reason to force insertion into protected fields.** Choose an explicitly tested path and preserve user control.

- **Synthetic paste:** the notes proposed `CGEventSource(.privateState)` and separate Command-down/V-down/V-up/Command-up events with about 10 ms spacing. Timing is a compatibility parameter to test. Resolve the paste key appropriately for the keyboard layout; Hex used Sauce.
- **Unicode chunks:** VoiceInk `DirectTextTyper` reportedly used 20 UTF-16-unit chunks and 10 ms intervals. This is an implementation choice, not a universal platform limit. Do not split surrogate pairs or grapheme sequences. Newlines/tabs and Return/Shift behavior need separate testing; the draft recorded dropped leading control characters in some targets.
- **Clipboard restoration:** snapshot all supported pasteboard items before changing them. Types such as `org.nspasteboard.TransientType`, `ConcealedType`, and `AutoGeneratedType` can advise cooperating clipboard managers, but are not a confidentiality boundary. Restore only if `changeCount` still identifies the app's own write; never overwrite a newer user clipboard change. The notes recorded delays of at least 0.25 s in VoiceInk and 0.5 s in Hex, not universal safe timing.
- Handy `paste_tx/macos.rs` used promised data through `declareTypes:owner:` / `pasteboard:provideDataForType:` to observe data requests. A request is useful evidence, not proof that the target finished inserting. Clipboard formats such as files, PDF, RTFD, and audio need explicit preservation testing.
- **Undo:** one paste often corresponds to one undo operation; chunked injection may create multiple undo groups in Monaco/web editors. Neither behavior is guaranteed across applications.

References: VoiceInk `Infrastructure/SystemIntegration/Paste/{CursorPaster,DirectTextTyper,ClipboardManager}.swift`; Hex `Hex/Clients/PasteboardClient.swift`; Handy `paste_tx/macos.rs`; TypeWhisper `TextInsertionService.swift` for post-paste validation ideas.

## 4. Reading selected text

- Candidate AX fallback chain: `kAXSelectedText` → `AXSelectedTextMarkerRange` plus `AXStringForTextMarkerRange` → `kAXSelectedTextRange` plus `kAXStringForRange`. VoiceInk `SelectedTextService.swift` used a 0.1-second timeout and distinguished empty selection from unavailable access.
- A user-authorized copy fallback can snapshot clipboard state, send Command-C to the intended app, and wait briefly for a change. The draft proposed at most 0.5 seconds and accepting only exactly one `changeCount` increment. This reduces ambiguity but does not prove the clipboard change came from the expected selection; concurrent clipboard writers remain possible.
- VS Code and other editors may copy a whole line when nothing is selected. Electron accessibility may need activation. Protected fields may expose no selected text; do not attempt to defeat that protection.

## 5. Audio

- **Startup latency:** opening CoreAudio input and changing Bluetooth profiles can delay capture and lose initial speech. VoiceInk issue 996 reportedly described about 0.5 seconds, longer after extended idle; this is not a universal number.
- Two warmup references: VoiceInk's AUHAL path (`kAudioUnitSubType_HALOutput`, `Infrastructure/Audio/CoreAudioRecorder.swift`) initialized a selected input before starting, without changing the system default. Hex's `SuperFastCaptureController.swift` kept an `AVAudioEngine` and one-second ring buffer, with about 0.45-second pre-roll on activation and teardown on lock/sleep. Continuous capture/pre-roll has privacy and power implications and must be explicit to users, not silently enabled.
- **AirPods/Bluetooth:** using a Bluetooth microphone may switch profiles and reduce playback/capture quality. The original notes described HFP/SCO and 8/16 kHz input, but exact behavior depends on hardware/OS. Reviewed products suggested the built-in microphone with headphones used only for output. Detect transport via `kAudioDevicePropertyTransportType` / `kAudioDeviceTransportTypeBluetooth`; explain options rather than silently changing user device selection.
- VoiceInk issues 659 and 459 were references for Bluetooth quality and waiting for the playback profile to recover after recording. Persistent microphone warmup can keep a headset in a lower-quality profile, so do not apply it indiscriminately.
- The draft recorded `AVAudioSessionCategoryOptionBluetoothHighQualityRecording` as unavailable on macOS. Verify the current SDK; absence of that API does not establish that no hardware/OS path can provide improved audio.
- **Device changes:** `AudioObjectAddPropertyListenerBlock` on `kAudioHardwarePropertyDefaultInputDevice` can track default-input changes. Debounce Bluetooth device notifications; handle lid closure, device disappearance, and sample-rate changes. VoiceInk issues 566 and 956 described built-in-mic disappearance and stale-AUHAL empty recordings.
- **VAD candidates:** Silero through whisper.cpp or FluidAudio, and macOS Speech framework `SpeechDetector` where supported. Choosing VAD is not evidence that silence hallucinations are already solved.

## 6. Distribution and permissions

These are research directions, not a claim that Talkless has shipped or been notarized.

- **Signing/notarization:** Developer ID Application signing, Hardened Runtime, secure timestamp, and no release `get-task-allow`. A typical pipeline is archive/export → `xcrun notarytool submit --keychain-profile <profile> --wait` → staple/validate; sign/notarize/staple the distributed container as appropriate. Verify current Apple instructions and artifact-specific steps. VoiceInk `scripts/release.sh` was a reference.
- **Entitlements:** review `com.apple.security.device.audio-input` for microphone access under Hardened Runtime. `com.apple.security.cs.disable-library-validation` and `com.apple.security.cs.allow-jit` should be added only when the selected dependencies actually require them, not as blanket defaults.
- **Info.plist:** provide `NSMicrophoneUsageDescription`; check Speech authorization and `NSSpeechRecognitionUsageDescription` requirements for the exact API path. The draft mentioned `NSAccessibilityUsageDescription`, but its effect as a public macOS TCC usage-string mechanism was not established; do not rely on it to customize the system Accessibility prompt. `LSUIElement` supports a menu-bar/accessory app shape when desired.
- **Sparkle 2:** references included `generate_keys`, `SUPublicEDKey`, `SUFeedURL`, `generate_appcast`, and `SPUStandardUpdaterController`. Keep update signing keys private and validate the current integration/security requirements. Non-sandboxed distribution does not eliminate all helper/configuration considerations.
- **Permission onboarding:** `AXIsProcessTrustedWithOptions` with `kAXTrustedCheckOptionPrompt` can request Accessibility guidance. A Settings deep link recorded in the notes was `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`; deep links may change. Distinguish granted trust from a working event-tap session and provide recovery instructions without aggressive polling.
- **Development identity:** TCC associates permission with code identity/designated requirements. Ad-hoc signatures can make iterative builds lose trust; stable development signing with consistent team/bundle identity may help. Review Apple TN3127. `tccutil reset Accessibility <bundle-id>` is a troubleshooting action with user-visible consequences, not an automatic startup step.
- Sparkle/framework loading under library validation depends on signatures and configuration. Diagnose the actual failure before weakening validation. OS upgrades may also require users to revisit permission settings.
