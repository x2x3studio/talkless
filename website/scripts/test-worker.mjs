// Offline Worker checks: feeds, release assets, shared KV and ASSETS are synthetic.
import assert from 'node:assert/strict';
import worker, { latestItem, parseNotes, publishedDate, refreshReleases, resolveSnapshot } from '../src/worker.js';

const downloads = 'https://github.com/x2x3studio/talkless/releases/download';
const feedURLs = { stable: `${downloads}/updates/appcast.xml`, beta: `${downloads}/updates/appcast-beta.xml` };
const emptyFeed = '<rss><channel><title>Talkless Updates</title></channel></rss>';
const chineseHeading = String.fromCodePoint(0x7b80, 0x4f53, 0x4e2d, 0x6587);
const notes = `# Talkless\n\n## English\n\n### Improved\n- Faster polishing.\n- Smoother history.\n\n## ${chineseHeading}\n\n### Improved\n- Translation one.\n- Translation two.\n`;
const store = new Map();
const assets = new Map();
let upstream = {};
let requests = [];
let failPut = null;
let failGet = false;
const originalFetch = globalThis.fetch;
globalThis.fetch = async (url, options) => {
  requests.push(url);
  const value = upstream[url];
  return typeof value === 'function' ? value(options)
    : value === undefined ? new Response('missing', { status: 404 }) : new Response(value);
};
const env = {
  RELEASE_CACHE: {
    async get(key, type) {
      assert.equal(type, 'json');
      if (failGet) throw new Error('KV unavailable');
      return store.has(key) ? JSON.parse(store.get(key)) : null;
    },
    async put(key, value) {
      if (key === failPut) throw new Error('KV write failed');
      store.set(key, value);
    },
  },
  ASSETS: { async fetch(request) {
    const path = new URL(request.url ?? request).pathname;
    if (assets.has(path)) return new Response(JSON.stringify(assets.get(path)));
    if (path.endsWith('.json')) return new Response('missing', { status: 404 });
    return new Response(`asset ${path}`);
  } },
};
async function get(path, method = 'GET') {
  const count = requests.length;
  const response = await worker.fetch(new Request(`https://typeless.x2x3.com${path}`, { method }), env);
  assert.equal(requests.length, count, 'Visitor requests must never fetch GitHub');
  return response;
}
async function json(path = '/release.json') { return (await get(path)).json(); }
function feed(tag, version, build) {
  return `<rss><channel><item><sparkle:version>${build}</sparkle:version><sparkle:shortVersionString>${version}</sparkle:shortVersionString>`
    + '<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>'
    + `<enclosure url="${downloads}/${tag}/Talkless-${version}-${build}-arm64.zip" length="1" /></item></channel></rss>`;
}
function publish(channel, overrides = {}) {
  const version = channel === 'stable' ? '2026.1101.100' : '2026.1102.5';
  const build = channel === 'stable' ? '1793500000' : '1793600000';
  const tag = `v${version}${channel === 'beta' ? `-beta.${build}` : ''}`;
  const base = `${downloads}/${tag}`;
  upstream[feedURLs[channel]] = feed(tag, version, build);
  upstream[`${base}/release-metadata.json`] = JSON.stringify({
    tag, version, build_number: build, release_channel: channel, notarized: true,
    files: { [`Talkless-${version}-${build}-arm64.dmg`]: {} }, ...overrides,
  });
  upstream[`${base}/release-notes.md`] = notes;
  return base;
}
function reset() {
  store.clear(); assets.clear(); upstream = {}; requests = []; failPut = null; failGet = false;
}

// Both channels are refreshed and persisted independently, even when stable exists.
reset();
publish('stable'); publish('beta');
let results = await refreshReleases(env);
assert.equal(results.stable.ok, true);
assert.equal(results.beta.ok, true);
assert.equal(store.size, 2);
assert.equal(requests.length, 6);
const stable = results.stable.release;
const beta = results.beta.release;
for (const channel of ['stable', 'beta']) {
  const snapshot = JSON.parse(store.get(`latest-${channel}`));
  assert.deepEqual(snapshot.release, results[channel].release);
  assert.ok(Number.isFinite(Date.parse(snapshot.fetchedAt)));
  assert.equal(snapshot.release.channel, channel);
}
assert.equal(beta.publishedDate, '2026-11-02');
assert.equal(beta.minimumMacOS, '26');
assert.equal(beta.downloadURL, `${downloads}/v2026.1102.5-beta.1793600000/Talkless-2026.1102.5-1793600000-arm64.dmg`);
assert.deepEqual(beta.notes.en, ['Faster polishing.', 'Smoother history.']);
assert.equal(beta.notes['zh-Hans'].length, 2);
assert.deepEqual(await json(), stable, 'Stable wins over a newer beta');
assert.deepEqual(await json('/release.json?channel=stable'), stable);
assert.deepEqual(await json('/release.json?channel=beta'), beta);
for (const [query, expected] of [['', stable], ['?channel=stable', stable], ['?channel=beta', beta]]) {
  const download = await get(`/download${query}`);
  assert.equal(download.status, 302);
  assert.equal(download.headers.get('Location'), expected.downloadURL);
  assert.equal(download.headers.get('Cache-Control'), 'no-store');
}

