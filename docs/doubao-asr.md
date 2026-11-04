# Doubao online speech recognition

Talkless offers two recognition paths: local Qwen3 ASR and online Doubao. AI polishing, voice editing and translation providers remain separate.

## Service provider and official agreements

"Doubao online" means the Doubao Speech ASR API offered through Volcengine, not the consumer Doubao chat app or the Volcano Ark chat-model API. Volcengine is a third-party provider relative to Talkless. Its general Terms of Service and Privacy Policy name Beijing Volcano Engine Technology Co., Ltd.

Official documents:

- [Volcengine Terms of Service](https://docs.volcengine.com/docs/6256/64903)
- [Volcengine Products and Services Agreement](https://docs.volcengine.com/docs/6256/68938)
- [Volcengine Privacy Policy](https://docs.volcengine.com/docs/6256/64902)

The applicable contract and product-specific terms are those presented when the customer activates or purchases Speech services in the Volcengine console. The Speech documentation also links [Generative Model Service Specific Terms](https://docs.volcengine.com/docs/6561/1533787); that page describes generative services and does not explicitly identify ASR, so this guide does not assert that it alone governs this integration. Do not substitute consumer Doubao or Ark terms for the Speech service agreement.

"Talkless does not save recordings" describes this app only. It is not a guarantee of zero provider retention or no training. The provider distinguishes customer data processed through its services from account personal information; consult the applicable agreements for data handling, retention and deletion.

## Setup

Select **Settings > Voice input > Speech recognition > Doubao online**. Enter the **Speech API key** from the new Doubao Speech console. This is not an Ark chat-model key. The key is stored under a dedicated Keychain account, never in UserDefaults, the repository or diagnostic logs. Former Whisper-compatible provider keys are not reused. Retired recognition choices fall back to local Qwen, so upgrading does not silently upload audio to a different provider.

The default is ASR 2.0 hourly billing, `volc.seedasr.sauc.duration`. **More options** also offers its concurrent-billing resource. The selected resource must be enabled for the key. Use **Test** after pasting the key: it sends only the configuration frame and waits up to ten seconds for the service acknowledgment, then closes the connection. It never opens the microphone or sends audio. Success verifies that the configuration was accepted, not speech accuracy or future quota. Provider billing policies still apply. Editing the key/resource or leaving the page cancels the check and clears its receipt; viewing Settings never starts a request.

## Integration choice

- Protocol: [official streaming recognition documentation](https://docs.volcengine.com/docs/6561/1354869).
- SDK reviewed: [official large-model streaming SDK](https://docs.volcengine.com/docs/doubao-voice/large-model-stream-recognition-sdk-1?lang=zh). At review time it documented Android and iOS, with an iOS CocoaPods artifact, SocketRocket dependency and App ID/Access Token authentication. It did not establish support for native macOS arm64 with the new single-key API.
- Consequently Talkless uses the platform's `URLSessionWebSocketTask` for TLS, connections and messages, and system zlib for gzip. Only Doubao binary framing and recognition-session lifecycle are implemented locally. No Python service, alternative networking library or mobile SDK is bundled.

**Speech input language** defaults to **Auto**, which uses `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async` without an `audio.language` field. Choosing a specific language uses `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream` and sends its language code in `audio.language`. This is a recognition input setting, independent of AI output and translation languages. Authentication uses `X-Api-Key`; the request also supplies the resource ID, a random request ID and `X-Api-Sequence: -1`. Redirects are rejected. There are no automatic online retries. Optional local fallback is described below.

**Spoken cleanup** independently controls Doubao's `enable_ddc` request field and defaults to **off** (`false`). It asks Doubao to remove fillers and accidental repetition during recognition; it does not enable or require the separate AI polishing service. Punctuation and inverse text normalization remain enabled.

A shared ephemeral `URLSession` retains transport resources across utterances, with URL caching, cookies and shared credential storage disabled. Each utterance creates a new WebSocket task; completed recognition streams are not reused. Closing an utterance cancels its task, not the shared session.

Audio is 16 kHz, mono, signed PCM16 little endian, sent in 200 ms chunks using gzip binary frames. The final packet carries the end-of-input flag. Full-text responses replace previews rather than being appended, avoiding duplicate words. A final response is required before insertion; a disconnect, timeout or protocol failure never promotes a preview to final text.

Capture only copies samples to a bounded 15-second mailbox. Compression, PCM packing and network waits are off the audio callback and main actor. Service acknowledgment and stalled sends have a 10-second deadline; after recording ends the final response has a 15-second deadline. These are failure deadlines, not a recording-duration limit. Cancellation closes the socket and resolves the caller immediately. Responses and decompressed payloads are size-limited; provider error bodies are not shown or logged.

Qwen receives dictionary recognition hints. This Doubao integration does not send a separate hotword list; local explicit dictionary fixes still apply to preview/final text, and optional AI polishing still uses the dictionary.

## Optional local fallback and model memory

With **Settings > Labs > Enhanced recognition** off, there are two modes, and you choose one:

- **Offline**: every recording uses the local Qwen model on your Mac. Doubao is never contacted, whatever the fallback switch says.
- **Doubao online**: every recording tries Doubao first. **Allow falling back to offline recognition** (off by default) decides whether a recording may fall back to the offline model when Doubao is unavailable.

With the switch on and a local model installed, Talkless preloads the model and keeps it in memory while Doubao is selected. A preparation error is shown rather than claiming the standby is ready.

- If Doubao cannot start, for example because no key is saved, the recording uses local Qwen from the start and the overlay says so.
- If the online session fails during or after recording (network, rejected key, quota, timeout), recording continues and the overlay explains the change. On finishing, Qwen recognizes the complete recorder-owned PCM snapshot once, in bounded windows; online partial text is never concatenated with local output. A local error is reported rather than retried.
- Cancellation never triggers fallback. The next recording still tries Doubao first.

The switch is a safety net, not a requirement: if no local model is installed yet, or a model download/deletion is in progress, Doubao recordings run without fallback instead of being blocked. Settings shows a notice until a model is available.

With fallback off, online failure stops dictation and reports the error. Selecting online with both local fallback and Labs enhanced recognition off releases resident Qwen weights and caches when idle, without deleting downloaded files. Selecting local or enabling fallback reloads the model. Changes during a recording are deferred until that recording completes; the in-flight session keeps its captured policy.

Audio already sent online cannot be recalled. Fallback does not make AI polishing offline. Polishing uses a **five-second request deadline**: timeout quietly uses the recognized text after dictionary fixes, with local formatting still applied; other polishing failures also fall back but show a brief error. No speculative or early polishing requests are added.

Labs **Enhanced recognition** is a different opt-in path: ordinary dictation runs Qwen and Doubao together even when Offline is selected, then sends available transcripts to the AI provider. It requires a local model and both service configurations, and uses AI regardless of the separate polishing switch. One recognizer can continue if the other fails. It is not the online-local-fallback switch or a proven accuracy improvement. Labs **Sentence alternatives** is independently optional. See the [Labs guide](user-guide.md#labs-enhanced-recognition-and-sentence-alternatives) for deadlines, candidate selection and privacy implications.

## Validation

Offline Swift tests use an injected scripted socket and cover headers, frame sizes, gzip/plain responses, sequence/final flags, PCM encoding, partial-to-final flow, no duplicate upload at finish, cancellation, timeout, send failure and backlog limits. Settings tests verify retired-engine migration, isolated Keychain storage and failed-save behavior.

An authorized live check used a temporary credential outside the repository and approximately eight seconds of synthetic Mandarin speech, not a microphone recording. ASR 2.0 duration billing accepted the request, returned changing previews and a final transcript preserving the time and negative instruction. First preview arrived at approximately 0.63 seconds and the final reply approximately 0.34 seconds after the final audio feed completed. These are one-run observations, not latency or accuracy guarantees. The temporary credential was removed after testing; no key is included in reports or source.
