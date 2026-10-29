# Local model management

Talkless recommends **Qwen3-ASR 0.6B, MLX 4-bit**. The optional 1.7B entry is explicitly separate. Selecting a model is not the same as downloading it; downloads start only from a user action. The catalogue pins repository revisions, file sizes, hashes and runtime format.

## Reference decisions

SpeakMore's default local model is Qwen3-ASR 0.6B **GGUF Q8_0**, running through transcribe-cpp. Its fixed artifact catalogue, staged downloads, cancellation, resume and checksum validation informed the management design. Those GGUF files are not compatible with Talkless's native MLX runtime.

OpenLess's experimental TextStream uses the official Qwen3-ASR 0.6B original weights with Python MLX; its model-management UI separates the model being browsed from the active installed model. Its application-level macOS default is a cloud provider, not the experimental local model. Talkless independently implements the management concepts without copying OpenLess's AGPL implementation or visual assets.

## Download sources

- Hugging Face: pinned `mlx-community` MLX conversions.
- HF Mirror: matching repository/revision metadata, but requests may redirect to Hugging Face. It is not advertised as an independent regional guarantee.
- Custom mirror: HTTPS, Hugging Face-compatible repository/revision/file paths; no credentials in the URL.

ModelScope is not offered until an exact matching MLX artifact set is verified. A source change never changes the manifest or expected hashes.

## Storage and lifecycle

Models live in the user's Application Support `Talkless/Models` directory. Downloads use staging folders and `.part` files, stream data to disk, validate HTTP Range responses, and verify complete file SHA-256 values before publishing an installed directory. If the server ignores Range, only that file restarts. App restarts recover partial progress. Cancellation retains reusable files.

The active model is persisted separately from install state. No development-directory or alternate-size fallback is silently selected. Changing or deleting a managed model waits for the MLX runtime to unload and is blocked during dictation. A damaged managed install can be explicitly deleted and downloaded again. Arbitrary custom folders are not deleted by the manager.

The runtime synthesizes `tokenizer.json` on first load. It is permitted as a bounded, regular JSON-object cache while all pinned source files remain verified. Symlinks, unrelated files and unmanaged folders are rejected.

Advanced settings offer an explicit custom-model folder override. The catalogue remains the primary interface. Model weights are excluded from Git and application updates.

## Validation performed

- Native Swift tests cover range validation, interrupted and canceled downloads, restart recovery, checksum mismatch, oversized responses, atomic install, owned deletion, symlink safety, selection defaults and generated tokenizer caches.
- The actual 0.6B model was downloaded from Hugging Face, canceled after initial progress, resumed through a newly created manager, and verified across all nine files (712,778,752 bytes).
- The installed model completed a native application Mandarin transcription test. Reopening the manager after inference correctly recognizes the installation, including its generated tokenizer cache.
- The icon is original reproducible AppKit/CoreGraphics artwork in `scripts/generate-icon.swift`.

This iteration focuses on local model management. Additional cloud ASR providers, Responses/Anthropic protocol adapters, remote model discovery, thinking controls, and expanded prompt editing are deferred, not represented as completed features.
