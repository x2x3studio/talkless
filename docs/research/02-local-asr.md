# Local ASR Candidates for Mandarin-English Dictation on Apple Silicon

Research date: 2026-10-29. Original target: macOS 26 / Apple Silicon.

> **Historical, unverified research notes — not a controlled benchmark.** The original researcher reported search-tool timeouts and relied mainly on READMEs, model cards, papers, and repository files. Numbers below are source-reported observations with differing corpora, subsets, normalization, hardware, and runtime settings. They do not establish a ranking for Talkless or a relative Apple/open-model error rate. Model availability, licenses, and integration claims require verification against exact artifacts.
>
> **The Apple-preview + second-model-final recommendations in section 4 are superseded.** The later decision uses one Qwen model/session for both preview and final transcription. See [the actual single-Qwen experiment](06-qwen-streaming-measurement.md), which establishes limited feasibility, not human-speech accuracy or production readiness.

## 1. Main research leads

1. A third-party `fmasi/parley` note dated 2026-07-16 reported Apple SpeechTranscriber Mandarin **CER 7.8%** on **50 FLEURS test sentences**, using an M5 Pro and macOS 26.5.1; Japanese and Korean results were 7.2% and 4.0% [1]. Other papers reported Qwen3-ASR-1.7B 2.41%, Qwen3-ASR-0.6B 2.88%, Fun-ASR-Nano 2.56%, Whisper large-v3 4.09%, and Dolphin-small 4.6% for their FLEURS-Mandarin evaluations. **These are not a matched evaluation. The original draft's claim that Apple had 2.5–3 times the error rate was unsupported and is withdrawn.** A common dataset label alone does not make a 50-sentence subset comparable to another study.
2. Qwen3-ASR-0.6B/1.7B, Fun-ASR-Nano 0.8B, and FireRedASR2 were promising recent candidates in the original survey. Papers reported competitive Mandarin results, but this does not prove universal superiority over Paraformer or SenseVoice on dictation, quiet speech, or code-switching.
3. Several Swift integration paths were identified: sherpa-onnx's SwiftPM binary package [2], FluidAudio's Core ML/ANE integrations [3], and mlx-audio-swift [4]. Support varies by runtime version, model artifact, streaming mode, and precision; an API or example is not proof that every listed model works in Talkless.
4. The search found little directly comparable public **Mandarin-English code-switching** reporting for the newer candidates on ASCEND/TAL-CSASR. The Fun-ASR paper reported internal code-switching WER of 1.55–4.49% [5], and FireRedASR2S described code-switching training data [6]. A human-recorded Mandarin-plus-technical-terms test set remains necessary.

## 2. Candidate matrix

The Mandarin column preserves the original notes' source-reported figures in this order: **AISHELL-1 / AISHELL-2 / WenetSpeech-net / WenetSpeech-meeting / FLEURS-zh**, in percent. A dash means no figure recorded. **Check each source's metric and normalization before comparing; these rows were not measured under one protocol.** Model/runtime sizes and speed claims likewise refer to differing artifacts and environments.

