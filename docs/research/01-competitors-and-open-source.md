# Voice-Input Competitors and Open-Source Projects

Research date: 2026-10-29.

> **Historical, unverified research notes.** The original researcher reported search-tool timeouts and used direct website/document fetches and the GitHub API instead. Repository stars, licenses, and last-commit dates below are the snapshot recorded at that time, not a fresh audit. Pricing, behavior, privacy, and availability can change. Third-party reverse engineering is not official product documentation. Interaction details were not independently tested unless stated; absence from this search does not establish that a feature or repository does not exist. Recheck source licenses before reuse.

## 1. Competitor comparison

| Product | Trigger | Live preview | Cleanup selection | Insertion | Recognition / cleanup | Recorded pricing | Privacy notes |
|---|---|---|---|---|---|---|---|
| **Typeless**, third-party analysis of v2.8.1 [^1] | Default Fn or right Command; reported toggle-only recording, with holds over 600 ms cancelled and a warning; Fn+Space for questions, Fn+left Shift for translation | Analysis reported no live text: server acknowledged audio during recording and returned text after completion; bottom overlay followed the pointer's display | Server-controlled, with application-dependent tone; no per-dictation cleanup toggle identified | Clipboard + simulated Command-V, then clipboard restoration; reported 15-second polling for user edits after insertion | Cloud endpoint `api.typeless.com`; Electron 33 client; analysis reported audio plus app, window title, surrounding text, and visible screen text up to 10,000 characters | Free weekly word limit; Pro $12/month billed annually or $30/month [^2] | Official claims of zero retention/no training and third-party LLM providers [^3]; reverse-engineering notes reported terminal/chat context transmission. These are distinct claims requiring current review. |
| **Wispr Flow** | Push-to-talk; Command Mode reportedly Fn+Ctrl, Fn dictation inferred; hands-free via separate binding or double-tap; mouse side buttons [^4] | Flow Bar at bottom showed idle/recording/processing, not live transcript in reviewed documentation [^5] | Global Auto Cleanup levels None/Light/Medium [^6]; application-category Styles [^7]; separate Command Mode for rewriting selections | Paste at caret; Command-Z undo | Cloud audio processing; supplier not disclosed in reviewed source [^8] | Free 2,000 words/week; Pro $12/month annually or $15 monthly [^9] | Model-improvement sharing reportedly enabled by default but optional; dictation cloud storage can be disabled |
| **SpeakMore**, MIT / Electron [^10] | Right Option toggles; right Option+Space translates speech; right Option+Return translates selection; Escape cancels | Bottom overlay with level meter and key hints, no live transcript identified | Global direct audio-model / hybrid local-ASR-to-LLM / offline-local modes; no per-session toggle identified | Native helper inserts at caret | Local Qwen3-ASR 0.6B / SenseVoice; BYOK Gemini, OpenAI, Alibaba, DeepSeek, Kimi, etc. | Software free; API usage billed by providers | Project claims no analytics, Keychain storage, and no relay server |
| **Doubao Input Method, desktop** | Requires the input method to be active; macOS hold Fn and release to stop [^11]; double-tap for hands-free [^12]; Windows hold right Alt or right Alt+Space hands-free [^13] | Streaming text at caret. Underlined marked-text implementation was inferred from IME capabilities, **not verified** | Website described automatic organization and showed a cleanup panel, but exact activation was **unverified**; advertised self-correction handling | IME insertion; Mac reportedly requires microphone and Accessibility access | Cloud recognition/cleanup associated with Seed-ASR | Free | No separate desktop privacy statement located in the original research |
| **Superwhisper** | Right Command push-to-talk; quick tap toggles; Option-Space toggle; hold Option-Shift-K during recording for mode list [^14] | Recording window with waveform/mode; realtime models reportedly show live text | Modes: Voice to Text without AI, others with AI; per-mode shortcuts, per-app activation, switching during recording | Clipboard paste | Local Whisper / Parakeet / Cohere / S1-mini; cloud GPT/Claude-family options; Pro BYOK | Free unlimited local use; Pro $8.49/month, $84.99/year, $249.99 lifetime [^15] | Offline operation available, depending on selected models |
| **VoiceInk**, GPL-3 | Primary/secondary shortcuts with Toggle, Push-to-Talk, Hybrid (0.5 s), or Double-Tap; per-mode keys; panel keys 1–10 [^16] | Notch/mini recording panel | Mode-specific AI enhancement; separate paste-last-raw and paste-last-enhanced shortcuts | Paste | Local whisper.cpp / FluidAudio (Parakeet); cloud enhancement sends text | One-time $25/$39/$49 tiers [^17] | Local transcription path; cloud cleanup has separate privacy implications |
| **MacWhisper** | System-wide dictation | Not recorded | AI prompts and per-app prompts | Not recorded | Local Whisper; Ollama / LM Studio; BYOK | Pro €64 one-time [^18] | Local-processing options |
| **Aqua Voice** | Advertised hold Space to speak; Realtime Mode in Max tier [^19] | Max-tier realtime feature | Custom instructions and Edit Mode | Paste at caret | Proprietary cloud model Avalon | Pro $10/$12, Max $19/$24; original notes did not fully specify billing basis | Advertised Privacy Mode without server storage |

