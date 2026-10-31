# Polishing validation

This page describes the test harness accompanying **2026.1031.18018**, audited on 2026-10-31. Offline tests below were run for this documentation audit; no live provider requests were made. Historical proxy scores and latency measurements are not current-release guarantees.

## Offline checks

Run from the repository root on macOS with Swift tooling installed:

```sh
bash Tests/APITests/run-tests.sh
bash Tests/ProviderSettingsTests/run-tests.sh
bash Tests/PolishIntegration/test-validation.sh
env -u TALKLESS_RUN_LIVE_TESTS bash Tests/PolishIntegration/run-tests.sh
```

Observed results for the current source:

- API tests print **24 API tests passed** twice: once as a standalone executable and once in a temporary `.app`, checking the bundle-version User-Agent as well as protocol/transport behavior. All HTTP is intercepted by URLProtocol.
- Provider settings tests print **Provider settings tests passed (2676 assertions; in-memory defaults and credentials only).** This includes receipt sanitization/fixed request serialization, provider persistence, credentials and shortcut/HUD checks; it is not 2,676 network tests.
- Literal validation prints **PASS literal markup/code preservation, repetition counts and ordinary cleanup**.
- The opt-out command prints **SKIP: live polishing tests require TALKLESS_RUN_LIVE_TESTS=1.** and exits `0` without compiling or sending requests.

Compiler warnings may precede these results. The macOS 27 SDK currently warns about deprecated audio APIs; these runs completed successfully.

API fixtures cover Chat Completions, Responses, native Messages and Generate Content; authentication and URL handling; explicit model discovery/pagination; cancellations, timeouts and byte limits; redirect policy; refusals, incomplete results, tools and reasoning-only output. Receipt tests verify actual response display, the fixed inputs, safe error summaries, credential/URL/encoded-echo withholding, bounded text and identical displayed/copied output.

The literal guard checks that source tags, backtick spans and code fences survive with their occurrence counts. It does not prove preservation of negation, numbers, actors, language or overall meaning. Mocked protocol success is not evidence that a live endpoint accepts the request or produces good prose.

## Optional live smoke tests

`Tests/PolishIntegration/run-tests.sh` links the production client, transport, protocol and prompts with an in-memory settings stub. It does not load app settings, Keychain, ASR models or user configuration files. It tests prompt/client output directly: it does **not** invoke the dictation pipeline's `PolishValidation` guard or raw-transcript fallback. No app-aware context is supplied.

Both script and executable require `TALKLESS_RUN_LIVE_TESTS=1`. The suite is excluded from ordinary CI. Each selected case sends one sequential request with a 30-second timeout and a 1,024-output-token limit. There are no discovery requests, application retries, LLM judges or protocol/model fallbacks. Provider charges and retention policies still apply.

Supply credentials through your existing secret-management workflow, never source files or reports:

| Environment variable | Meaning |
| --- | --- |
| `ANTHROPIC_BASE_URL` | Default endpoint base |
| `TALKLESS_TEST_BASE_URL` | Explicit override for that base |
| `ANTHROPIC_AUTH_TOKEN` | Bearer credential |
| `TALKLESS_LIVE_MODEL` | Model ID; default `mai-code-2-flash` |
| `TALKLESS_LIVE_SUITE` | `legacy` (default, 8 cases) or `challenge` (20 cases) |
| `TALKLESS_LIVE_CASES` | Comma-separated unique known case names; overrides suite selection, at most 20 |
| `TALKLESS_LIVE_REPORT` | New simple `.json` filename under `.build/PolishIntegration/`; default `results.json` |

Despite the credential variable names, this harness uses **Responses with bearer authentication**, not native Messages. It trims the base and trailing slashes, then appends `/responses` unless already present. It does not insert `/v1`: supply a base ending in `/v1` or a full `/v1/responses` URL when needed. A local preflight rejects production URL normalization that changes that exact endpoint before sending requests.

The following command is a live, potentially chargeable action, not part of the offline checks:

```sh
# Requires the endpoint and credential to be exported already.
TALKLESS_RUN_LIVE_TESTS=1 bash Tests/PolishIntegration/run-tests.sh
```

For a challenge run, additionally set `TALKLESS_LIVE_SUITE=challenge` and a new `TALKLESS_LIVE_REPORT` filename. Filenames may contain letters, digits, `_` and `-`, followed by `.json`. Existing reports are rejected rather than overwritten.

Legacy cases cover Chinese/English/Japanese cleanup, self-correction, dictionary spellings, explicit translation, embedded questions, numbers/negation and bullet formatting. Challenge adds dictionary ambiguity, multilingual passages, literal code/URLs, instruction-like quoted content and spoken-versus-mentioned formatting. The 20-case challenge consists of 18 challenge fixtures plus the first two legacy cases.

## Output and limits

The console starts with `Running <count> synthetic polishing cases; 30-second timeout, 1024 output tokens, no retries.` Each case prints PASS/FAIL, name, latency and input/output character counts; failed check descriptions follow. It does not print provider output. On a written report, it ends with:

```text
Result: <passed>/<count> cases passed. Marker checks are not a full semantic evaluation.
Sanitized report saved (endpoint and credentials withheld).
```

The ignored JSON report contains an array of case results: synthetic input/output, latency, character counts, system/input-prompt hashes, a hash of check descriptions, and expected check descriptions with pass/fail flags. `frozenChecksSHA256` fingerprints descriptions, not the evaluator implementation. Reports are local and are not uploaded automatically.

The report sanitizer replaces the configured key, endpoint and host and other HTTP(S) URLs, while retaining the known synthetic fixture URL. It is separate from the settings receipt's more conservative filter and is not a universal detector for encoded secrets. Raw errors, headers and provider error bodies are not serialized. Inspect outputs before sharing; a run can fail to write its report after requests have already occurred.

Exit codes are `0` for passing cases or opt-out, `1` for failed cases, and `2` for configuration/report errors; compiler failures may return their own nonzero status. Interpret a report only after the runner confirms writing it.

Checks are deterministic markers, not an exact-text comparison or semantic judge. Valid paraphrases can fail; lost meaning can pass. Review synthetic outputs and failures instead of treating the score as multilingual quality, ASR accuracy or a reason to keep rerunning paid cases until they pass.
