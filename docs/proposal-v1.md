# Talkless v1 Proposal — Historical Research Synthesis

> **SUPERSEDED: this is not the current implementation plan.** The later decision is to use **one Qwen ASR model and session for live preview and final transcription**, without an Apple preview model or a second ASR pass. See [the single-Qwen measurement report](research/06-qwen-streaming-measurement.md).
>
> Date: 2026-10-29. This proposal originally synthesized research notes 01–05 and an inspection of the prototype at that time. It is retained as historical design context. Its recommendations are not claims of implemented features. Competitor behavior, licenses, prices, model availability, and external benchmark figures in the early research require independent verification. In particular, incomparable Apple/open-model results do **not** establish an error-rate ratio, and the cited results do **not** establish that OpenAI or overseas services are generally worse at Mandarin-English dictation.

## 1. Original proposal in one sentence

Keep the prototype's native Swift structure, CGEventTap, transcription-session abstraction, clipboard insertion, and HUD, while changing the recognition engine and interaction. The **original, now-superseded** proposal used Apple only for live preview and Fun-ASR-Nano / Qwen3-ASR-0.6B for final recognition, with optional MLX Qwen3.5-2B or remote DeepSeek/Qwen cleanup, and separate shortcuts plus post-insertion replacement instead of a mandatory choice after release.

## 2. Research observations that informed the original proposal

These are historical research leads, not verified product or benchmark conclusions:

1. No official Typeless source repository was identified in the original search. Community alternatives were found, including SpeakMore's reported 18 reverse-engineering notes for Typeless 2.8.1. Swift projects worth reviewing included kitlangton/Hex, Voxt, openquack, platx-ai/Talk, and VoiceScribe. Review licenses before reuse: the notes identified VoiceInk/FluidVoice as GPL and openless as AGPL; permissive licenses also carry obligations.
2. Third-party Typeless 2.8.1 analysis described toggle recording rather than push-to-talk, no live text preview, cloud processing, and transmission of audio plus application/window/text context. This is version-specific third-party reporting, not a current independent privacy audit.
3. Doubao's input-method architecture may use marked text for interim inline output. Its exact underline implementation was **unverified**. A non-IME overlay is a different approach and requires its own usability validation.
4. One third-party Apple test reported Mandarin CER of about 7.8% on 50 FLEURS sentences. Open-model papers reported other results under different conditions. **No like-for-like Apple versus Qwen/Fun-ASR comparison was established; the original draft's 2.5–3x claim was unsupported and has been withdrawn.**
5. Qwen3-ASR, Fun-ASR-Nano, FireRedASR2, and Swift-accessible runtimes were promising local candidates. The notes recorded small quantized models and hotword results, but artifact size, license, runtime support, and target-device performance need checking for the exact version.
6. Cloud providers expose different language, hotword, streaming, and commit capabilities. Benchmark tables and language-support lists do not prove a general domestic-versus-overseas quality ranking. Volcengine was an original candidate, not a measured winner.
7. Apple Foundation Models availability was a concern for mainland-China users. Availability must be checked at runtime and against current Apple documentation; anticipated launches are not established availability.
8. A third-party cleanup experiment favored some 2B–4B models over smaller candidates on its own tasks. This does not establish a universal parameter-count threshold or Mandarin quality. The proposed Qwen3.5-2B latency was an estimate, not a Talkless measurement.
9. Separate shortcuts and mode systems appeared in several researched products. No post-release-choice design was found in that search; that is not proof that none exists.
10. The engineering notes identified reusable patterns for event taps, Fn keycodes, clipboard handling, and overlays. Their applicability still requires testing on supported macOS versions and target applications.

## 3. Original proposed architecture — superseded, not an implementation inventory

```text
Shortcuts   Active session CGEventTap on a dedicated run loop;
            recreate after wake/unlock; detect Secure Input.
            Hold Fn = raw; hold Fn+Shift or right Command = cleanup;
            tap = hands-free; Escape = cancel.
Audio       Preinitialized AUHAL; Bluetooth-input warning;
            Silero / SpeechDetector voice activity detection.
Recognition TranscriptionSession abstraction:
            - Apple volatile results for live overlay preview.
            - Local Fun-ASR-Nano / Qwen3-ASR-0.6B final pass,
              or Volcengine / user-supplied HTTP endpoint.
Cleanup     LLMClient with bounded output, warmup, timeout, raw fallback:
            - MLX Qwen3.5-2B 4-bit, resident with prefix cache.
            - Optional Apple Foundation Models when available.
            - OpenAI-compatible remote service.
Insertion   Clipboard + Command-V by default;
            evaluate Unicode chunks for terminal compatibility.
            Optional shortcut replaces recently inserted raw text;
            preserve application undo where supported.
Overlay     Caret-relative placement with fallback:
            TextMarker → selected range → focused element → mouse
            → bottom of screen.
Distribution Developer ID, notarization, Sparkle 2 / EdDSA;
             stable development signing for Accessibility identity.
```

