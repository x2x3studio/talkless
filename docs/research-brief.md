# Talkless Deep Research Brief

> Purpose: a brief for further research. Provide **sourced conclusions** and **explicit recommendations** for each item; mark uncertainty as **unverified**.
> Date: 2026-10-29.
> Status: historical research questions, not implementation commitments. The subsequent decision is to use **one Qwen ASR model for both live preview and final transcription**, not an Apple-preview/two-model pipeline. See [the single-model measurement report](research/06-qwen-streaming-measurement.md). Earlier research and proposals remain historical notes.

## 0. Background and established constraints

Build a **productivity-oriented macOS voice-input tool**, with Typeless, SpeakMore (speakmore.zephyrxiang.com), and Doubao Input Method (shurufa.doubao.com) as references.

Established constraints:
- **Platform:** macOS first (Apple Silicon, macOS 26+); iOS later.
- **Distribution:** outside the Mac App Store, signed with Developer ID and notarized for distribution from our website. **App Sandbox is not a product requirement.**
- **Product shape:** not an input method (IMK), but an **auxiliary voice-only layer**. Global shortcut → recording → recognition → optional cleanup → insertion into the current application.
- **Models:** support local and remote options. **We do not host models.** Remote inference uses APIs, including enterprise-operated endpoints; local inference uses on-device models or user-operated services.
- **Stack:** prefer native Swift / SwiftUI so core code can eventually be shared with iOS.

Core experience goals:
1. **Show transcription while the user speaks.** A non-IME app must use an overlay rather than an input method's underlined marked text. Insert only when the text is ready.
2. **Make raw versus cleaned-up output a quick per-dictation choice**, for example through different shortcuts or modifier combinations.
3. Accurate recognition, especially **Mandarin mixed with English technical/product terms**, proper nouns, and quiet speech in a quiet environment.
4. Low latency: target roughly one second from shortcut release to text insertion. This is a goal, not an established performance result.

---

## 1. Competitors and open-source projects

**1.1** Compare Typeless, Wispr Flow, SpeakMore, Doubao Input Method for desktop, Superwhisper, VoiceInk, MacWhisper, Aqua Voice, and other relevant products.

**1.2** Record for each:
- Trigger keys, push-to-talk versus toggle, and hands-free mode.
- Live-preview behavior and placement.
- Cleanup selection: global, per session, per application, or separate keys.
- Text-insertion mechanism.
- Local versus cloud recognition and cleanup, and the models used.
- Pricing.
- Privacy policy.

**1.3** **Determine whether Typeless has an official or community open-source version.** The user recalled one, but this had not been verified when the brief was written. Record repository URL, license, stack, activity, and useful modules.

**1.4** Find open-source macOS dictation projects, such as VoiceInk and OpenWhispr, based on actual findings. Evaluate:
- Code quality.
- License obligations, including the implications of GPL-family licenses for a closed-source commercial product.
- Components suitable for study or reuse: shortcuts, text insertion, capture, and model integration. Reuse requires license review.

**1.5** Investigate Doubao desktop voice interactions: activation, interim underlined text, and cleanup controls.

## 2. Per-dictation cleanup interaction — priority

Requirement: users must be able to **quickly choose whether to clean up a particular dictation**.

**2.1** How do competitors handle this?

**2.2** Evaluate benefits, accidental activation, and learning cost for:
- a. Separate triggers: hold Fn for raw output and Fn+Shift or another key for cleanup, or vice versa.
- b. A default mode with a held modifier temporarily selecting the opposite mode.
- c. **Choose after release:** review the live preview, then press Enter for raw insertion or Tab for cleanup and insertion.
- d. **Insert first, clean up afterward:** insert raw text immediately; a shortcut within a few seconds replaces it with cleaned text, with undo support.
- e. Per-app defaults, such as raw in terminals and cleanup in email.
- f. Automatic selection based on length, fillers, self-corrections, rules, or a model.

**2.3** Recommend a combination and describe the full state flow: press, speak, release, preview, insert, cancel, and timeout.

## 3. Speech recognition — priority

The user's hypothesis was that Apple's on-device SpeechAnalyzer **might perform substantially worse than current open models**. This requires a controlled evaluation; results from different corpora, subsets, or scoring rules do not establish a ranking or error-rate ratio.

**3.1 Local / open candidates** — starting points, not a final shortlist:
- Apple SpeechAnalyzer / SpeechTranscriber (macOS 26), as a comparison baseline.
- FunASR: Paraformer, including streaming variants, and SenseVoice-Small.
- FireRedASR.
- Qwen speech-recognition models: verify availability and licenses.
- Whisper large-v3 / turbo through whisper.cpp, WhisperKit, or MLX.
- Streaming models in sherpa-onnx, including Zipformer and Paraformer.
- Other Mandarin or Mandarin-English models released in 2025–2026.