| Model | Recorded Mandarin error figures | Streaming | Size / memory notes | Recorded license | Hotwords | Punctuation | Swift path / caveats |
|---|---|---|---|---|---|---|---|
| **Apple SpeechTranscriber**, macOS 26 | — / — / — / — / **7.8**, third-party 50-sentence subset [1] | Volatile → final results | System-managed assets/processes; not zero total system memory | System API terms | `AnalysisContext.contextualStrings`; effect unmeasured here [7] | Yes | Native API |
| **Qwen3-ASR-1.7B** | — / 2.71 / 4.97 / 5.88 / 2.41 [8] | Paper described dynamic attention windows and 2 s chunks; streaming FLEURS-zh 2.84 | Notes recorded about 2B total parameters, bf16 about 4 GB / 8-bit about 2 GB; verify artifact | Apache-2.0 | Context biasing / terminology in prompt, runtime-dependent | Yes | mlx-audio-swift, including `generateStream` [4] |
| **Qwen3-ASR-0.6B** | — / 3.15 / 5.97 / 6.88 / 2.88 [8] | As above; streaming FLEURS-zh 3.40 | 0.6B; sherpa-onnx int8 artifact dated 2026-03-25 in notes | Apache-2.0 | As above | Yes | sherpa-onnx / mlx-audio-swift |
| **Fun-ASR-Nano 0.8B**, 2025-12 | 1.80 / 2.75 / 6.01 / 6.60 / 2.56 [9] | vLLM path reported 720 ms chunks; sherpa-onnx path recorded as offline | 0.8B, including a 0.2B encoder and Qwen3-0.6B | Apache-2.0 | Paper reported recall ≥0.97 on its hotword evaluation [5] | Yes | sherpa-onnx `funasr-nano`; int8 artifact dated 2025-12-30 |
| **FireRedASR2-AED**, 2026-02 | 0.57 / 2.51 / 4.57 / 4.53 / — [10] | Offline, up to 60 s segments | 1B+; recorded int8 encoder 779 MB + decoder 398 MB; CTC artifact 740 MB | Apache-2.0 | None recorded | Separate FireRedPunc | sherpa-onnx `fire-red-asr`; source reported single-thread CPU RTF 0.33 AED / 0.17 CTC [11], hardware-specific |
| FireRedASR2-LLM | 0.64 / 2.15 / 4.44 / 4.32 / — [10] | Offline | 8B+ | Apache-2.0 | None recorded | Separate punctuation | Higher resource demand; not shortlisted originally |
| **Paraformer-large**, offline | 1.95 / 2.85 / 6.74 / 6.97 / — [12] | Offline | 220M; Core ML int8 artifact 207 MB; source-reported peak 0.24 GB | FunASR model license; commercial-use terms **unverified** | SeACo/Contextual variant: source-reported hotword-subset CER 10.0→4.55 and recall 16→74% [12] | Separate CT-Punc | FluidAudio `ParaformerManager`; source reported ANE RTFx 84x and AISHELL-1 2.12% [13] |
| **Paraformer-large**, streaming zh-en | No official figure recorded | 600 ms chunks | sherpa-onnx int8 encoder 158 MB + decoder 68 MB; source RTF 0.15 [14] | As above | Generic sherpa-onnx hotword mechanism was documented for transducers, not this path | Separate punctuation | sherpa-onnx `OnlineParaformer` |
| **SenseVoice-Small** | 2.96 / 3.80 / 7.84 / 7.44 / — [15] | Offline | 234M; Core ML int8 225 MB | Code MIT; weights under FunASR terms | None in official path recorded | `use_itn` includes punctuation | FluidAudio `SenseVoiceManager`, source ANE RTFx 97x [16]; sherpa-onnx artifact about 228 MB |
| Whisper large-v3 | 5.14 / 4.96 / 10.48 / 18.87 / 4.09 [15][8] | Chunked/pseudo-streaming integrations | 1.55B; source memory estimate 3.9 GB | MIT | Prompt biasing only | Yes | WhisperKit / whisper.cpp |
| Whisper large-v3-turbo | No public Mandarin figure located in original search | As above | 809M | MIT | Prompt | Yes | WhisperKit |
| sherpa-onnx streaming Zipformer zh-en, 2023-02 | Not recorded | Transducer | int8 174 MB | Apache-2.0 | Aho-Corasick, `cjkchar+bpe` [17] | No | Swift API; `reset(hotwords:)` runtime vocabulary changes |
| Nemotron 3.5 ASR Streaming Multilingual 0.6B | Source FLEURS-zh 18.1–19.5 [18] | Yes | 0.6B | OpenMDW-1.1 | Reported support | Yes | FluidAudio; original notes did not favor it for Mandarin, without a matched test |
| Dolphin-small, 2025-03 | Source FLEURS-zh 4.6 [19] | Offline | 372M | Apache-2.0 | None recorded | No | sherpa-onnx CTC |
| GLM-ASR-Nano, 2025-12 | Official average 4.10 recorded; not a per-corpus Mandarin figure [20] | Offline | 1.5B | Apache-2.0 | Not located | Not recorded | mlx-audio-swift |
| Ming-3.0-ASR-Tiny / MiMo-V2.5-ASR | Figures only in charts in reviewed sources | Offline | 9B / 8B | MIT, as recorded; verify artifacts | Ming hotwords reported | Not recorded | mlx-audio-swift; higher resource demand |
| Parakeet/Canary, Kyutai STT, Moonshine | Reviewed variants were recorded as lacking Mandarin [21]; do not generalize to every family/version | Not evaluated | Not evaluated | Verify exact variant | Not evaluated | Not evaluated | Excluded from original Mandarin shortlist |
| Voxtral Mini 4B Realtime, 2026-02 | Source FLEURS-zh 10.45 / 5.50; conditions not preserved in original notes | Yes | 4B | Apache-2.0 | None recorded | Not recorded | Requires source recheck before interpreting figures |

Other original exclusions: Step-Audio 2 mini and Kimi-Audio were recorded as at least 7B; TeleSpeech-ASR was described as a 2024 dialect-oriented CTC model. These were resource-oriented shortlist decisions, not accuracy findings.

## 3. Apple SpeechTranscriber details

- `reportingOptions: [.volatileResults]` provides interim output that is subsequently finalized. No official latency number was located [22]. A MacStories June 2025 English-only review reported 2.2x speed versus MacWhisper large-v3-turbo with no obvious quality difference; it does not establish Mandarin quality or general throughput.
- `AnalysisContext.contextualStrings` is a terminology-biasing API on supported systems [7]. No independent effectiveness measurement was recorded.
- Repository issues described locale-selection and empty-chunk-result problems, including zh-HK selection and `nil` locale falling back to system language. These are leads for reproduction, not universal API behavior. The original draft speculated about Apple's underlying model architecture; no reliable architecture evidence was established here.