## 2. Typeless source availability

No official Typeless source repository was identified in the original search. The reviewed product was described as a closed-source Electron application. Several independent alternatives use “Typeless” in their names; they must not be confused with an official release.

SpeakMore included a reported **18 reverse-engineering notes for Typeless 2.8.1**, with packet observations, native Swift API lists, and state-machine parameters [^1]. These are version-specific third-party reports.

| Repository | Recorded stars | Stack / recorded license | Recorded latest commit | Potential study material |
|---|---:|---|---|---|
| [Open-Less/openless](https://github.com/Open-Less/openless) | 3,991 | Rust + Tauri 2 / AGPL-3 | 2026-10-29 | Incremental insertion with paste fallback, CGEventTap shortcuts, Style Packs, local Qwen3-ASR |
| [tover0314-w/opentypeless](https://github.com/tover0314-w/opentypeless) | 647 | Rust + Tauri / MIT | 2026-10-22 | Fn / Fn+Space / Fn+left Shift bindings, hold/toggle support, local app-category tone selection |
| [zephyr4123/speakmore](https://github.com/zephyr4123/speakmore) | 166 | Electron / MIT | 2026-10-28 | `targets/typeless/docs/`, `native/mac` shortcut helper, local Qwen3-ASR/SenseVoice evaluation notes |
| [Mor-Li/Whisper-Input-Next](https://github.com/Mor-Li/Whisper-Input-Next) | 93 | Python / MIT | 2026-10-01 | Doubao streaming-ASR integration |
| [platx-ai/Talk](https://github.com/platx-ai/Talk), “Open Typeless” | 25 | Swift / MIT | 2026-04-23 | Local Swift implementation |
| Wentong-Liu/SayIt; kuleka/OpenTypeless; rock74710/TypelessMLX; ZhaoChaoqun/nano-typeless | 49 / 24 / 34 / 15 | Swift / MIT or no license identified | 2026 | Small Swift references; verify each license independently |

Unrelated or misleading search matches included `typeless-js/typeless` (React toolkit), `keyboardDrummer/typeless` (Scala), `mindfold-ai/open-typeless` (framework demo), and `estarpro1022/typeless-reset-device` (a circumvention script, not a product source release).

## 3. Open-source macOS dictation projects

Licenses below are historical observations, not legal advice. Permissive code still requires compliance with license terms. GPL/AGPL code is not suitable for unrestricted copying into a proprietary project; assess obligations before any reuse. Code without a license is not freely reusable by default.

| Project | Recorded stars | Stack | Recorded license / reuse caution | Latest activity recorded | Useful references |
|---|---:|---|---|---|---|
| [cjpais/Handy](https://github.com/cjpais/Handy) | 35,039 | Rust + Tauri 2 + React; rdev, enigo, transcribe-cpp | MIT | 10-27 | Separate `transcribe` and `transcribe_with_post_process` shortcuts; `paste_tx/macos.rs`; Apple-keyboard Fn caveat |
| [altic-dev/FluidVoice](https://github.com/altic-dev/FluidVoice) | 12,590 | Swift | GPL-3; review obligations | 10-27 | Parakeet realtime path, hold-Space-to-mute interaction, Accessibility insertion |
| [OpenWhispr/openwhispr](https://github.com/OpenWhispr/openwhispr) | 10,278 | Electron + React; whisper.cpp, sherpa-onnx, llama.cpp | MIT | 10-29 | Dictation versus Voice Assistant shortcut; selection rewriting |
| [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk) | 6,963 | Swift / SwiftUI; whisper.cpp, FluidAudio, Sparkle, KeyboardShortcuts | GPL-3; notes reported no PR acceptance | 10-29 | ShortcutEventTap, Hybrid detection, per-mode keys, notch panel |
| [EpicenterHQ/epicenter](https://github.com/EpicenterHQ/epicenter), Whispering | 4,828 | Svelte + Tauri | AGPL-3 | 10-29 | Additional architecture reference |
| Open-Less/openless | 3,991 | Rust + Tauri | AGPL-3 | 10-29 | See above |
| [kitlangton/Hex](https://github.com/kitlangton/Hex), archived | 2,898 | Swift; WhisperKit, Sauce, TCA, Sparkle, FluidAudio | MIT | 10-14 | Swift integrations, keycode handling, updates |
| [anomalyco/hex](https://github.com/anomalyco/hex), newer project | 805 | Rust | MIT | 10-29 | Hold Option dictation; Option-Command Voice Action |
| hehehai/voxt → [sglang-omni/Voxt](https://github.com/sglang-omni/Voxt) | 891 | Swift | Apache-2.0 | 10-14 | Live preview and app/URL context |
| [VocaHQ/vocamac](https://github.com/VocaHQ/vocamac) | 159 | Swift | AGPL-3 | 10-28 | Multiple local engines |
| [larryxiao/openquack](https://github.com/larryxiao/openquack) | 54 | Swift / WhisperKit | MIT | 10-19 | Minimal menu-bar implementation |
| [eddmann/VoiceScribe](https://github.com/eddmann/VoiceScribe) | 11 | Swift | MIT | 04-27 | Whisper/Parakeet, optional LLM cleanup, smart paste |
| [savbell/whisper-writer](https://github.com/savbell/whisper-writer) | 1,106 | Python | GPL-3 | Last activity noted: 2024-08 | Older reference |
| [thewh1teagle/vibe](https://github.com/thewh1teagle/vibe) | 7,949 | Tauri | MIT | 10-06 | Primarily file transcription |
| Spokenly / Aiko | Not recorded | Closed source | Not applicable | Not recorded | No reusable source identified |

## 4. Per-dictation cleanup interaction patterns

1. **Separate shortcuts:** Handy distinguishes transcription from post-processed transcription. Other products distinguish dictation, voice actions, questions, or translation. Those actions are **not necessarily equivalent** to a raw-versus-cleanup toggle. VoiceInk also has primary/secondary and per-mode shortcuts.
2. **Switch during recording:** Superwhisper's Option-Shift-K mode list and VoiceInk's numbered mode selection were examples in the reviewed material.
3. **Per-app selection:** Superwhisper app activation, VoiceInk Power Mode, Wispr Styles, and reported Typeless server-side tone adjustment.
4. **Post-insertion actions:** Wispr undo/history actions; VoiceInk paste-last-raw versus paste-last-enhanced; reported Typeless `delivery=replace` behavior using rich-text paste to replace a selection.
5. **Global settings:** Wispr Auto Cleanup levels and SpeakMore's direct/hybrid/offline modes.
6. **Choose after release:** no example was identified in this limited search. Reported post-edit dictionary-learning features in Typeless and OpenLess are different interactions.

**Historical implications for Talkless:** separate shortcuts and modes were worth prototyping, but this research did not validate a preferred interaction. The reviewed Typeless version reportedly migrated `pushToTalk` to `dictationMode`; this does not establish current behavior across versions. For native Swift references, inspect Hex, openquack, Talk, VoiceScribe, and Voxt while checking exact licenses. GPL/AGPL projects can inform research, but copying code requires a deliberate license-compatible decision.

---

[^1]: SpeakMore `targets/typeless/docs/` notes 00, 07, 10, 14, and 15; https://github.com/zephyr4123/speakmore . Packet-analysis date recorded as 2026-10-13.
[^2]: https://www.typeless.com/pricing
[^3]: https://www.typeless.com/privacy
[^4]: https://docs.wisprflow.ai/en/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts
[^5]: https://docs.wisprflow.ai/en/articles/1790396454-move-and-dock-the-flow-bar-on-desktop
[^6]: https://docs.wisprflow.ai/en/articles/4283510616-auto-cleanup-control-how-much-flow-edits-your-dictation-beta
[^7]: https://docs.wisprflow.ai/en/articles/2368263928-how-to-setup-flow-styles
[^8]: https://docs.wisprflow.ai/en/articles/3467817258-security-and-compliance-faq
[^9]: https://wisprflow.ai/pricing
[^10]: https://github.com/zephyr4123/speakmore , README v0.17.1, 2026-10-28.
[^11]: https://www.aihub.cn/tools/doubao-shurufa/ ; https://post.smzdm.com/p/a46mxon7/ (2026-01-16).
[^12]: https://blog.csdn.net/khaxi/article/details/161057140 ; https://shurufa.doubao.com/pc
[^13]: https://www.jamecling.com/archives/6406 (2026-09-09).
[^14]: https://superwhisper.com/docs/get-started/essential-settings.md ; https://superwhisper.com/docs/modes/switching-modes.md
[^15]: https://superwhisper.com/docs/billing/plans.md
[^16]: https://github.com/Beingpax/VoiceInk , `VoiceInk/Features/Shortcuts/Coordination/RecordingShortcutManager.swift`.
[^17]: https://tryvoiceink.com/
[^18]: https://macwhisper.com/
[^19]: https://aquavoice.com/pricing
