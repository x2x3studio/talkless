# Doubao online speech recognition

Talkless offers two recognition paths: local Qwen3 ASR and online Doubao. AI polishing, voice editing and translation providers remain separate.

## Setup

Select **Settings > Speech recognition > Online · Doubao**. Enter the **Speech API key** from the new Doubao Speech console. This is not an Ark chat-model key. The key is stored under a dedicated Keychain account, never in UserDefaults, the repository or diagnostic logs. Former Whisper-compatible provider keys are not reused. Retired recognition choices fall back to local Qwen, so upgrading does not silently upload audio to a different provider.

The default is ASR 2.0 hourly billing, `volc.seedasr.sauc.duration`. Advanced settings also offer its concurrent-billing resource. The selected resource must be enabled for the key. Use **Verify connection** after pasting the key: it sends only the configuration frame and waits up to ten seconds for the service acknowledgment, then closes the connection. It never opens the microphone or sends audio. Success verifies that the configuration was accepted, not speech accuracy or future quota. Provider billing policies still apply. Editing the key/resource or leaving the page cancels the check and clears its receipt; viewing Settings never starts a request.

## Integration choice

- Protocol: [official streaming recognition documentation](https://docs.volcengine.com/docs/6561/1354869).
- SDK reviewed: [official large-model streaming SDK](https://docs.volcengine.com/docs/doubao-voice/large-model-stream-recognition-sdk-1?lang=zh). At review time it documented Android and iOS, with an iOS CocoaPods artifact, SocketRocket dependency and App ID/Access Token authentication. It did not establish support for native macOS arm64 with the new single-key API.
- Consequently Talkless uses the platform's `URLSessionWebSocketTask` for TLS, connections and messages, and system zlib for gzip. Only Doubao binary framing and recognition-session lifecycle are implemented locally. No Python service, alternative networking library or mobile SDK is bundled.

The fixed endpoint is `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`. Authentication uses `X-Api-Key`; the request also supplies the resource ID, a random request ID and `X-Api-Sequence: -1`. Redirects are rejected. There are no automatic retries or provider fallback.

Audio is 16 kHz, mono, signed PCM16 little endian, sent in 200 ms chunks using gzip binary frames. The final packet carries the end-of-input flag. Full-text responses replace previews rather than being appended, avoiding duplicate words. A final response is required before insertion; a disconnect, timeout or protocol failure never promotes a preview to final text.

Capture only copies samples to a bounded 15-second mailbox. Compression, PCM packing and network waits are off the audio callback and main actor. Startup and stalled sends have bounded waits; finishing has a 30-second deadline. Cancellation closes the socket and resolves the caller immediately. Responses and decompressed payloads are size-limited; provider error bodies are not shown or logged.

Qwen receives dictionary recognition hints. This Doubao integration does not send a separate hotword list; local explicit dictionary fixes still apply to preview/final text, and optional AI polishing still uses the dictionary.

## Validation

Offline Swift tests use an injected scripted socket and cover headers, frame sizes, gzip/plain responses, sequence/final flags, PCM encoding, partial-to-final flow, no duplicate upload at finish, cancellation, timeout, send failure and backlog limits. Settings tests verify retired-engine migration, isolated Keychain storage and failed-save behavior.

An authorized live check used a temporary credential outside the repository and approximately eight seconds of synthetic Mandarin speech, not a microphone recording. ASR 2.0 duration billing accepted the request, returned changing previews and a final transcript preserving the time and negative instruction. First preview arrived at approximately 0.63 seconds and the final reply approximately 0.34 seconds after the final audio feed completed. These are one-run observations, not latency or accuracy guarantees. The temporary credential was removed after testing; no key is included in reports or source.
