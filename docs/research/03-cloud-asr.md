# Cloud ASR Research for Push-to-Talk Dictation

Research date: 2026-10-29.

> **Historical, unverified research notes, not a provider benchmark or integration inventory.** The original researcher reported search-tool timeouts and relied mainly on direct documentation/pricing-page fetches. Model names, prices, protocols, regional availability, and retention terms below were recorded in that early draft and have not been independently revalidated here. Verify current documentation and account-specific terms before implementing or selecting a service. Latency figures are provider claims or estimates unless explicitly identified otherwise; none is a Talkless end-to-end measurement.
>
> The later product direction selects **single-Qwen local preview and final transcription**. These remote-service notes are research context, not evidence that the adapters below are implemented.

## Comparison

Prices are the historical draft's hourly conversions, excluding taxes, network cost, minimum billing, and account-specific discounts unless noted. Regional access descriptions are observations to verify, not guarantees or instructions to bypass restrictions.

| Service | Recorded protocol | Mandarin / English notes | Latency or endpointing notes | Recorded price per hour | Hotwords | Retention notes | Mainland-China availability notes |
|---|---|---|---|---|---|---|---|
| Volcengine Doubao Streaming ASR 2.0 / Seed-ASR | WebSocket custom binary frames; `bigmodel`, `bigmodel_async`, `bigmodel_nostream` | Advertised Mandarin/English plus eight dialects without switching | Recommended 200 ms packets; claimed 300–400 ms return for a 5 s nostream clip; two-pass VAD default recorded as 800 ms | CNY 1 pay-as-you-go; CNY 0.80–0.93 prepaid | `context`; draft recorded 100-token bidirectional / 5,000-word nostream limits, plus vocabulary and replacement lists | **Unverified** | Expected domestic availability; identity verification; enterprise requirement unverified |
| Alibaba Model Studio `qwen3-asr-flash-realtime` | WebSocket with OpenAI-Realtime-style events, including `session.update` / `input_audio_buffer.append` | Automatic multilingual recognition; open-weight Qwen benchmarks do not establish this hosted endpoint's quality | Server VAD default recorded as 800 ms; manual commit; draft described per-session disconnection | CNY 0.00033/s ≈ CNY 1.19/h | Not listed in reviewed notes | **Unverified** | Domestic service; account/identity requirements need checking |
| Alibaba `fun-asr-realtime` | WebSocket `run-task` / `finish-task`, plus SDK | Advertised free switching between Mandarin and English | `max_sentence_silence` controls segmentation | About CNY 1.19/h | Advertised large custom vocabularies | **Unverified** | As above |
| Alibaba `paraformer-realtime-v2` | WebSocket / SDK | Mandarin, Cantonese, English, Japanese, Korean; `language_hints` | Sentence-silence setting | CNY 0.00024/s ≈ CNY 0.86/h | Supported in reviewed documentation | **Unverified** | As above |
| iFlytek dictation `iat` / large-model dictation | WebSocket; session limit recorded as 60 s | `zh_cn` described simple English recognition; large-model offering advertised Mandarin/English plus 202 dialects | `dwa=wpgs` dynamic correction; default `eos` recorded as 2,000 ms | **Unverified** | App-level 2,000-word list plus session `dhw` | **Unverified** | Domestic service |
| iFlytek realtime transcription `rtasr` | WebSocket; 40 ms / 1,280-byte packets | `lang=cn` described Mandarin-English mixed speech | No official latency number recorded | **Unverified** | No hotwords recorded | **Unverified** | Domestic service |
| Tencent realtime recognition | WebSocket + HMAC; 200 ms packets | `16k_zh_en`; Hy-ASR-3.0-preview advertised Mandarin/English plus 20 dialects | `vad_silence_time` 500–2,000 ms | Standard CNY 3.2/h; large-model 2.0 CNY 1/h; standard free allowance recorded as 5 h/month | Up to 128 weighted session entries in `hotword_list`, plus stored vocabularies | **Unverified** | Domestic service |
| OpenAI `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`, `whisper-1` | HTTP `/v1/audio/transcriptions`; output SSE support is distinct from live audio-input streaming and varies by model | Mandarin support; no matched Talkless code-switching evaluation | Complete-audio request path | Draft recorded $0.36 / $0.18 / $0.36; also listed `gpt-transcribe` at $0.27, **model/price unverified** | `prompt`, model-dependent | Draft recorded endpoint-specific no-abuse-log retention and eligibility for ZDR; **verify current endpoint/account terms** | Check supported regions and provider terms |
| OpenAI Realtime transcription; draft named `gpt-live-transcribe` | WebSocket `?intent=transcription`; draft recorded 24 kHz PCM | No matched code-switching evaluation | Draft listed a `delay` setting, client commit, and no server VAD; **all are model/version-specific and need verification** | Draft recorded $0.017/min ≈ $1.02/h; **unverified** | Draft listed `keywords` + `prompt`; verify model schema | Draft recorded 30-day abuse monitoring and possible ZDR; **verify current terms** | Check supported regions and terms |
| Deepgram Nova-3 | WebSocket streaming | Reviewed `multi` code-switching language list did not include Mandarin; single-language support is a separate question | No comparable latency number recorded | $0.46/h streaming | `keyterm` up to 500 tokens in notes; Mandarin support unverified | **Unverified** | Regional access unverified |
| ElevenLabs Scribe v2 Realtime | WebSocket; draft recorded 48 kHz PCM | Advertised 90-language detection; Mandarin placed in a provider “high accuracy” category, not a matched benchmark | Provider claim below 150 ms; not release-to-insertion measurement | $0.39/h; batch $0.22/h; keyterms +$0.05/h | Up to 50 keyterms in notes | Zero-retention mode advertised; eligibility/scope unverified | Regional access unverified |
| Groq Whisper large-v3-turbo | OpenAI-compatible HTTP | Whisper-family support; no measured Talkless code-switching result | Complete-audio input; hundreds-of-ms estimate for short clips **unverified** | $0.04/h; 10 s minimum billing recorded | `prompt`, 224-token limit recorded | **Unverified** | Check supported regions |
| AssemblyAI | WebSocket `/v3/ws` | Reviewed Universal-Streaming multilingual list omitted Mandarin; separately, Universal-3.6 Pro Realtime was reported to include Mandarin/Cantonese. Do not generalize across models. | Billing based on connection duration in reviewed offering | $0.15/h streaming; exact model/tier needs checking | `keyterms` | **Unverified** | Regional access unverified |
| Gemini 2.5 Flash | HTTP complete-audio input | General audio-capable model; no task-specific evaluation here | Not a live-input ASR path in this proposal | About $0.09/h, an estimate dependent on token accounting | Prompt context | Paid-tier no-training statement recorded; verify current terms | Check supported regions |

