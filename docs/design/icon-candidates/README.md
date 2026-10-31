# Talkless icon candidates

Archived first-round studies, superseded by the [Pip silhouette](../icon-candidates-round-two/README.md) shipped in 2026.1031.18018. Production artwork lives in [scripts/generate-icon.swift](../../../scripts/generate-icon.swift) and [MenuBarIcon.swift](../../../Sources/Talkless/MenuBarIcon.swift). These three alternatives were not adopted; their generator does not change the production assets.

| Candidate | Concept | Trade-off |
| --- | --- | --- |
| **A — One Key** | A substantial ivory keycap carries a cut-out voice rhythm: one voice key replaces the work of a keyboard. Slate blue `#516781`. | Most tactile and closely tied to less typing; the key silhouette matters more than a text cursor. |
| **B — Spoken Line** | A speech bubble already contains a written line and an insertion point. Deep mineral green `#326C68`. | Most conversational and distinctive as a silhouette; a bubble alone can suggest messaging, so the text cursor is essential. |
| **C — Voice Cursor** | Three voice bars lead into an I-beam cursor, making the voice-to-text transition the entire mark. Burnished copper `#A8664D`. | Most immediately related to dictation and closest to the earlier waveform identity; less object-like than A or B. |

## Visual system

- Shared continuous-corner macOS tile, generous transparent margins, restrained tonal lighting, and an ivory `#FFF9ED` mark. No stock symbols, fonts-as-icons, or external images.
- Contact sheet uses native SF/system typography, with SF Mono utility labels; cool paper `#F2F4F7`, ink `#202736`, and dark preview surface `#172029`.
- Each direction has its own meaningful silhouette, not merely a different color. The monochrome studies use the same geometry with optical adjustments at small sizes, without relying on color or shadows.
- The 1440 × 1112 contact sheet shows each app icon at **256 px**, then **32/16 px** color and monochrome previews on both light and dark. Preview sizes are actual pixels; view the sheet at 100% to judge them.

## Render on macOS

Requires the system Swift toolchain and AppKit only. No packages, network requests, or uploads.

```sh
swift docs/design/icon-candidates/generate.swift /tmp/talkless-icon-candidates
open /tmp/talkless-icon-candidates/talkless-icon-contact-sheet.png
```

The generator updates the three editable SVGs next to itself and writes all PNGs to the supplied **absolute** output directory:

- `talkless-icon-contact-sheet.png`
- `{a-one-key,b-spoken-line,c-voice-cursor}-{1024,256,32,16}.png`
- `{a-one-key,b-spoken-line,c-voice-cursor}-mono-{light,dark}-{32,16}.png`

SVGs share their geometry and palette with the native renderer; native PNGs are the review reference for shadows, antialiasing, and small-size optical correction. PNGs stay outside tracked source because repository hygiene does not allow additional binary artwork. An ignored `dist/icon-candidates` output directory is also supported.

The contact sheet and all three 1024 px exports were rendered and visually inspected. An initial keycap detail that resembled a face was removed, and gradient edge artifacts were corrected. Choosing a candidate does not automatically replace the shipped app or menu-bar icon; production adoption is a separate step.
