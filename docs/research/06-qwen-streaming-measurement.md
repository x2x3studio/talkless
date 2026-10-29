# Single-Qwen Live Preview Measurements

Date: 2026-10-29.

> This is a record of a specific experiment, not a production-readiness claim or a cross-model accuracy benchmark. The selected direction is **one Qwen ASR model for preview and final transcription**, superseding the two-model recommendations in the earlier research and v1 proposal. Statements about implementation and build status below describe this experiment at the time it ran, not necessarily the current working tree.

## Conclusions

**Model-side live preview ran successfully.** The same Qwen3-ASR-1.7B 4-bit model received audio at wall-clock speed, emitted text multiple times before input ended, and returned a final transcript when that same session stopped. No Apple preview model, second ASR model, or cleanup model was used.

**The upstream defaults were not ready to ship unchanged.** Tests exposed repetition at window boundaries, temporary hallucinations on very short input, and a final hallucination on digital silence. A working realtime path does not establish adequate accuracy or stability.

**GUI follow-up after the user unlocked the machine:** recording was started by an actual click, and real model output drove the test app. Screenshots and Accessibility state confirmed that the preview-update count increased while the target field stayed empty and retained focus; stopping inserted the final transcript once into that test field. A 42.295-second sample produced 382 preview updates in one run. The screenshot tool captured only the main window, not the floating HUD itself. The user saw the HUD and asked to remove instructional text; the hands-free instruction was removed, and another Swift 6 build/run succeeded. **Cross-application paste, microphone capture, and global shortcuts were not verified by this experiment.** Follow-up logs are in `experiments/preview-runner/results/`. GUI finalization took about 0.94–1.07 seconds, slower than the standalone CLI results below; sub-second completion is not guaranteed.

## Environment and versions

- Mac mini, Apple M4, 10-core CPU, 16 GiB unified memory.
- macOS 27.0.1 (26A434), **Swift 6.4** from the installed Xcode. The inference CLI and preview test used Swift 6 language mode, without a compiler downgrade.
- Low Power Mode disabled; other user applications were left running.
- `mlx-audio-swift` commit `fe2c182f4da8115fe2b6b99c9a4d2048fbf9b1e6`.
- Model: `mlx-community/Qwen3-ASR-1.7B-4bit`, revision `78a389c776a5483b2d0d4ea5494e11012e0d6159`.
- Weights: 1,603,081,617 bytes. Required model files: 1,607,551,611 bytes in total. SHA256 verified; only one copy of the weights downloaded.
- Initial model download took about 50.97 seconds on this machine, excluded from recognition latency. The missing Apple Metal Toolchain was also installed, with a download of about 838.9 MB.
- The default Swift 6.4 build backend failed at Metal compilation. `swift build --build-system native -c release`, together with shader generation using Xcode's Metal tools, produced a working run. This did not change the Swift version. Upstream recognition source was not modified.

## Method

Test audio was generated locally with the macOS Tingting voice as 16 kHz mono PCM. No user speech was captured or uploaded.

The corrected measurement supplied one frame every 50 ms against absolute deadlines. The first frame became available only after 50 ms. Logs recorded capture timing, the feed queue, every partial result, stop, and final output. Capture delays exceeding a full frame caused an error rather than being hidden by an immediate burst of catch-up frames. In all five corrected sessions, frames were fed in order without drops, and the foreground timing validator passed.

An initial baseline used relative sleeps, whose accumulated error stretched 14.098 seconds of audio to about 15.98 seconds. **That baseline is excluded from final realtime-latency conclusions.** Its log remains in `mandarin.jsonl`; the final measurements use only `*-realtime.jsonl`.

“First meaningful text” means the first match for the sample's opening Mandarin words, represented here as `\u6211\u4eec` (“we”) or `\u8fd9\u4e2a` (“this”). The earliest nonempty output was often an incorrect filler, `\u55ef`, so it cannot justify advertising 100 ms time to first text. First-text latency below starts when the first frame is available; add about 50 ms when measuring from simulated recording start. Model-load time is reported separately.

## Results

| Test | Source duration | First meaningful text | Input stop to final | Nonempty preview events before stop | Outcome |
|---|---:|---:|---:|---:|---|
| Mandarin, new process with corrected timing | 14.098 s | 1.190 s | 0.560 s | 116 | Streaming worked; window-boundary repetition |
| Mandarin, second session in the same process | 14.098 s | 1.103 s | 0.533 s | 117 | Streaming worked; repetition persisted |
| Mandarin with technical terms | 17.994 s | 1.184 s | 0.322 s | 156 | Streaming worked; terminology errors and repetition |
| Truncated short sentence | 3.000 s | 1.199 s | 0.327 s | 16 | Preview and finalization worked below a full window |
| Digital silence | 3.000 s | Not applicable | 0.192 s | 7 hallucinated events | **Failed: final output was `\u662f\u3002` (“yes/is.”)** |

These are individual or small-sample session measurements, not p50/p95 figures or promises for other machines. Preview events may arrive in token bursts during one decoding pass; 116 events does not mean a uniform eight visual updates per second.

