# Historical measurement method — 2026-10-29

These definitions describe the standalone streaming CLI experiment, not the later native product adapter. See the [native integration record](native-integration-results/README.md) and [project README](../README.md) for subsequent results and current status.

Environment observed on 2026-10-29: Mac mini M4, 10 physical/logical CPU cores, 16 GiB unified memory, macOS 27.0.1 (26A434), Swift 6.4, full Xcode selected. Low power mode is off. Other user applications remain running; this is not an otherwise idle benchmark machine.

## Model and timing

Use one Qwen3-ASR-1.7B 4-bit model, one streaming session per utterance. UI preview and final text must be outputs of that session. No Apple recognition, second ASR model, or polishing model is involved. The upstream streaming implementation may recompute its current window and finalize completed windows using the same model; it is not claimed to be a strictly single-pass acoustic decoder.

- **Download**: measured separately and excluded from recognition latency.
- **Load**: `Qwen3ASRModel.fromModelDirectory`, including the upstream `eval(model)`. This excludes first inference initialization.
- **First text**: first nonempty `displayUpdate` measured from the first supplied audio frame. Preserve the text so an incorrect first fragment is not mistaken for a useful result.
- **Pacing**: 50 ms PCM frames, a separate capture thread, serial feed queue. The initial relative-`Thread.sleep` baseline (`mandarin.jsonl`) accumulated sleep overshoot and stretched 14.098 seconds to about 15.98 seconds; it is retained as a rejected timing baseline, not the final real-time result. Corrected `*-realtime.jsonl` runs use absolute `mach_wait_until` deadlines and a latency-critical activity. Each frame becomes available only after its samples' nominal capture time; first frame waits 50 ms. If capture falls behind a whole frame the harness fails rather than bursts to catch up. `feedWallSeconds` starts at first-frame availability, so total capture time adds approximately 50 ms. Compare that with source duration. GPU feed queue backlog is measured separately.
- **Stop to final**: `input_stopped` after the last frame's nominal duration until `.ended`; includes outstanding queued input and decoder finalization, not just the final API call.
- **Updates**: count nonempty updates occurring before input stops; first text after stop is not a live preview.
- **Memory**: Darwin peak RSS and MLX peak allocation reported separately. Do not sum them as independent memory pools. Repeated sessions in one process have cumulative process peaks.
- **Warm session**: repeat Mandarin with the same loaded model and a fresh streaming session; distinguish from starting a fresh process with only OS disk caches warmed.

## Fixture limitations

Tingting TTS is an intentionally reproducible local input, not a human benchmark. English technical words may be mispronounced by the synthesizer. Pure digital silence checks hallucination only; it does not stand in for a noisy room, low-amplitude whisper, or microphone route change. No CER comparison with Apple or other models is appropriate from this test alone.

## Desktop verification sequence

The initial AppKit preview run created a registered on-screen window, but the desktop was locked and the UI tool could not acquire it. That attempt did not verify screenshots or real-time interaction, and no unlocking was attempted by the automation. After the user unlocked the desktop, the [preview runner](preview-runner/README.md) was exercised successfully: live updates and final-only insertion into its local test view were observed. The capture did not include the separate floating HUD. Later [native product integration tests](native-integration-results/README.md) also exercised a product file-test window.

None of those file-driven tests establish cross-application paste or microphone/hotkey behavior. The initial locked-desktop limitation is historical, not a claim that all subsequent GUI verification remained blocked.