## 4. Focused questions and historical recommendations

### A. FunASR 2pass and Apple Silicon

The reviewed FunASR runtime 2pass design used streaming Paraformer-large-online at 600 ms chunks for partials, FSMN-VAD for sentence boundaries, offline Paraformer-large to re-recognize buffered sentence audio, and CT-Transformer punctuation [23]. Contextual-hotword variants were available in that ecosystem. The original notes found Linux/ARM64 Docker server deployment, not a verified native macOS build of that full service.

A possible Apple Silicon composition was sherpa-onnx `OnlineRecognizer` + `OfflineRecognizer` + Silero VAD; an Android two-pass example illustrated the pattern. The **old Talkless proposal** instead suggested Apple volatile preview plus Qwen3-ASR-0.6B or Fun-ASR-Nano final recognition after release.

**That proposal is superseded by single Qwen.** It was never justified by a matched Talkless benchmark. The old latency estimates—about 0.1 s for 10 s of audio using source-reported SenseVoice/Paraformer ANE throughput, 0.5–1.5 s for Qwen3-ASR-0.6B MLX 8-bit, and about 3 s for FireRedASR2-AED single-thread CPU—were extrapolations across different runtimes, **not measured release-to-final latency**. Do not use them as performance commitments.

### B. Hotwords

- Source-reported quantitative evaluations: Contextual/SeACo-Paraformer hotword-subset CER 10.0→4.55 [12]; Fun-ASR-Nano hotword recall ≥0.97 in its evaluation [5]. sherpa-onnx transducer hotword documentation describes the mechanism [17], not a Talkless terminology score.
- Mechanisms without measured effectiveness here: Qwen3-ASR prompt context, Apple `contextualStrings`, and WhisperKit prompts.
- No official mechanism was identified in the reviewed paths for FireRedASR, SenseVoice, or Dolphin.
- Prompt-based biasing might suit technical vocabulary, but large-vocabulary recall and false positives require an A/B test; architectural intuition is not measured superiority.

### C. Original recommendations — retained only as history

- **Original local default:** Apple preview plus Fun-ASR-Nano int8 or Qwen3-ASR-0.6B for final recognition. The draft slightly favored Fun-ASR-Nano because its paper discussed hotwords and code-switching. **This recommendation is no longer current.**
- **Original low-memory option:** Core ML SenseVoice-Small int8, about 225 MB, for final recognition plus Apple preview, subject to model-license review. It was not validated on M1 / 8 GB.
- **Proposed evaluation work:**
  1. Record 200 Mandarin-plus-English-technical-term utterances; compare Apple, Fun-ASR-Nano, Qwen3-ASR-0.6B, and SenseVoice using identical audio, normalization, CER, and term recall.
  2. Measure end-to-end latency and resident memory on target hardware for 5/10/20-second clips across CPU int8, MLX GPU, and Core ML ANE paths.
  3. A/B-test Fun-ASR `hotwords`, Apple `contextualStrings`, and Qwen prompt context.
  4. The old proposal also considered replacing Apple preview with streaming Paraformer later. That two-engine roadmap is superseded, not an outstanding commitment.

The later single-Qwen experiment answers a narrower question: one model can emit previews before input ends and finalize the same session. It does not complete the human-speech evaluation above.

## Sources retained from the original research

[1] https://github.com/fmasi/parley/blob/main/docs/benchmarks/2026-07-16-fluidaudio-vs-speechanalyzer.md

[2] https://github.com/k2-fsa/sherpa-onnx/blob/master/Package.swift

[3] https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md

[4] https://github.com/Blaizzy/mlx-audio-swift

[5] https://arxiv.org/html/2509.12508

[6] https://arxiv.org/html/2603.10420

[7] https://developer.apple.com/documentation/speech/analysiscontext

[8] https://arxiv.org/html/2601.21337

[9] https://github.com/FunAudioLLM/Fun-ASR

[10] https://github.com/FireRedTeam/FireRedASR2S

[11] https://k2-fsa.github.io/sherpa/onnx/FireRedAsr/pretrained.html

[12] https://arxiv.org/html/2305.11013

[13] https://huggingface.co/FluidInference/paraformer-large-zh-coreml

[14] https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-paraformer/paraformer-models.html

[15] https://arxiv.org/html/2407.04051

[16] https://huggingface.co/FluidInference/sensevoice-small-coreml

[17] https://k2-fsa.github.io/sherpa/onnx/hotwords/index.html

[18] https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML

[19] https://arxiv.org/html/2503.20212

[20] https://github.com/zai-org/GLM-ASR

[21] https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3

[22] Apple WWDC25, Session 277.

[23] https://github.com/modelscope/FunASR/blob/main/runtime/docs/SDK_advanced_guide_online.md
