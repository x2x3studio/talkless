# AI polishing providers

Speech recognition remains local Qwen3-ASR 0.6B. Optional second-stage polishing sends the final transcript, relevant writing context, dictionary and additional instructions to the selected API provider. It does not invoke Claude Code or any other CLI.

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

Custom base URLs preserve proxy path prefixes and accept either a base path or the selected full endpoint. HTTP/keyless access is allowed only for loopback services; remote endpoints require HTTPS and credentials. Same-origin redirects cannot silently change POST into GET or forward credentials to another host.

## Credentials and privacy

Polishing keys use a stable macOS Keychain service. Existing legacy plaintext polishing credentials are migrated only after Keychain storage succeeds; failures preserve the prior value and display an error. No new polishing keys are written to UserDefaults. This does not migrate the separate legacy cloud-ASR key setting.

**Test Connection** is explicit and sends only a fixed short test request, not the user's transcript, dictionary or instructions. The provider may charge for it. No request is sent just by choosing a provider, entering a key, or enabling the panel. Fetch Models uses the configured provider's authenticated models endpoint.

No extra thinking is requested. Thinking is explicitly disabled only for exact provider/model combinations with verified parameter support; otherwise the client omits the field and shows guidance that the model may reason by default. Unknown custom proxies are not given guessed provider-specific flags. The app does not promise that every model can disable reasoning.

## Response handling

Only final text is returned to the dictation pipeline. Refusals, truncation, tool calls, incomplete statuses, empty results and reasoning-only responses are rejected. The existing optional-polish failure path retains the raw transcript rather than replacing it with a partial model response. There are no hidden retries, model substitutions or protocol fallbacks.

## Validation

Native URLProtocol tests cover all four request/response formats, authentication, model discovery and pagination, endpoint validation, cancellation, timeouts, byte limits, redirects, refusals and truncation. Separate in-memory settings/credential tests cover migration, independent provider switching, failed saves and keyless local services. These tests use synthetic responses and no paid API calls; live provider behavior still depends on the user's endpoint, key and model.

```sh
bash Tests/APITests/run-tests.sh
bash Tests/ProviderSettingsTests/run-tests.sh
```