// Empty feeds, malformed/untrusted assets and KV write failures preserve the last good value.
const saved = new Map(store);
upstream = {};
results = await refreshReleases(env);
assert.equal(results.stable.ok, false);
assert.equal(results.beta.ok, false);
assert.deepEqual(store, saved);
assert.deepEqual(await json(), stable);
for (const channel of ['stable', 'beta']) {
  const other = channel === 'stable' ? 'beta' : 'stable';
  for (const overrides of [{ notarized: false }, { tag: 'v0.0.0' }, { files: {} }, { release_channel: other }, { build_number: '1' }]) {
    publish(channel, overrides); publish(other);
    results = await refreshReleases(env);
    assert.equal(results[channel].ok, false, JSON.stringify(overrides));
    assert.equal(results[other].ok, true, 'Other channel keeps refreshing');
    assert.equal(store.get(`latest-${channel}`), saved.get(`latest-${channel}`));
  }
  publish(channel); publish(other);
  upstream[feedURLs[channel]] = emptyFeed;
  assert.equal((await refreshReleases(env))[channel].ok, false);
  assert.equal(store.get(`latest-${channel}`), saved.get(`latest-${channel}`));
  const base = publish(channel);
  upstream[`${base}/release-notes.md`] = '## English\n- Unpaired translation.';
  assert.equal((await refreshReleases(env))[channel].ok, false);
  assert.equal(store.get(`latest-${channel}`), saved.get(`latest-${channel}`));
  publish(channel);
  failPut = `latest-${channel}`;
  results = await refreshReleases(env);
  assert.equal(results[channel].ok, false);
  assert.equal(results[other].ok, true);
  assert.equal(store.get(`latest-${channel}`), saved.get(`latest-${channel}`));
  failPut = null;
  // Reset the expected snapshot after successful refreshes of this channel as "other".
  for (const [key, value] of store) saved.set(key, value);
}

// Per-fetch timeout covers the feed, metadata and streamed notes, with beta isolated.
const originalSetTimeout = globalThis.setTimeout;
try {
  globalThis.setTimeout = (callback, ms, ...args) => {
    assert.equal(ms, 8000);
    return originalSetTimeout(callback, 5, ...args);
  };
  for (const target of ['feed', 'metadata', 'notes']) {
    const base = publish('stable'); publish('beta');
    const previous = store.get('latest-stable');
    let signal;
    const url = target === 'feed' ? feedURLs.stable : `${base}/release-${target === 'metadata' ? 'metadata.json' : 'notes.md'}`;
    upstream[url] = options => {
      signal = options.signal;
      if (target !== 'notes') return new Promise(() => {});
      return new Response(new ReadableStream({ start(controller) {
        controller.enqueue(new TextEncoder().encode('## English\n'));
        signal.addEventListener('abort', () => controller.error(signal.reason), { once: true });
      } }));
    };
    results = await refreshReleases(env);
    assert.equal(results.stable.ok, false);
    assert.match(results.stable.error, /timed out/);
    assert.equal(results.beta.ok, true);
    assert.equal(signal.aborted, true);
    assert.equal(store.get('latest-stable'), previous);
  }
} finally { globalThis.setTimeout = originalSetTimeout; }

// Reject oversized upstream bodies with or without Content-Length (cap is 1 MiB).
for (const header of [true, false]) {
  for (const target of ['feed', 'metadata', 'notes']) {
    const base = publish('stable'); publish('beta');
    const previous = store.get('latest-stable');
    const url = target === 'feed' ? feedURLs.stable : `${base}/release-${target === 'metadata' ? 'metadata.json' : 'notes.md'}`;
    upstream[url] = () => new Response(header ? 'small' : 'x'.repeat(1024 * 1024 + 1), {
      headers: header ? { 'Content-Length': String(1024 * 1024 + 1) } : {},
    });
    results = await refreshReleases(env);
    assert.equal(results.stable.ok, false);
    assert.match(results.stable.error, /size limit/);
    assert.equal(results.beta.ok, true);
    assert.equal(store.get('latest-stable'), previous);
  }
}

// Feed/enclosure mismatch never writes a snapshot.
for (const [channel, tag, version, build] of [
  ['beta', 'v1.2.3-beta.9', beta.version, beta.build],
  ['stable', 'v1.2.3', stable.version, stable.build],
]) {
  publish('stable'); publish('beta');
  const previous = store.get(`latest-${channel}`);
  upstream[feedURLs[channel]] = feed(tag, version, build);
  results = await refreshReleases(env);
  assert.equal(results[channel].ok, false);
  assert.match(results[channel].error, /naming scheme/);
  assert.equal(store.get(`latest-${channel}`), previous);
}

