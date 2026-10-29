# Talkless streaming preview probe

A historical standalone AppKit test app that compiles the product `Overlay.swift` and `TextIO.swift`. It launches the experimental Qwen CLI and forwards live JSONL `displayUpdate` events into the product HUD; after `ended` it inserts the final transcript into its own disposable text view.

This is not the current product integration. It does not record a microphone or paste into other applications. Inserting into the local test view is deliberately not claimed as a cross-application paste test. The initial product build had actor-isolation errors in `Prompts.swift`, so this probe avoided unrelated components. Those early errors are not a claim about the current product; later native build and integration results are recorded [separately](../native-integration-results/README.md).

## Reproduce

From the project root, first prepare the [fixtures](../fixtures/README.md) and [experimental CLI and model](../qwen-streaming/README.md), then run:

```sh
zsh experiments/preview-runner/build.sh
open experiments/preview-runner/TalklessPreviewProbe.app --args \
  "$PWD/experiments/qwen-streaming/.build/release/qwen-streaming" \
  --audio "$PWD/experiments/fixtures/mandarin.wav" \
  --model-dir "$PWD/experiments/qwen-streaming/model"
```

Click "Start Live Preview Test". During streaming the destination text view should remain empty and retain focus; the floating HUD should change. Each run writes the child process JSONL to a uniquely named `talkless-preview-probe-*.jsonl` in the system temporary directory. Do not run concurrently with CLI latency measurements.

## Historical observations — 2026-10-29

The initial locked-desktop attempt could not verify UI behavior. After the user unlocked the desktop, real UI interaction succeeded. The start button launched the actual model process. Accessibility state and screenshots showed live update counts increasing while the destination stayed empty and retained focus, followed by final-only insertion into the test text view. A 42.295-second fixture (three repetitions of the Mandarin recording) completed with 382 display updates after simplifying the recording HUD.

Raw logs were retained locally, not included as repository source. The capture tool cropped to the normal host window and did not capture the separate floating HUD; this is not evidence of a full HUD visual screenshot. The user independently observed the recording instruction text and requested its removal; the HUD was subsequently rebuilt without it in Swift 6 language mode. Microphone input and cross-application paste were not tested by this probe.
