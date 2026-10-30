# AI polishing providers

Local Qwen3-ASR 0.6B is the default speech engine; Apple on-device recognition and a cloud Whisper-compatible API are also available in Settings > Models. Optional second-stage polishing is independent of that choice and sends the final transcript, relevant writing context, dictionary and additional instructions to the selected API provider. It does not invoke Claude Code or any other CLI. This page describes the current source implementation, not a release announcement.

## Configuration

Settings > AI polish offers five provider entries:

| Provider | Protocol |
| --- | --- |
| DeepSeek | OpenAI Chat Completions |
| OpenAI | Responses by default, with Chat Completions selectable |
| Gemini | Native GenerateContent |
| Anthropic | Native Messages |
| Custom | Any of the four protocols, custom base URL and authentication |

Fresh model selections are empty. Enter an API key, click **Fetch Models**, and choose a returned model, or enter its ID manually. Each provider keeps independent endpoint, model and authentication settings. Changing endpoints or providers cancels/discards stale discovery and test responses.

Custom base URLs are used as entered, preserving proxy path prefixes and accepting either a base path or the selected full endpoint. No `/v1` or `/v1beta` is injected: `https://example.com` becomes `/responses` for Responses, while `https://example.com/v1` becomes `/v1/responses`. Official provider presets include their version prefix. HTTP/keyless access is allowed only for loopback services; remote endpoints require HTTPS and credentials. Same-origin redirects cannot silently change POST into GET or forward credentials to another host.

## Per-dictation choice

Polishing is off by default. Normal finish uses the global AI on/off setting captured when recording starts. The alternate finish key ends just that dictation with the opposite choice; it neither changes the saved default nor applies to selected-text voice editing. Configure the single-key bindings in Settings > General > Keyboard shortcuts; see [dictation and shortcuts](../README.md#dictation-and-shortcuts). A missing provider or failed polishing request retains the original transcript.

## Credentials and privacy

Polishing keys use a stable macOS Keychain service. Existing legacy plaintext polishing credentials are migrated only after Keychain storage succeeds; failures preserve the prior value and display an error. No new polishing keys are written to UserDefaults. The separate legacy cloud-ASR key remains plaintext in UserDefaults; it is not covered by this migration. Non-secret preferences and dictionary terms also use UserDefaults, while text history and managed models use Application Support, not `~/.talkless`.

**Test Connection** is explicit and sends only a fixed short test request, not the user's transcript, dictionary or instructions. The provider may charge for it. No request is sent just by choosing a provider, entering a key, or enabling the panel. Fetch Models uses the configured provider's authenticated models endpoint.

No extra thinking is requested. Thinking is explicitly disabled only for exact provider/model combinations with verified parameter support; otherwise the client omits the field and shows guidance that the model may reason by default. Unknown custom proxies are not given guessed provider-specific flags. The app does not promise that every model can disable reasoning.

## Dictionary review

Dictionary > Review can compare existing local raw/polished dictation pairs without sending history to a provider or making additional AI requests. Automatic scanning is opt-in; Scan history runs once without enabling it. Small changed spellings become candidates with source/output evidence, not automatic corrections. Accept explicitly adds a candidate to My terms, whose spellings may then be included in enabled speech-recognition and polishing requests. Dismissed spellings stay hidden until reset. Only confirmed terms are used as hints; AI changes and repeated appearances are not proof of correctness. Edits and translations are excluded, and the app does not observe changes made after pasting into other apps.

## Response handling

Only protocol-defined final text is returned to the dictation pipeline. Refusals, truncation, tool calls, incomplete statuses, empty results and reasoning-only response blocks are rejected. Markup and code fences inside a final text block are preserved rather than guessed to be reasoning. The polishing stage also checks that literal tags and code spans from the source survive; if they change, it retains the original transcript. This narrow check does not prove general semantic equivalence. The existing optional-polish failure path retains the raw transcript rather than replacing it with a partial model response. There are no hidden retries, model substitutions or protocol fallbacks.

## Validation

Native URLProtocol tests cover all four request/response formats, authentication, model discovery and pagination, endpoint validation, cancellation, timeouts, byte limits, redirects, refusals and truncation. Separate in-memory settings/credential tests cover migration, independent provider switching, failed saves and keyless local services. These tests use synthetic responses and no paid API calls; live provider behavior still depends on the user's endpoint, key and model.

```sh
bash Tests/APITests/run-tests.sh
bash Tests/ProviderSettingsTests/run-tests.sh
```

### Optional live polishing smoke tests

`Tests/PolishIntegration/run-tests.sh` compiles the production client, protocol, transport and prompts with a small in-memory settings stub. It does not load the app, ASR models, UserDefaults, Keychain or user configuration files. Without `TALKLESS_RUN_LIVE_TESTS=1`, both the script and executable skip without making requests. This suite is not part of the default build or CI.

Provide `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` through the process environment using your existing secret-management workflow; never put credentials in source files or reports. `TALKLESS_TEST_BASE_URL` explicitly overrides the environment's default base URL when a test needs a different API prefix. Despite these environment variable names, this harness uses the **Responses** protocol with bearer authentication. The target is the selected base URL, trimmed of whitespace and trailing slashes, with `/responses` appended unless it already ends in `/responses`; it does not append `/v1`. For a `/v1/responses` endpoint, supply a URL ending in `/v1` or the complete `/v1/responses` endpoint. A local preflight rejects any production-client rewrite of that exact URL before sending requests.

```sh
# Uses credentials already exported in the environment; this command incurs API usage.
TALKLESS_RUN_LIVE_TESTS=1 bash Tests/PolishIntegration/run-tests.sh
```

The default model is `mai-code-2-flash`; `TALKLESS_LIVE_MODEL` explicitly overrides it. The default `legacy` suite sends eight small synthetic requests; `TALKLESS_LIVE_SUITE=challenge` selects 20 cases, or `TALKLESS_LIVE_CASES` selects comma-separated case names (at most 20). Requests run sequentially, each with a 30-second timeout and a 1,024-token output limit. There are no application retries, discovery calls, LLM judges, or protocol/model fallbacks. The provider may charge for input and output tokens; actual pricing depends on the configured service.

Cases cover Mandarin and English cleanup/self-correction, mixed technical vocabulary with dictionary spellings, Japanese, explicit English translation, preserving an embedded question rather than answering it, numbers and negation, and custom bullet formatting. Deterministic marker checks deliberately avoid exact punctuation comparisons. Passing is only smoke-test evidence, not proof of full semantic preservation, multilingual quality, or ASR accuracy; a valid paraphrase can also fail a marker check. Review failures before changing prompts or checks, and do not repeatedly rerun paid tests to tune to these examples.

The ignored `.build/PolishIntegration/results.json` contains case names, latency, synthetic inputs, character counts, prompt/check hashes, expected checks with pass/fail results, and sanitized final outputs. It contains no configured host, credentials, raw headers, or provider error bodies. Console output includes case status, timing/counts and failed-check descriptions, not provider responses. Exit codes are `0` for pass/opt-out, `1` for failed cases, and `2` for configuration or report errors (compiler failures may use their own nonzero status). Existing reports are never overwritten: set `TALKLESS_LIVE_REPORT` to a new simple `.json` filename for another authorized run. Only interpret a report after the runner confirms writing it. See the [dated validation notes](polish-validation.md) for historical results and limitations.