// Stable can be the only beta-feed item: it must preserve beta, not relabel stable.
publish('stable'); publish('beta');
const previousBeta = store.get('latest-beta');
upstream[feedURLs.beta] = upstream[feedURLs.stable];
results = await refreshReleases(env);
assert.equal(results.stable.ok, true);
assert.equal(results.beta.ok, false);
assert.equal(results.beta.code, 'empty_feed');
assert.equal(store.get('latest-beta'), previousBeta);
store.delete('latest-beta');
results = await refreshReleases(env);
assert.equal(results.beta.code, 'empty_feed');
assert.equal(store.has('latest-beta'), false);
// Select the newest actual beta even if a higher-build stable leads the beta feed.
const stableUpgrade = feed('v2026.1103.1', '2026.1103.1', '1793700000');
publish('beta');
upstream[feedURLs.beta] = stableUpgrade + upstream[feedURLs.beta];
assert.equal((await refreshReleases(env)).beta.release.channel, 'beta');
assert.equal(latestItem(stableUpgrade, 'beta'), undefined);
assert.equal(latestItem(feed('v2026.1102.5-beta.1793600000', beta.version, beta.build), 'stable'), undefined);
// Local fallback candidates are re-resolved through remote metadata and notes.
publish('beta');
assert.deepEqual(await resolveSnapshot({ ...beta, notes: { en: ['local'], 'zh-Hans': ['local'] } }), beta);
publish('beta', { notarized: false });
await assert.rejects(resolveSnapshot(beta), /notarized/);
await assert.rejects(resolveSnapshot({ ...beta, channel: 'stable' }), /Invalid candidate/);

// Strict channels with only beta available, including pre-first-stable static deployments.
reset();
assets.set('/release.json', beta);
assert.deepEqual(await json(), beta);
assert.deepEqual(await json('/release.json?channel=beta'), beta);
for (const path of ['/release.json?channel=stable', '/download?channel=stable']) {
  assert.equal((await get(path)).status, 404);
  const response = await get(path, 'HEAD');
  assert.equal(response.status, 404);
  assert.equal(await response.text(), '');
}
assert.equal((await get('/download')).headers.get('Location'), beta.downloadURL);
assets.clear();
publish('beta'); upstream[feedURLs.stable] = emptyFeed;
results = await refreshReleases(env);
assert.equal(results.stable.ok, false);
assert.equal(results.beta.ok, true);
assert.equal(store.has('latest-stable'), false);
assert.deepEqual(await json(), beta);
assert.equal((await get('/download?channel=stable')).status, 404);

// A stable static fallback still takes precedence over cached beta; beta has its own fallback.
assets.set('/release.json', stable);
assets.set('/release-beta.json', beta);
assert.deepEqual(await json(), stable);
assert.deepEqual(await json('/release.json?channel=beta'), beta);
store.clear();
assert.deepEqual(await json('/release.json?channel=beta'), beta);
assets.delete('/release-beta.json');
assert.equal((await get('/release.json?channel=beta')).status, 404, 'Stable is not a beta fallback');
assets.set('/release-beta.json', stable);
assert.equal((await get('/release.json?channel=beta')).status, 404, 'Do not trust a mislabeled beta snapshot');

// KV read failures and invalid snapshots use static fallback, never cross-channel KV data.
for (const value of ['{', JSON.stringify({ release: beta, fetchedAt: new Date().toISOString() }),
  JSON.stringify({ release: stable, fetchedAt: 'invalid' }),
  JSON.stringify({ release: { ...stable, downloadURL: 'https://example.com/malware.dmg' }, fetchedAt: new Date().toISOString() })]) {
  store.set('latest-stable', value);
  assert.deepEqual(await json(), stable);
}
failGet = true;
assert.deepEqual(await json(), stable);
failGet = false;
store.clear(); assets.clear();
assert.equal((await get('/release.json')).status, 404);
assert.equal((await get('/download')).status, 404);

// Scheduled handler refreshes both channels; static paths and request validation stay local.
publish('stable'); publish('beta');
await worker.scheduled({}, env);
assert.equal(store.size, 2);
assert.equal(await (await get('/guide')).text(), 'asset /guide');
assert.equal((await get('/download', 'POST')).status, 405);
assert.equal((await get('/release.json?channel=nightly')).status, 400);
assert.equal((await get('/download?channel=')).status, 400);
assert.equal(await (await get('/release.json', 'HEAD')).text(), '');
assert.equal((await get('/download?channel=beta', 'HEAD')).headers.get('Location'), beta.downloadURL);
assert.throws(() => parseNotes('## English\n- Only English.\n'));
assert.throws(() => publishedDate('1.2.3'));
assert.equal(latestItem(emptyFeed), undefined);
const older = feed('v2026.1031.1-beta.1', '2026.1031.1', '1');
assert.equal(latestItem(older + feed('v2026.1102.5-beta.1793600000', beta.version, beta.build)).build, beta.build);
globalThis.fetch = originalFetch;
console.log('PASS: shared stable/beta snapshots, strict channel routing, static fallbacks, isolated refresh failures, 8s timeouts, size limits and zero visitor GitHub fetches');
