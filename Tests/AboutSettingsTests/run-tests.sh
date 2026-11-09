#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/talkless-about-settings-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/TalklessAboutPreview.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -R "$ROOT/Sources/Talkless/Resources" "$APP/Contents/Resources/Talkless_Talkless.bundle"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf '%s' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>about-settings-tests</string><key>CFBundleIdentifier</key><string>local.talkless.about-preview</string><key>CFBundleName</key><string>Talkless About Preview</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundleShortVersionString</key><string>0.0.0-test</string><key>CFBundleVersion</key><string>42</string><key>LSUIElement</key><true/></dict></plist>' > "$APP/Contents/Info.plist"
# Compile the exact production section metadata and About view without loading any
# app services. Check the hierarchy/routing in the enclosing production source too.
python3 -I - "$ROOT" "$WORK/AboutSettings.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / 'Sources/Talkless/SettingsView.swift').read_text()
about = source[source.index('// MARK: - About'):source.index('// MARK: - Speech Recognition')]
system = source[source.index('private struct SystemSettingsTab:'):source.index('struct DiagnosticsSection:')]
assert 'UpdateSettingsView(' not in system and 'updateController' not in system
for retained in ['Section(L10n.tr("Language"))', 'Section(L10n.tr("Permissions"))',
                 'Section(L10n.tr("Setup guide"))', 'LaunchAtLoginSettingsView()', 'DiagnosticsSection()']:
    assert retained in system, retained
assert 'SystemSettingsTab(controller: controller)' in source
assert 'AboutSettingsTab(controller: controller, updateController: updateController)' in source
assert 'onPermissions: { selection = .system }' in source
assert 'publisher(for: .showSettingsSection)' in source and 'notification.object as? SettingsSection' in source
assert source.count('UpdateSettingsView(') == 1
# The three voice-related pages share no nested forms or feature controls.
voice = source[source.index('private struct DictationSettingsTab:'):source.index('private struct SystemSettingsTab:')]
assert voice.count('Form {') == 1
ordered = ['AudioInputSettingsView(', 'if !microphoneGranted || !accessibilityGranted',
           'RecordingSettingsSection(', 'SpeechSettingsSections(']
positions = [voice.index(item) for item in ordered]
assert positions == sorted(positions), 'Microphone, permission notice, shortcut, then recognition'
assert 'DictationProcessingSettingsView(' not in voice
speech = source[source.index('private struct SpeechSettingsSections:'):source.index('struct SettingsChoiceCard:')]
assert 'Form {' not in speech and 'ScrollView' not in speech
assert 'RecognitionEngineChooser(' in speech and 'ModelManagementView(' in speech and 'DoubaoSettingsSection(' in speech
assert 'case .models:' not in source
ai_page = source.split('case .aiService:', 1)[1].split('case .formatting:', 1)[0]
assert 'AIServiceSettingsView(' in ai_page and 'DictationProcessingSettingsView(' in ai_page
assert 'TextFormattingSettingsView(settings: settings)' in source
processing = (root / 'Sources/Talkless/DictationProcessingSettingsView.swift').read_text()
ai_sections, experiments = processing.split('struct LabsSettingsView:', 1)
labs, formatting = experiments.split('struct TextFormattingSettingsView:', 1)
assert 'Form {' not in ai_sections and 'ScrollView' not in ai_sections
labs_page = source.split('case .labs:', 1)[1].split('case .about:', 1)[0]
assert 'LabsSettingsView(settings: settings)' in labs_page
assert labs.count('Form {') == 1 and '.formStyle(.grouped)' in labs
for setting in ['polishEnabled', 'outputLanguage', 'appToneEnabled', 'customInstructions', 'voiceEditEnabled']:
    assert setting in ai_sections and setting not in formatting and setting not in labs
for setting in ['enhancedRecognition', 'sentenceCandidates', 'candidateWaitSeconds']:
    assert setting in labs and setting not in ai_sections and setting not in formatting
# Each switch binds only to its own existing preference; no implicit changes or migrations.
assert 'isOn: $settings.enhancedRecognition' in labs
assert 'isOn: $settings.sentenceCandidates' in labs
assert '.onChange' not in labs and '.onAppear' not in labs and 'Binding(' not in labs
assert 'value: $settings.candidateWaitSeconds, in: 2...15' in labs
for setting in ['punctuationStyle', 'latinSpacing']:
    assert setting in formatting and setting not in ai_sections and setting not in labs
service = (root / 'Sources/Talkless/PolishSettingsView.swift').read_text()
assert service.count('Form {') == 1 and 'ScrollView' not in service
assert 'if let processingSections { processingSections }' in service
assert 'UpdateController(' not in about
assert 'https://typeless.x2x3.com' in about
assert 'https://github.com/x2x3studio/talkless' in about
assert 'NSApplication.shared.applicationIconImage' in about
configured, fallback = about.split('if let updateController {', 1)[1].split('} else {', 1)
assert 'UpdateSettingsView(updater: updateController, controller: controller)' in configured
assert 'Installed version' not in configured
assert fallback.count('LabeledContent(L10n.tr("Installed version")') == 1
updates = (root / 'Sources/Talkless/UpdateSettingsView.swift').read_text()
assert updates.count('LabeledContent(L10n.tr("Installed version")') == 1
for preserved in ['updater.selectChannel($0)', 'updater.setAutomaticallyChecksForUpdates($0)',
                  'updater.checkForUpdates(updateSource.window)', '.background(UpdateSourceReader(view: updateSource))', 'updater.lastUpdateCheckDate',
                  '.disabled(controller.state != .idle || !updater.canCheckForUpdates)',
                  '.disabled(!updater.canChangeChannel)', '.disabled(!updater.canChangeAutomaticChecks)']:
    assert preserved in updates, preserved
Path(sys.argv[2]).write_text('import AppKit\nimport SwiftUI\n' + about.replace('private struct', 'struct', 1))
print('PASS settings hierarchy, retained System controls, updater reuse, branding, links, and existing navigation')
PY
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/Talkless/L10n.swift" \
  "$ROOT/Sources/Talkless/SettingsNavigation.swift" \
  "$WORK/AboutSettings.swift" \
  "$ROOT/Sources/Talkless/UpdateSettingsView.swift" \
  "$ROOT/Sources/Talkless/SettingsStyle.swift" \
  "$ROOT/Tests/AboutSettingsTests/AboutSettingsTests.swift" \
  -o "$APP/Contents/MacOS/about-settings-tests"
"$APP/Contents/MacOS/about-settings-tests" "$@"
