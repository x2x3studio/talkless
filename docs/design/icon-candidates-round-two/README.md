# Talkless icon studies

## Selected: Pip silhouette

The monochrome **I / Pip** silhouette was selected and shipped in **2026.1031.18018**. Its eyes and smile are negative space, without pupils. The app uses charcoal on an off-white tile; the menu bar uses a template silhouette with recording and processing badges.

Production sources are [the app icon generator](../../../scripts/generate-icon.swift) and [the menu bar artwork](../../../Sources/Talkless/MenuBarIcon.swift). Their geometry parity and small-size rendering are tested. The files in this directory preserve the exploration process; running them does not replace the production icon.

## Archived directions

| ID | Name | Direction |
| --- | --- | --- |
| D | Type Ligature | A blue T/L monogram. |
| E | First Word | Opening quotation marks on amber. |
| F | One Breath | A flowing cursive loop on grape. |
| G | Air Nib | A light writing nib on graphite. |
| H | Fold | Blue and lilac folded sculpture on porcelain. |
| I | Pip | The original apricot character on deep green, plus the selected monochrome silhouette. |
| J | Offbeat | A black eccentric ring on citron. |
| K | Puddle | An irregular pearlescent shape on violet-black. |

The four later Pip color studies were **not selected**: porcelain/cobalt, lilac/butter, midnight/coral, and ice/tangerine. They keep the character outline but retain pupils, unlike the final silhouette.

## Reproduce the previews

Requires macOS and Swift with AppKit. No packages, downloads, or network requests. Run from the repository root, using a new output directory each time:

```sh
swift docs/design/icon-candidates-round-two/generate.swift "/tmp/talkless-icon-round-two-$(uuidgen)"
swift docs/design/icon-candidates-round-two/pip-colors.swift "/tmp/talkless-pip-colors-$(uuidgen)"
```

`generate.swift` refreshes the eight SVG sources in this directory and writes PNGs to the specified temporary directory:

- `talkless-icon-round-two-contact-sheet.png`: D–G.
- `talkless-icon-play-contact-sheet.png`: H–K.
- `silhouette-selection.png`: the four H–K monochrome marks, enlarged and at menu-bar sizes.
- Individual icons at 16, 32, 256, 360, and 1024 pixels; light/dark monochrome previews and silhouette panels.

`pip-colors.swift` writes `pip-color-studies.png` and individual color variants at 16, 32, 360, and 1024 pixels. PNGs stay outside Git; only editable vectors and reproducible source are archived here.