Record for each:
- Mandarin and **Mandarin-English code-switching** character error rate (CER), preferably from public test sets such as AISHELL, WenetSpeech, and code-switching datasets. Keep corpus, subset, normalization, and metric definitions explicit.
- Streaming support.
- Real-time factor and time to first meaningful text on Apple Silicon; ANE, Core ML, and MLX acceleration.
- Download size and memory use.
- License and commercial-use conditions.
- Hotwords or custom vocabulary.
- Punctuation.
- Swift integration path and difficulty.

**3.2 Remote candidates:**
- Volcengine large-model speech recognition, associated with Doubao.
- Alibaba Paraformer realtime and Qwen speech recognition.
- iFlytek.
- OpenAI gpt-4o-transcribe and Realtime.
- Deepgram and ElevenLabs Scribe.
- Groq Whisper.

Record protocol (WebSocket input streaming versus complete-audio upload), code-switching quality, first-text and finalization latency, pricing, hotwords, and data retention.

**3.3 Historical architecture question: is two-pass recognition practical?**
- Original idea: a lightweight streaming model produces previews, then a stronger non-streaming model reprocesses the complete recording after release.
- Questions: added latency, preview/final differences, and mature examples such as FunASR 2pass.
- **This is no longer the selected architecture.** The later single-Qwen decision uses the same model and session for preview and final output.

**3.4 Requested recommendations:**
- One default local option, one default remote option, and one minimum-hardware option.
- A small evaluation set covering code-switching, technical terminology, self-corrections, and quiet speech, with a reproducible measurement method.

## 4. Cleanup with a language model

**4.1 Local options:**
- Apple Foundation Models: Mandarin quality and **availability on mainland-China devices/accounts**.
- Small MLX models, for example Qwen-family models from 1.5B to 8B.
- Ollama / LM Studio.

Measure filler removal, self-correction handling, punctuation, and list formatting for both quality and latency.

**4.2 Remote options:** OpenAI-compatible services. Compare time to first token, price, and Mandarin quality; recommend two or three defaults only after verification.

**4.3 Prompt design:**
- Prevent the model from answering or executing dictated content; test prompt-injection resistance.
- Include personal vocabulary and application context without treating them as instructions.
- Streaming versus complete-response output.

**4.4 Latency budget:** set targets for recognition + cleanup + insertion, and evaluate connection warming, streamed output, and speculative cleanup. Distinguish estimates from measurements.

## 5. macOS engineering questions

**5.1 Global shortcuts:**
- Listen for Fn / Globe and handle conflicts with the emoji panel and system dictation.
- Distinguish left/right modifiers.
- Compare CGEventTap and NSEvent global monitoring, including Accessibility and Input Monitoring permissions.

**5.2 Caret placement:**
- Obtain caret screen bounds through Accessibility and measure success in native apps, Chrome, Electron apps (VS Code, Slack, Feishu/Lark, WeChat), terminals, and JetBrains IDEs.
- Define fallbacks when bounds are unavailable.

**5.3 Text insertion:** compare compatibility, speed, undo, and clipboard effects for:
- Clipboard + Command-V.
- Unicode input through CGEvent.
- Direct Accessibility text assignment.

**5.4 Selected text:** assess application compatibility for future voice rewriting and selection translation.

**5.5 Audio:**
- First-recording startup latency.
- Bluetooth microphone profile changes and playback-quality degradation, including AirPods.
- Input-device selection.

**5.6 Distribution:** Developer ID signing, notarization, Hardened Runtime entitlements, Sparkle updates, and permission onboarding.

## 6. iOS — later feasibility research only

- Keyboard extensions cannot directly access the microphone. How do Doubao and Typeless handle this, for example by switching to a containing app for recording?
- Assess experience and App Review implications.
- Plan Swift Package boundaries for shared macOS/iOS core code.

---

## 7. Expected deliverables

1. Competitor comparison and useful interaction patterns.
2. Recommended cleanup-selection interaction and state flow.
3. Recognition recommendation matrix with sources, clearly separating historical two-pass ideas from the later single-model decision.
4. Cleanup recommendations and latency budget.
5. macOS technical findings and known pitfalls.
6. Proposed first-version architecture and two or three initial proofs of concept.

Research requirements: prioritize primary sources (official documentation, papers, repository READMEs, and benchmarks), record dates, and state whether pre-2025 information still applies. Treat unverified research notes as leads, not measured evidence.
