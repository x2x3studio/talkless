# AI service and polishing

This page describes the implementation accompanying **2026.1031.18018**. Speech recognition and AI processing are separate: local Qwen3 ASR or Apple recognition does not need an AI service. Optional polishing sends the recognized text to your configured provider; cloud speech recognition also sends audio to its separately configured service. Talkless uses native HTTP requests, not Claude Code or another CLI.

## Configuration

**Settings > AI service** configures the provider shared by dictation polishing, selected-text translation and voice editing. It has no master AI enable toggle. **Configuration complete** means the settings can form a request locally, not that a connection has succeeded.

| Provider | Protocol | Initial model |
| --- | --- | --- |
| DeepSeek | OpenAI Chat Completions | Empty |
| OpenAI | Responses; Chat Completions selectable | Empty |
| OpenRouter | OpenAI Chat Completions | `openrouter/free` |
| Gemini | Native Generate Content | Empty |
| Anthropic | Native Messages | Empty |
| Custom | Any of the four protocols | Empty |

Enter your API key and a model ID, or click **Fetch Models** and select a returned model. Discovery does not automatically select a model; manual entry remains available after an empty list or failure. Providers retain separate endpoint, model, protocol and credential state. Only Custom exposes the base URL and authentication controls: Protocol default, Bearer token or API key header. Defaults use bearer authentication for Chat/Responses, `x-goog-api-key` for Gemini and `x-api-key` for Messages.

Custom URLs preserve proxy path prefixes and accept a base URL or matching full endpoint. No `/v1` or `/v1beta` is injected: `https://example.com` becomes `/responses` for Responses, while `https://example.com/v1` becomes `/v1/responses`. URLs must not contain credentials, a query or fragment. Remote endpoints require HTTPS and a key; loopback endpoints may use HTTP and an empty key. Cross-origin redirects are rejected; POST redirects must preserve the method and use 307/308.

OpenRouter's preset uses `https://openrouter.ai/api/v1` and your own key. `openrouter/free` is a router, not a fixed model. Talkless configures no paid fallback, but availability and limits belong to the provider. **Fetch Models** is not restricted to free models; another selection may incur charges.

## Feature settings and transmitted text

- **Settings > Dictation > AI processing** controls polishing, output language, app-aware tone and additional instructions. Polishing is off for new users. Normal finish uses the choice captured when recording starts; alternate finish reverses it for that dictation only, without changing the saved default.
- Polishing sends a JSON-framed transcript plus editing instructions. Dictionary terms are candidate spellings, not mandatory replacements. With app-aware tone enabled, the prompt also identifies the frontmost app and its writing context. Additional instructions and a chosen output language are included when set.
- **Settings > Dictation > Voice editing** enables selected-text editing, off by default. A voice-edit request includes the selection, recognized spoken instruction and dictionary terms. It does not use the alternate-finish polishing choice.
- **Settings > Translation** requires a configured AI service but is independent of the polishing toggle. A translation request includes the selected text and language instructions. Source/target settings and Auto direction are separate from dictation output language and interface language. Matching explicit source/target language IDs skips the provider; Auto detection alone is not that bypass. Changing languages in the translation panel can send a new request. See [selected-text translation](user-guide.md#selected-text-translation).

## Test Connection and its receipt

Nothing is sent merely by opening AI service settings, switching providers or entering a key. **Fetch Models** and **Test Connection** are explicit actions. Tests may incur provider charges and use the current endpoint, protocol, credentials and model, with a 30-second timeout and a 1,024-output-token limit.

The test uses exactly these fixed inputs, not your transcript, selection, dictionary, app context or additional instructions:

```text
System input: You are checking an API connection. Reply briefly.
Test input: Reply with OK.
```

**Test input** is inspectable before sending. After a result, **Test details** opens with provider, model, protocol, the fixed inputs and the actual response or safe error. The summary shows success/failure and elapsed seconds. Success means the client accepted complete final text; it does not require the literal answer `OK` and is not a polishing-quality test.

**Copy Diagnostics** replaces the clipboard with this receipt: status, provider, model, protocol, duration, inputs and the displayed response/error. It does not copy request headers, an endpoint field or raw provider error bodies. The receipt is in-memory, not a saved connection history. Changing endpoint identity, model or thinking policy clears it; leaving the page cancels pending requests and clears results. Stale completions are ignored.

Both the model label and response are screened before display or copying. Known credential/endpoint echoes, credential-shaped text, URLs and suspicious encoded escapes cause the whole value to read **Content hidden because it may contain credentials.** Screening happens before an 8,000-character display limit; long allowed values end with **Response truncated.** Typed client errors retain app-owned guidance and HTTP status; unknown errors use a generic failure message. This is conservative filtering, not a guarantee against every possible secret encoding: review a receipt before sharing it. Hiding output does not turn an otherwise successful request into a failed connection.

## Credentials, transport and response handling

Polishing keys use macOS Keychain. Legacy plaintext polishing keys are removed only after successful migration; failed saves keep a key available for the current session, preserve any prior saved key and display an error. No new polishing keys are written to UserDefaults. The separate cloud-ASR key still uses plaintext UserDefaults. Non-secret settings and dictionary terms also use UserDefaults; history and managed model files use Application Support.

Generation/discovery use ephemeral sessions with cookies, URL caching and shared credential storage disabled. Responses requests include `store: false`; this is a request parameter, not a promise about a provider's retention policy. Generation, discovery and cloud-ASR requests use `User-Agent: Talkless/<CFBundleShortVersionString>`; development executables without a valid version use `Talkless/0.1.0`.

Thinking policy is automatic, not a user-facing switch. The app requests it off only for exact endpoint/model combinations supported by the client; otherwise it omits thinking parameters. It does not guarantee that a chosen model runs without reasoning.

Only protocol-defined final text reaches processing. Refusals, incomplete/truncated results, tool calls, empty text and reasoning-only output are rejected. Literal markup and code fences in final text are preserved. Polishing additionally checks that source tags, backtick spans and fenced code remain present with their occurrence counts; it does not prove semantic equivalence or preserve every numeric value by validation. Missing configuration or a polishing failure retains the raw transcript. There are no application retries, model substitutions or protocol fallbacks. Voice editing and translation have their own error paths rather than the raw-dictation fallback.

Dictionary review compares local raw/polished history without extra API requests. Only explicitly accepted terms become dictionary hints; review candidates are not automatically applied. See the [user guide](user-guide.md).

## Validation

Offline protocol, settings and receipt checks:

```sh
bash Tests/APITests/run-tests.sh
bash Tests/ProviderSettingsTests/run-tests.sh
bash Tests/PolishIntegration/test-validation.sh
```

### Optional live polishing smoke tests

The separate `Tests/PolishIntegration/run-tests.sh` is explicit opt-in and is not part of ordinary CI. See [polishing validation](polish-validation.md) for current commands, report fields, limits and the distinction between mocked protocol checks and paid live requests.
