# Local model management

This page describes the implementation accompanying **2026.1031.18018**. Open **Settings > Speech recognition** and choose **Qwen3 ASR** to see the managed model controls. The catalogue offers one model: **Qwen3 ASR · 0.6B**, MLX 4-bit, with nine pinned files totaling **712,778,752 bytes**. Weights are downloaded separately, not bundled with the app. GGUF checkpoints are not interchangeable with these MLX files.

## Download, use and recover

| Row state | Available action |
| --- | --- |
| Not downloaded | **Download** |
| Downloading / verifying | **Cancel**, retaining reusable progress |
| Paused | **Resume** or **Delete…** |
| Download failed | **Retry** or **Delete…**, with the error below the row |
| Downloaded | **Use** if not already in use; **Delete…** |
| Checking / deleting | Wait for the operation to finish |

Opening the manager checks local files; it does not start a download. Restarting the app recovers staged progress as Paused, not an automatic network transfer. Resume/Retry uses the currently selected download source. A source change does not alter the expected files or checksums.

**Use** selects an installed model, turns off the custom-folder override and chooses Qwen recognition. The saved managed-model selection, verified installation and loaded runtime are separate states. **In use** identifies the installed managed selection while Qwen is selected and the custom override is off; it is not by itself proof that the model has loaded. Its status can show **Preparing model…**, **Ready · kept in memory**, or a preparation failure. The app prewarms an available selected model while idle; a successful recognition can clear an earlier preparation failure.

Download/source/selection/deletion controls are disabled during dictation or another model operation. Switching or deleting through the manager waits for the runtime to unload. **Delete…** requires confirmation, removes owned installed and staged files, and warns if the model is selected. It does not silently choose another installed model or download a replacement.

For a failed download, check the row error and source, then **Retry**. For a damaged installed model, **Delete…** and download again: Retry does not overwrite an existing installed directory. Deletion refuses symlinks, unknown contents or a missing/mismatched ownership manifest. If the app reports an unmanaged folder, inspect and move it yourself rather than expecting the manager to erase it. The removed 1.7B catalogue entry is not automatically deleted or offered as a fallback.

## Download sources

- **Hugging Face** downloads the pinned `mlx-community/Qwen3-ASR-0.6B-4bit` revision.
- **HF Mirror** uses the same pinned file paths and may redirect to Hugging Face. It is not an independent availability or regional-access guarantee.
- **Custom mirror…** accepts a Hugging Face-compatible HTTPS base URL without credentials, a query or fragment. Paths are formed as `<base>/<repository>/resolve/<revision>/<file>`.

Talkless does not host model weights. No ModelScope source is offered. Network access is needed to obtain the files; Qwen recognition itself is local. Optional [AI polishing](ai-polish.md) is separate and sends text to the configured service.

## Storage and verification

Managed files live under `~/Library/Application Support/Talkless/Models/`. Downloads stream to a staging directory and `.part` files. HTTP Range responses are validated; if a server ignores Range, only that file restarts. Completed files are checked for exact byte size and SHA-256, then the full manifest is rechecked before a same-volume directory rename publishes the installation.

Startup inspection verifies the pinned files before marking an installation Downloaded. Later directory resolution checks safe paths and file sizes against that launch/install verification; it does not rehash every file on every dictation. Progress bytes can include an unverified partial file, so 100% transferred is not yet a verified installation.

The runtime may generate `tokenizer.json` on first load. The manager permits this extra cache only as a regular, nonempty JSON object of at most 32 MiB; it still verifies the pinned tokenizer source files. Other unrelated files and symlinks are rejected.

**Advanced > Use a custom model folder** is an explicit override for a compatible Qwen3 ASR MLX folder, not another managed download source. **Choose Folder…** selects it; **Use Downloaded Models** returns to the managed selection. Custom folders do not receive the catalogue's pinned-checksum verification and are not managed or deleted by the catalogue. There is no automatic development-folder, alternate-size or Hugging Face cache fallback.

## Regression checks

```sh
bash Tests/ModelTests/run-tests.sh
```

The suite uses small synthetic files and intercepted HTTP responses. It covers catalogue pins, safe paths, Range handling, canceled/interrupted transfers, restart recovery, checksum rejection, atomic publication, tokenizer-cache rules, owned deletion and selection defaults. It neither downloads the real model nor proves inference quality or compatibility with an arbitrary custom folder.
