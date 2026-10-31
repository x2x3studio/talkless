#!/usr/bin/env python3
"""Sync the static fallback release metadata and bilingual notes; no network."""
from datetime import date
from html import escape
import json
from pathlib import Path
import re

PUBLIC = Path(__file__).resolve().parents[1] / 'public'
release = json.loads((PUBLIC / 'release.json').read_text())
assert re.fullmatch(r'[0-9.]+', release['version']), 'Invalid release version'
assert re.fullmatch(r'[0-9]+', release['build']), 'Invalid release build'
tag = f"v{release['version']}-beta.{release['build']}"
expected = f"https://github.com/x2x3studio/talkless/releases/download/{tag}/Talkless-{release['version']}-{release['build']}-arm64.dmg"
assert release['downloadURL'] == expected, 'Release download does not match version/build'
assert release['releaseURL'] == f'https://github.com/x2x3studio/talkless/releases/tag/{tag}', 'Unexpected source release URL'
assert release['channel'] == 'beta' and release['architecture'] == 'arm64' and release['minimumMacOS'] == '26', 'Platform requirements changed; review website copy'
assert date.fromisoformat(release['publishedDate']).isoformat() == release['publishedDate'], 'Invalid publication date'
notes = release['notes']
assert set(notes) == {'en', 'zh-Hans'}, 'Published notes must include both languages'
assert all(isinstance(items, list) and items and all(isinstance(item, str) and item.strip() for item in items) for items in notes.values()), 'Release notes must be nonempty text lists'
assert len(notes['en']) == len(notes['zh-Hans']), 'Release note translations must correspond'

for locale, items in notes.items():
    path = PUBLIC / 'locales' / f'{locale}.json'
    catalog = json.loads(path.read_text())
    catalog = {key: value for key, value in catalog.items() if not key.startswith('release.note.')}
    catalog.update({f'release.note.{index}': value for index, value in enumerate(items)})
    path.write_text(json.dumps(catalog, ensure_ascii=True, indent=2) + '\n')

versions = 0
for path in sorted(PUBLIC.glob('*.html')):
    html = path.read_text()
    html, count = re.subn(r'(data-release-version>)[^<]+', lambda match: match[1] + release['version'], html)
    versions += count
    html = re.sub(r'(data-release-build>)[^<]+', lambda match: match[1] + release['build'], html)
    html = re.sub(r'<time data-release-date datetime="[^"]+">[^<]+</time>', f'<time data-release-date datetime="{release["publishedDate"]}">{release["publishedDate"]}</time>', html)
    if path.name == 'updates.html':
        changes = ''.join(f'<li data-i18n="release.note.{index}">{escape(note)}</li>' for index, note in enumerate(notes['en']))
        html, count = re.subn(r'(<ul class="release-notes" data-release-changes>).*?(</ul>)', lambda match: match[1] + changes + match[2], html, flags=re.S)
        assert count == 1, 'Release notes markup changed; review sync script'
    path.write_text(html)
assert versions == 2, 'Static version markup changed; review sync script'
# /download is served by the Worker (src/worker.js); this snapshot is only its fallback.
print(f'Synced fallback release {release["version"]}, publication date and {len(notes["en"])} bilingual notes')
