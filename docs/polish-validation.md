# Polishing validation — 2026-10-30

The owner's authorized Responses proxy and `mai-code-2-flash` were exercised using synthetic inputs and the production request/parser code. No credential or proxy address is stored in reports or source. These are small functional smoke tests, not an unbiased model benchmark or a guarantee of semantic fidelity.

## Reference review

OpenLess and SpeakMore both separate dictation cleanup from answering questions. Useful patterns include explicit source-data boundaries, context-aware dictionary hints, language/translation separation and protected numeric/code literals. Their defaults are not copied wholesale: aggressive list formatting, assumptions about Chinese output, and examples strengthening uncertainty are unsuitable for a general multilingual editor.

- OpenLess: `Open-Less/openless`, commit `3a0bb311ad05061e3b52ec5bf5abb06ffdd1f05e`, `style_packs.rs`, `prompt_compose.rs`, `prompts.rs`, `llm_protocol.rs` (AGPL source read for behavior only).
- SpeakMore: `zephyr4123/speakmore`, commit `5c0ac69c2c49826af06c201ca257061feac1d9d4`, `dictate/polish-prompt.mjs`, `translate/polish-prompt.mjs`, `chat/openai-chat.mjs` (MIT).

## Findings and changes

1. The original 8 basic cases passed. A frozen 20-case challenge baseline scored 16/20 by deterministic markers. Human review identified one harmless punctuation false negative, plus three real issues: reversed translation negation, deleted literal XML, and lost framing tags.
2. The client had been deleting `<analysis>`/`<think>` fragments and code fences from final text. Protocol-specific response parsing already excludes actual reasoning blocks, so final-text cleanup now only trims outer whitespace.
3. Source framing now uses a JSON string rather than colliding XML delimiters. The model is explicitly told to decode JSON escapes. Closing slash characters are not unnecessarily escaped.
4. The prompt separates ordinary cleanup from explicit translation and protects negation, conditions, uncertainty, actors, names, numeric values and code. Dictionary entries are candidate data rather than mandatory replacements.
5. An early prompt revision regressed explicit translation and fillers. It was not treated as success. Subsequent revisions restored translation direction, negation and exact personal-name spelling.
6. The final full challenge pass scored **19/20 frozen marker checks**, versus baseline 16/20. Median latency was **1.466 seconds**, mean **1.604 seconds**. The remaining failure rewrote an embedded instruction/markup payload instead of preserving it. A separate deterministic literal-preservation guard now rejects that result and falls back to the source.
7. Human review also saw occasional omission of an explicit Cantonese subject despite passing markers. The literal guard does not solve that; further representative testing remains necessary.

There were 64 calls across the four challenge/refinement rounds, plus the earlier 8-case basic run. Reports are local, ignored `.build/PolishIntegration/*.json` files with synthetic inputs/outputs, latencies and frozen check/prompt hashes. They are not uploaded automatically. Checks were not relaxed to manufacture a passing score; focused reruns are not claimed as full-suite results.

## Running tests

Offline routing/parser and literal-preservation checks:

```sh
bash Tests/APITests/run-tests.sh
bash Tests/PolishIntegration/test-validation.sh
```

Live tests remain explicit opt-in and are excluded from ordinary CI. See `Tests/PolishIntegration/run-tests.sh` and the live-testing section of `docs/ai-polish.md`. Default runs use the original eight cases; challenge selection and report filenames are configurable. Existing result files are never overwritten.