- Model loading in corrected new-process runs took about **0.82–1.38 seconds**; the first baseline load took 2.72 seconds.
- The corrected runs benefited from system caches populated by earlier tests; they were not fully cache-cleared cold starts. The initial baseline's first meaningful result arrived after about 3.59 seconds, but its distorted capture timing makes this only a hint of first-use overhead.
- Peak MLX allocation: about **2.43–2.44 GB**.
- `/usr/bin/time -l` peak process memory footprint: about **2.87–3.04 GB** in decimal units; the long Mandarin and mixed-language samples were about 3.04 GB.
- Peak RSS: about 1.33–1.73 GB. RSS is not a substitute for total unified-memory use, and RSS, MLX allocation, and footprint must not be added together.
- With corrected timing, maximum feed queue depth was 3–9 frames and the longest individual feed call was about 0.14–0.41 seconds. Product audio callbacks therefore should not execute inference synchronously.

## Output observations and problems

The following English descriptions explain Mandarin test content; they are not replacement reference transcripts for scoring. Exact language-dependent fragments are represented with Unicode escapes, and the full original timelines remain in the experiment artifacts.

### Mandarin sample

The reference asked for a microphone-recording preview window: display text while speaking, then automatically paste into the original field after speech ends, without building an input method.

The final transcript preserved most of that meaning but repeated part of the phrase for “inside the window” across a boundary. The exact problematic fragment was `\u7a97\u53e3\u91cc\u3002 \u53e3\u91cc\u9762`. It appeared in both corrected Mandarin sessions. This is consistent with a window-boundary stitching problem, but the algorithmic root cause was not established. **The final transcript was not fully correct.**

Selected preview events from the second session, measured from first-frame availability:

- 0.101 s: `\u55ef`, an incorrect temporary filler.
- 1.103 s: `\u6211\u4eec` (“we”), matching the beginning.
- 4.362 s: text corresponding to “we first make a microphone recording,” with an extra space.
- 8.226 s: text through the preview-window description, already showing the beginning of the duplicated window-boundary fragment.
- 13.611 s: text through the instruction to paste back into the original field, still containing that repetition.

These were model outputs generated before all audio had been supplied, not a replay of a known answer after processing.

### Technical terms and self-correction

The reference contained `macOS`, `SwiftUI`, `Qwen ASR`, `API`, and a correction from a Wednesday launch to a Thursday launch.

The final output rendered `macOS` as `Mac OS`, `SwiftUI` as `Swift UI`, `Qwen ASR` as `CoreNLP. a s r`, and `API` as `a p i`. It also repeated the correction verb across a boundary: `\u6539\u3002 \u6539\u6210`, approximately “change. change to.” The sample ended with a request not to answer the dictated content.

Observed issues included `Qwen` → `CoreNLP`, split terminology, and repeated text. Tingting's pronunciation of English is not representative of human speech, so this cannot establish human Mandarin-English CER. It does show that this sample's output was not ready for direct delivery without further work.

### Silence

Three seconds of all-zero PCM produced the temporary filler `\u55ef` and a final **`\u662f\u3002`**. No VAD or silence gate was applied in this run. This demonstrates a no-speech hallucination in the tested default path. A product needs speech-activity gating and output validation; simply deleting every occurrence of these words would incorrectly remove legitimate speech.

## Implications for the product

1. **The single-model, separate-preview-window direction is feasible.** The native Swift path compiled and ran inference; preview does not inherently require Apple or a second recognition model.
2. Meaningful preview appeared after about 1.1–1.2 seconds and finalization took about 0.3–0.6 seconds in the speech CLI cases. This suggests useful latency potential, **excluding cleanup and cross-application paste**.
3. Short-input hallucinations, silence gating, and window stitching need work. Not every `displayUpdate` is reliable text. Provisional output can be visually distinguished, but correctness still needs an engine-level solution.
4. These tests did not establish human-speech accuracy, quiet-speech quality, suitability for 8 GB machines, or cross-application focus/paste reliability. The GUI follow-up established only the limited test-field behavior described above.

## Artifacts and reproduction

Paths below are repository-relative.

- Method: `experiments/measurement-notes.md`.
- Model CLI and build/run instructions: `experiments/qwen-streaming/`.
- Full timelines: `experiments/qwen-streaming/results/*-realtime.jsonl`.
- Diagnostics including system peak memory: adjacent `.stderr` files.
- Independent timing validation: `python3 -I experiments/validate_timeline.py <jsonl>`.
- Six positive/negative validator cases: `python3 -I experiments/test_validate_timeline.py`.
- Test app reusing the product HUD: `experiments/preview-runner/`.

At the time of the initial CLI experiment, product source was unchanged. The GUI follow-up changed only `Sources/Talkless/Overlay.swift` in response to user feedback, removing recording-HUD instructions; the root `Package.swift` was unchanged by that experiment. A pre-existing main-actor isolation error in `Prompts.swift` affected the root product build at that time; that experiment did not expand into a product refactor. These are historical scope notes, not a statement that the current build still has that error.