The two-model recognition branch above is retained only to explain the old proposal. It must not be used as the current roadmap. Secure Input is not a permission to bypass protected fields; insertion behavior requires explicit compatibility and safety testing.

## 4. Original cleanup interaction recommendation — pending design questions

Combine **a (separate triggers) + d (post-insertion replacement) + e (per-app defaults)** from the brief; do not require c (post-release choice) or f (automatic selection) initially.

- Separate triggers: hold `Fn` for raw output; hold `Fn+Shift` or another modifier for cleanup. Choose at recording start without an extra confirmation step.
- Post-insertion replacement: within a proposed 10-second window, press `Fn+Tab` or another shortcut to replace the recently inserted text with cleaned output. A second press or Command-Z would restore the original **if reliable targeting and undo can be implemented**.
- Per-app defaults: raw in terminals/IDEs, cleanup in mail/documents. The two triggers could mean default mode and inverted mode.
- Rationale: a mandatory post-release choice adds an action to every dictation; automatic cleanup selection may be unpredictable. These are design judgments, not validated usability findings.

Proposed state flow:

```text
idle → press → recording(mode selected by shortcut)
                ├─ tap <300 ms → hands-free recording
                ├─ Escape/cancel → idle
                └─ release/stop → finalizing → optional cleanup → inserting
                                     └─ timeout/failure → raw fallback
inserting → written (proposed 10-second window)
              ├─ replacement shortcut → replace with cleaned version
              └─ window expires → idle
```

## 5. Original change list — historical priorities, not completed work

| Priority | Proposed change | Original rationale |
|---|---|---|
| High | Apple preview plus sherpa-onnx Fun-ASR-Nano / Qwen3-ASR-0.6B final pass | Research 02; **superseded by single Qwen** |
| High | Second recording trigger and post-insertion replacement shortcut | Section 4 |
| High | Caret-following overlay with bottom-screen fallback | Research 05, section 2 |
| High | Data-delimited cleanup prompts, structured output, empty-result fallback | Research 04, section 5 |
| Medium | Cloud streaming adapters; explicitly scoped custom-endpoint compatibility | Research 03, section D |
| Medium | Optional local MLX cleanup and Apple FM backend | Research 04, section 2 |
| Medium | Dedicated tap thread, wake/unlock recovery, Secure Input diagnostics | Research 05, section 1 |
| Medium | AUHAL preparation and Bluetooth-input warning | Research 05, section 5 |
| Medium | Evaluate terminal-compatible Unicode insertion | Research 05, section 3 |
| Low | Sparkle, notarization scripts, permission onboarding | Research 05, section 6 |

## 6. Originally proposed proofs of concept

1. **Recognition bake-off:** record 100–200 utterances with Mandarin, English technical terms, self-corrections, and quiet speech. Run Apple, Fun-ASR-Nano, Qwen3-ASR-0.6B, and SenseVoice-Small on identical audio with identical normalization. Measure CER, terminology recall, release-to-final latency, and resident memory. This benchmark was proposed, not completed by these notes.
2. **Caret-following overlay:** test Accessibility bounds in Xcode, Safari, Chrome, VS Code, Feishu/Lark, WeChat, Terminal, iTerm, and JetBrains. Quantify actual success rather than assuming universal support.
3. **Cleanup latency and instruction handling:** compare cached MLX Qwen3.5-2B, a remote Flash-class service, and Apple FM on roughly 100-character inputs; measure end-to-end latency and injection probes.

The later [single-Qwen experiment](research/06-qwen-streaming-measurement.md) is a narrower feasibility measurement. It does not substitute for the proposed human-speech bake-off or cross-application testing.

## 7. Questions recorded at proposal time

1. Personal/small-group use or a commercial audience? This affects provider breadth and license review.
2. Mainland-China or overseas users first? This affects provider availability, latency, and billing rather than establishing a quality ranking.
3. Accept separate triggers plus post-insertion replacement? Which key selects cleanup?
4. Keep the hybrid hold-to-talk / tap-for-hands-free interaction? Competitor behavior is reference material, not a decision rule.
5. Accept an initial local-model download, originally estimated at 0.6–1 GB for recognition plus 1.1 GB for cleanup, or make local inference optional? Exact selected artifacts must be measured; these estimates do not describe the later 1.7B test model.
6. Support M1 / 8 GB as the minimum? A lower-memory option would require its own validation.
