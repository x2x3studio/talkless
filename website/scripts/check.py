#!/usr/bin/env python3
"""Offline website checks; --links also verifies the repository and the fallback snapshot DMG."""
import argparse
from html import escape
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PUBLIC = ROOT / 'public'
REPOSITORY = 'https://github.com/x2x3studio/talkless'


class Document(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids = []
        self.links = []
        self.anchors = []
        self.keys = set()
        self.headings = []
        self.downloads = []
        self.scripts = []
        self.inline = []
        self.images = []
        self.page = 'home'
        self.header = False
        self.repository_in_header = False

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == 'header':
            self.header = True
        if tag == 'body':
            self.page = values.get('data-page', 'home')
        if 'id' in values:
            self.ids.append(values['id'])
        for key in ('data-i18n', 'data-i18n-aria'):
            if key in values:
                self.keys.add(values[key])
        for key in ('href', 'src'):
            if key in values:
                self.links.append(values[key])
        if tag == 'a':
            self.anchors.append(values)
            if values.get('href') == REPOSITORY:
                self.repository_in_header = self.header
        for key in values:
            if key.startswith('on') or key == 'style':
                self.inline.append((tag, key))
        if tag == 'script':
            self.scripts.append(values.get('src'))
        if tag == 'img':
            self.images.append(values)
        if tag in ('h1', 'h2', 'h3'):
            self.headings.append(tag)
        if 'download-link' in values.get('class', '').split():
            self.downloads.append(values['href'])

    def handle_endtag(self, tag):
        if tag == 'header':
            self.header = False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--links', action='store_true', help='Also HEAD-check the repository and published DMG (network access)')
    args = parser.parse_args()
    js = (PUBLIC / 'app.js').read_text()
    css = (PUBLIC / 'styles.css').read_text()
    catalogs = {locale: json.loads((PUBLIC / 'locales' / f'{locale}.json').read_text()) for locale in ('en', 'zh-Hans')}
    assert set(catalogs['en']) == set(catalogs['zh-Hans']), 'Locale keys must match exactly'
    assert all(isinstance(value, str) and value.strip() for catalog in catalogs.values() for value in catalog.values()), 'Empty localized copy'
    documents = {}
    for path in sorted(PUBLIC.glob('*.html')):
        document = Document()
        html = path.read_text()
        document.feed(html)
        documents['/' if path.stem == 'index' else '/' + path.stem] = document
        assert len(document.ids) == len(set(document.ids)), f'Duplicate IDs: {path.name}'
        assert document.headings.count('h1') == 1, f'Exactly one primary heading required: {path.name}'
        assert not document.inline, f'Inline handlers/styles violate CSP: {path.name}'
        assert document.scripts and all(src and src.startswith('/') for src in document.scripts), 'No inline or external scripts'
        assert all('alt' in image for image in document.images), 'Images need alt attributes'
        assert '<main ' in html and '<nav ' in html and '<footer ' in html, 'Semantic landmarks required'
        assert document.keys <= catalogs['en'].keys(), f'Missing localization keys: {document.keys - catalogs["en"].keys()}'
        meta = 'meta' if document.page == 'home' else document.page + '.meta'
        assert all(f'{meta}.{key}' in catalogs['en'] for key in ('title', 'description')), 'Missing localized metadata'
        github = [link['href'] for link in document.anchors if urlsplit(link.get('href', '')).hostname == 'github.com']
        assert github == [REPOSITORY] and document.repository_in_header, f'Exactly one header repository link required: {path.name}'
        assert all(link == '/download' for link in document.downloads), 'Download links must remain same-origin'
        for link in document.anchors:
            target = urlsplit(link.get('href', ''))
            if target.path in ('/', '/guide', '/privacy', '/updates', '/support') and not target.scheme:
                assert 'data-site-link' in link, f'Navigation must preserve language: {path.name} {link}'
        assert not re.search(r'href="[^"]*(?:/blob/|/issues|/releases/)', html), 'Docs, support and release navigation must stay onsite'
    assert set(documents) == {'/', '/guide', '/privacy', '/updates', '/support'}, 'Expected all four companion routes'
    assert len(documents['/'].downloads) == 2, 'Landing page needs both download buttons'
    assert 'contenteditable="plaintext-only"' in (PUBLIC / 'index.html').read_text(), 'Editable note must not accept rich HTML'
    assert 'prefers-reduced-motion' in css and 'focus-visible' in css, 'Motion and focus support required'
    assert 'prefers-contrast' in css and 'forced-colors' in css, 'Contrast support required'
    assert 'getUserMedia' not in js and 'SpeechRecognition' not in js, 'Demo must not record audio'
    assert 'innerHTML' not in js, 'Localized and demo text must be inserted safely'
    assert not re.search(r'link\.href\s*=\s*(?:download|notes|release)', js), 'Runtime must not restore external navigation'
    dynamic_keys = set(re.findall(r"text\('([^']+)'\)", js))
    assert dynamic_keys <= catalogs['en'].keys(), 'Missing dynamic localization keys'
    for key, phrase in [('privacy.history.body', '15 MB'), ('privacy.open.body', 'standard request logs'), ('demo.disclaimer', 'No microphone access'), ('dictionary.note', 'not a guaranteed correction'), ('privacy.storage.body', 'plaintext'), ('privacy.website.download', 'does not grant a software license')]:
        assert phrase in catalogs['en'][key], f'Keep accurate disclosure: {key}'

    for path in PUBLIC.rglob('*'):
        if path.is_file():
            content = path.read_text()
            assert not any(0x3400 <= ord(char) <= 0x9FFF for char in content), f'Encode Han as JSON Unicode escapes: {path.name}'
            assert not re.search(r'/Users/|/home/|localhost|127\.0\.0\.1', content), f'Private/local path in public file: {path.name}'
    for route, document in documents.items():
        for link in document.links:
            url = urlsplit(link)
            if url.scheme:
                assert url.scheme == 'https', f'Insecure or executable link: {link}'
                assert url.hostname in ('github.com', 'typeless.x2x3.com'), f'Unexpected external dependency: {link}'
            else:
                if url.path == '/download':
                    continue
                target = documents.get(url.path or route)
                if target:
                    if url.fragment:
                        assert url.fragment in target.ids, f'Broken page anchor: {link}'
                else:
                    assert (PUBLIC / url.path.lstrip('/')).is_file(), f'Broken local asset: {link}'
    for path in re.findall(r"fetch\(['\"](/[^'\"]+)['\"]", js):
        assert (PUBLIC / path.lstrip('/')).is_file(), f'Missing fetched asset: {path}'

    release = json.loads((PUBLIC / 'release.json').read_text())
    tag = f"v{release['version']}-beta.{release['build']}"
    expected_download = f'{REPOSITORY}/releases/download/{tag}/Talkless-{release["version"]}-{release["build"]}-arm64.dmg'
    assert release['downloadURL'] == expected_download, 'Unexpected download path'
    assert release['releaseURL'] == f'{REPOSITORY}/releases/tag/{tag}', 'Release tag mismatch'
    assert release['channel'] == 'beta' and release['architecture'] == 'arm64' and release['minimumMacOS'] == '26', 'Release platform metadata mismatch'
    redirects = PUBLIC / '_redirects'
    assert not redirects.exists() or '/download' not in redirects.read_text(), 'The Worker owns /download; a static redirect would pin an old build'
    worker = (ROOT / 'src' / 'worker.js').read_text()
    assert "'/download'" in worker and "'/release.json'" in worker and 'env.ASSETS.fetch' in worker, 'Worker must serve /download and /release.json with a static fallback'
    subprocess.run(['node', '--check', str(ROOT / 'src' / 'worker.js')], check=True)
    for filename in ('index.html', 'updates.html'):
        assert f'data-release-version>{release["version"]}<' in (PUBLIC / filename).read_text(), f'Static release is stale: {filename}'
    assert set(release['notes']) == {'en', 'zh-Hans'} and len(release['notes']['en']) == len(release['notes']['zh-Hans']), 'Release notes need paired translations'
    for locale, notes in release['notes'].items():
        assert notes and all(catalogs[locale][f'release.note.{index}'] == note for index, note in enumerate(notes)), 'Release translations are stale'
    updates_html = (PUBLIC / 'updates.html').read_text()
    for index, note in enumerate(release['notes']['en']):
        assert f'<li data-i18n="release.note.{index}">{escape(note)}</li>' in updates_html, 'Static English release notes are stale'
    assert len(documents['/updates'].keys & {key for key in catalogs['en'] if key.startswith('release.note.')}) == len(release['notes']['en']), 'Stale release note markup'
    assert f'data-release-build>{release["build"]}<' in updates_html, 'Static release build is stale'
    assert f'datetime="{release["publishedDate"]}"' in updates_html, 'Publication date is stale'
    ET.parse(PUBLIC / 'assets' / 'pip.svg')
    sitemap = ET.parse(PUBLIC / 'sitemap.xml')
    urls = {node.text for node in sitemap.findall('.//{http://www.sitemaps.org/schemas/sitemap/0.9}loc')}
    assert urls == {'https://typeless.x2x3.com' + route for route in documents}, 'Sitemap must include all local pages'
    headers = (PUBLIC / '_headers').read_text()
    for directive in ("default-src 'none'", "script-src 'self'", "style-src 'self'", "connect-src 'self'", "frame-ancestors 'none'", 'microphone=()', 'X-Content-Type-Options: nosniff'):
        assert directive in headers, f'Missing security header: {directive}'
    assert 'unsafe-inline' not in headers and 'unsafe-eval' not in headers, 'Keep strict CSP'
    subprocess.run(['node', '--check', str(PUBLIC / 'app.js')], check=True)
    print(f'PASS: {len(documents)} pages, one repository link each, {len(catalogs["en"])} bilingual keys, local routes/anchors/assets, redirect and release consistency, privacy, CSP, SVG/XML and JS syntax')
    if args.links:
        failures = []
        for link in (REPOSITORY, release['downloadURL']):
            try:
                request = Request(link, method='HEAD', headers={'User-Agent': 'Talkless-website-link-check'})
                with urlopen(request, timeout=30) as response:
                    print(f'{response.status} {link}')
            except (HTTPError, URLError, TimeoutError) as error:
                failures.append((link, str(error)))
        if failures:
            for link, error in failures:
                print(f'FAIL {link}: {error}', file=sys.stderr)
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
