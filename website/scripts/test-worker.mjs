// Offline Worker checks: feeds, release assets, cache and ASSETS are all synthetic.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const staticRelease = JSON.parse(await readFile(new URL('../public/release.json', import.meta.url), 'utf8'));
const downloads = 'https://github.com/x2x3studio/talkless/releases/download';
const store = new Map();
globalThis.caches = { default: {
  async match(key) { return store.has(key) ? new Response(store.get(key)) : undefined; },
  async put(key, response) { store.set(key, await response.text()); },
} };
let upstream = {};
globalThis.fetch = async url => (url in upstream ? new Response(upstream[url]) : new Response('missing', { status: 404 }));
const worker = (await import('../src/worker.js')).default;
const { parseNotes, publishedDate } = await import('../src/worker.js');

const env = { ASSETS: { fetch: async request => {
  const path = new URL(request.url ?? request).pathname;
  return path === '/release.json' ? new Response(JSON.stringify(staticRelease)) : new Response(`asset ${path}`);
} } };
const pending = [];
const context = { waitUntil: promise => pending.push(promise) };
async function get(path, method = 'GET') {
  const response = await worker.fetch(new Request(`https://typeless.x2x3.com${path}`, { method }), env, context);
  await Promise.all(pending.splice(0));
  return response;
}
const emptyFeed = '<rss><channel><title>Talkless Updates</title></channel></rss>';
function feed(tag, version, build) {
  return `<rss><channel><item><sparkle:version>${build}</sparkle:version><sparkle:shortVersionString>${version}</sparkle:shortVersionString>`
    + `<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>`
    + `<enclosure url="${downloads}/${tag}/Talkless-${version}-${build}-arm64.zip" length="1" /></item></channel></rss>`;
}
const notes = '# Talkless\n\n## English\n\n### Improved\n- Faster polishing.\n- Smoother history.\n\n## \u7b80\u4f53\u4e2d\u6587\n\n### \u6539\u8fdb\n- \u66f4\u5feb\u3002\n- \u66f4\u987a\u3002\n';
function publish(channel, tag, version, build, overrides = {}) {
  const dmg = `Talkless-${version}-${build}-arm64.dmg`;
  upstream[`${downloads}/${tag}/release-metadata.json`] = JSON.stringify({
    tag, version, build_number: build, release_channel: channel, notarized: true, files: { [dmg]: {} }, ...overrides,
  });
  upstream[`${downloads}/${tag}/release-notes.md`] = notes;
}
function reset() { store.clear(); upstream = {}; }

// Beta only: the newest beta is served, with notes, date and minimum macOS derived from its assets.
reset();
upstream[`${downloads}/updates/appcast.xml`] = emptyFeed;
upstream[`${downloads}/updates/appcast-beta.xml`] = feed('v2026.1031.40954-beta.1793445754', '2026.1031.40954', '1793445754');
publish('beta', 'v2026.1031.40954-beta.1793445754', '2026.1031.40954', '1793445754');
let release = await (await get('/release.json')).json();
assert.equal(release.version, '2026.1031.40954');
assert.equal(release.channel, 'beta');
assert.equal(release.publishedDate, '2026-10-31');
assert.equal(release.minimumMacOS, '26');
assert.equal(release.downloadURL, `${downloads}/v2026.1031.40954-beta.1793445754/Talkless-2026.1031.40954-1793445754-arm64.dmg`);
assert.equal(release.releaseURL, 'https://github.com/x2x3studio/talkless/releases/tag/v2026.1031.40954-beta.1793445754');
assert.deepEqual(release.notes.en, ['Faster polishing.', 'Smoother history.']);
assert.equal(release.notes['zh-Hans'].length, 2);
const download = await get('/download');
assert.equal(download.status, 302);
assert.equal(download.headers.get('Location'), release.downloadURL);
assert.equal(download.headers.get('Cache-Control'), 'no-store');

// The fresh cache answers without touching upstream.
upstream = {};
assert.equal((await (await get('/release.json')).json()).version, '2026.1031.40954');

// A stable release wins over a newer beta.
reset();
upstream[`${downloads}/updates/appcast.xml`] = feed('v2026.1101.100', '2026.1101.100', '1793500000');
upstream[`${downloads}/updates/appcast-beta.xml`] = feed('v2026.1102.5-beta.1793600000', '2026.1102.5', '1793600000');
publish('stable', 'v2026.1101.100', '2026.1101.100', '1793500000');
release = await (await get('/release.json')).json();
assert.equal(release.channel, 'stable');
assert.equal(release.downloadURL, `${downloads}/v2026.1101.100/Talkless-2026.1101.100-1793500000-arm64.dmg`);

// Upstream failure after the fresh entry expires reuses the last good release.
store.delete('https://typeless.x2x3.com/__release-cache/fresh');
upstream = {};
assert.equal((await (await get('/release.json')).json()).version, '2026.1101.100');

// Without any cached result, failures and untrusted metadata fall back to the static snapshot.
for (const overrides of [{ notarized: false }, { tag: 'v0.0.0' }, { files: {} }, { release_channel: 'stable' }]) {
  reset();
  upstream[`${downloads}/updates/appcast.xml`] = emptyFeed;
  upstream[`${downloads}/updates/appcast-beta.xml`] = feed('v2026.1031.40954-beta.1793445754', '2026.1031.40954', '1793445754');
  publish('beta', 'v2026.1031.40954-beta.1793445754', '2026.1031.40954', '1793445754', overrides);
  assert.equal((await (await get('/release.json')).json()).version, staticRelease.version, JSON.stringify(overrides));
}
reset();
upstream[`${downloads}/updates/appcast.xml`] = emptyFeed;
upstream[`${downloads}/updates/appcast-beta.xml`] = feed('v1.2.3-beta.9', '2026.1031.40954', '1793445754');
assert.equal((await get('/download')).headers.get('Location'), staticRelease.downloadURL, 'Feed and tag must agree');
reset();
assert.equal((await get('/download')).headers.get('Location'), staticRelease.downloadURL, 'Unreachable feeds use the snapshot');

// Other paths and methods.
assert.equal(await (await get('/guide')).text(), 'asset /guide');
assert.equal((await get('/download', 'POST')).status, 405);
assert.equal(await (await get('/release.json', 'HEAD')).text(), '');
assert.throws(() => parseNotes('## English\n- Only English.\n'));
assert.throws(() => publishedDate('1.2.3'));
console.log('PASS: Worker prefers stable, derives beta metadata from release assets, caches fresh/last-good results, rejects mismatched metadata, and falls back to the static snapshot');
