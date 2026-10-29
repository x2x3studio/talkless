#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h:h}"
APP="$ROOT/experiments/preview-runner/TalklessPreviewProbe.app"
mkdir -p "$APP/Contents/MacOS"
# The app bundle is generated locally, including its launch metadata.
printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict>' \
  '<key>CFBundleIdentifier</key><string>com.x2x3studio.talkless.previewprobe</string>' \
  '<key>CFBundleName</key><string>TalklessPreviewProbe</string>' \
  '<key>CFBundleExecutable</key><string>TalklessPreviewProbe</string>' \
  '<key>CFBundlePackageType</key><string>APPL</string>' \
  '<key>CFBundleVersion</key><string>1</string>' \
  '<key>LSMinimumSystemVersion</key><string>26.0</string>' \
  '</dict></plist>' > "$APP/Contents/Info.plist"
swiftc -O -swift-version 6 -parse-as-library \
  "$ROOT/experiments/preview-runner/PreviewProbe.swift" \
  "$ROOT/Sources/Talkless/Overlay.swift" \
  "$ROOT/Sources/Talkless/TextIO.swift" \
  -o "$APP/Contents/MacOS/TalklessPreviewProbe"