### Source pages retained from the draft

- Volcengine: https://www.volcengine.com/docs/6561/1354869 and https://www.volcengine.com/docs/6561/1359370 ; original notes used the `docs.volcengine.com` host for the same document paths.
- Alibaba: https://help.aliyun.com/zh/model-studio/qwen3-asr-flash-realtime , https://help.aliyun.com/zh/model-studio/fun-asr-realtime , https://help.aliyun.com/zh/model-studio/paraformer-realtime-v2 .
- iFlytek: https://www.xfyun.cn/doc/asr/voicedictation/API.html and https://www.xfyun.cn/doc/asr/rtasr/API.html .
- Tencent: https://cloud.tencent.com/document/product/1093/35686 and https://cloud.tencent.com/document/product/1093/48982 .
- OpenAI: https://developers.openai.com/api/docs/pricing , https://developers.openai.com/api/docs/guides/realtime-transcription , https://developers.openai.com/api/docs/guides/your-data .
- Deepgram: https://deepgram.com/pricing .
- ElevenLabs: https://elevenlabs.io/pricing/api .
- Groq: https://console.groq.com/docs/speech-to-text .
- AssemblyAI: https://www.assemblyai.com/pricing .
- Gemini: https://ai.google.dev/gemini-api/docs/pricing .
- Qwen benchmark source: https://github.com/QwenLM/Qwen3-ASR .

## A. Short utterances and a one-second release-to-final target

The relevant metric is **tail latency after release**, not the presence of “streaming” in a product name. Two designs were considered:

1. **Streaming input with explicit end/commit:** send audio during recording, show partials, then send the documented end signal on release. Candidate APIs included Volcengine, Alibaba manual mode, OpenAI Realtime, Scribe manual commit, and Tencent/iFlytek end frames. The exact event sequence and endpointing behavior must be checked per model. A commit request does not guarantee immediate final output.
2. **Complete-audio upload:** simpler when no live preview is needed. The original draft recorded a Volcengine claim of 300–400 ms for a 5-second clip and estimates of hundreds of milliseconds for Groq and roughly a second for gpt-4o-mini-transcribe. **Those were not controlled Talkless measurements.**

Server VAD silence thresholds can add avoidable tail delay when the user explicitly stops recording. The draft recorded defaults of 800 ms for Volcengine/Alibaba, 1,000 ms for Tencent, and 2,000 ms for iFlytek. Check whether the chosen API supports manual endpointing; do not blindly disable required VAD or assume these defaults remain current.

## B. What the research does not establish about code-switching

- The original draft claimed domestic models were generally superior to overseas providers, and described OpenAI as worse. **Those generalizations were unsupported and are withdrawn.**
- A Qwen-published benchmark table recorded WenetSpeech figures around 5–6 for Qwen, 15/32 for GPT-4o-Transcribe, and 10/19 for Whisper, alongside FLEURS-zh figures of 2.69 for Doubao, 2.41 for Qwen, and 2.44 for GPT-4o. Metric definitions, model versions, normalization, and evaluation conditions must be checked in the source. These figures are **not a Mandarin-English technical-dictation benchmark**, and do not imply a universal ranking or ratio.
- Advertised mixed-language support from Alibaba and Tencent is a useful capability lead, not an accuracy measurement.
- Deepgram/AssemblyAI support must be checked for the **exact model**, not summarized as a provider-wide absence of Mandarin.
- No common provider comparison on the intended dictation task was completed. A suggested next step was 50 human-recorded Mandarin-plus-technical-term utterances, using the same audio, transcript normalization, error metrics, and network conditions.

## C. Original shortlist — not current defaults or implemented adapters

- For mainland-China accounts, the draft shortlisted **Volcengine Doubao Streaming ASR 2.0**, with Alibaba Fun-ASR/Qwen realtime alternatives, based on advertised protocol, vocabulary, pricing, and regional availability. It did **not** measure the lowest domestic latency or best accuracy.
- For other supported regions, it shortlisted **OpenAI HTTP transcription** and a Realtime option, with **ElevenLabs Scribe** as another streaming candidate. It did not establish that Scribe was better at code-switching.
- For low-cost complete-audio requests without preview, it considered **Groq Whisper turbo**.

These are historical candidates subject to current documentation, region, privacy, and task-specific testing, not final product recommendations.

## D. Provider abstraction

- **Complete-audio HTTP:** many services expose an OpenAI-shaped `/v1/audio/transcriptions` endpoint, including some Groq, Deepgram, Voxtral, whisper.cpp/faster-whisper-server/Speaches, vLLM, and LocalAI deployments. Compatibility is not universal: verify multipart fields, authentication, response format, supported models, and streaming semantics. A configurable base URL + API key + model is a useful interface, not a promise of arbitrary compatibility.
- **Streaming:** there is no single universal protocol. Alibaba has an OpenAI-Realtime-style event API, while Volcengine, Tencent, iFlytek, Deepgram, ElevenLabs, and AssemblyAI use provider-specific schemas. The proposed internal interface was `StreamingASRProvider` with start/append/commit/partial/final concepts and separate adapters. A custom streaming endpoint should claim only a precisely documented event dialect that has been tested.

## Unverified items / follow-up

- iFlytek pricing and AssemblyAI's exact realtime tier pricing.
- Retention, training, abuse-monitoring, and ZDR terms for every exact endpoint/account, especially the domestic providers.
- Identity versus enterprise verification requirements for Volcengine and Alibaba.
- Mandarin support for Deepgram terminology biasing.
- The draft's newer OpenAI model names, pricing, event fields, VAD assertions, and deprecation assertions. Do not treat these historical notes as an API reference.
