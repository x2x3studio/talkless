// Visitors read shared, independently validated channel snapshots, never GitHub.
// Scheduled refreshes read the public Sparkle feeds and each release's own assets.
const DOWNLOADS = 'https://github.com/x2x3studio/talkless/releases/download';
const FEEDS = [['stable', `${DOWNLOADS}/updates/appcast.xml`], ['beta', `${DOWNLOADS}/updates/appcast-beta.xml`]];
const FETCH_TIMEOUT_MS = 8000;
const MAX_RESPONSE_BYTES = 1024 * 1024;

export default {
  async fetch(request, env) {
    const { pathname, searchParams } = new URL(request.url);
    if (pathname !== '/download' && pathname !== '/release.json') return env.ASSETS.fetch(request);
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('Method not allowed', { status: 405, headers: { Allow: 'GET, HEAD' } });
    }
    const channel = searchParams.get('channel');
    if (channel !== null && channel !== 'stable' && channel !== 'beta') {
      return unavailable(request, 400, 'Unknown release channel');
    }
    const release = await currentRelease(request, env, channel);
    if (!release) return unavailable(request, 404, 'No published release in this channel');
    if (pathname === '/download') {
      return new Response(null, { status: 302, headers: { Location: release.downloadURL, 'Cache-Control': 'no-store' } });
    }
    return new Response(request.method === 'HEAD' ? null : JSON.stringify(release, null, 2), {
      headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'public, max-age=60' },
    });
  },
  async scheduled(_event, env) {
    const results = await refreshReleases(env);
    for (const [channel, result] of Object.entries(results)) {
      if (!result.ok) console.error(`Release refresh (${channel}): ${result.error}`);
    }
  },
};

function unavailable(request, status, message) {
  return new Response(request.method === 'HEAD' ? null : message, { status, headers: { 'Cache-Control': 'no-store' } });
}

async function currentRelease(request, env, channel) {
  // Reuse the default static snapshot if both channel lookups need it.
  const assets = new Map();
  async function staticRelease(path, expectedChannel) {
    if (!assets.has(path)) assets.set(path, (async () => {
      try {
        const response = await env.ASSETS.fetch(new URL(path, request.url));
        return response.ok ? await response.json() : null;
      } catch { return null; }
    })());
    const release = await assets.get(path);
    return validRelease(release, expectedChannel) ? release : null;
  }
  for (const candidate of channel ? [channel] : ['stable', 'beta']) {
    try {
      const snapshot = await env.RELEASE_CACHE?.get(`latest-${candidate}`, 'json');
      if (snapshot && Number.isFinite(Date.parse(snapshot.fetchedAt)) && validRelease(snapshot.release, candidate)) {
        return snapshot.release;
      }
    } catch { /* KV unavailable or malformed: keep serving the deploy-time snapshot. */ }
    // release.json remains a single default snapshot; never relabel its channel.
    if (candidate === 'beta') {
      const beta = await staticRelease('/release-beta.json', 'beta');
      if (beta) return beta;
    }
    const fallback = await staticRelease('/release.json', candidate);
    if (fallback) return fallback;
  }
  return null;
}

function validRelease(release, channel) {
  if (!release || release.channel !== channel || !/^\d{4}\.\d{4}\.\d+$/.test(release.version)
      || !/^\d+$/.test(release.build) || release.architecture !== 'arm64'
      || typeof release.minimumMacOS !== 'string' || typeof release.publishedDate !== 'string') return false;
  const tag = `v${release.version}${channel === 'beta' ? `-beta.${release.build}` : ''}`;
  return release.downloadURL === `${DOWNLOADS}/${tag}/Talkless-${release.version}-${release.build}-arm64.dmg`
    && release.releaseURL === `https://github.com/x2x3studio/talkless/releases/tag/${tag}`
    && Array.isArray(release.notes?.en) && Array.isArray(release.notes?.['zh-Hans'])
    && release.notes.en.length > 0 && release.notes.en.length === release.notes['zh-Hans'].length
    && [...release.notes.en, ...release.notes['zh-Hans']].every(note => typeof note === 'string');
}

// Also used by the deployment seed script with a Wrangler-backed put adapter.
// Failed/empty feeds never delete or overwrite the previous snapshot; no expiry is set.
export async function refreshReleases(env) {
  if (!env.RELEASE_CACHE?.put) throw new Error('RELEASE_CACHE binding is required for refresh');
  return Object.fromEntries(await Promise.all(FEEDS.map(async ([channel, feed]) => {
    try {
      const item = latestItem(await text(feed), channel);
      if (!item) return [channel, { ok: false, code: 'empty_feed', error: 'No published release for this channel in feed' }];
      const release = await describe(channel, item);
      if (!validRelease(release, channel)) throw new Error('Invalid release snapshot');
      const snapshot = { release, fetchedAt: new Date().toISOString() };
      await env.RELEASE_CACHE.put(`latest-${channel}`, JSON.stringify(snapshot));
      return [channel, { ok: true, ...snapshot }];
    } catch (error) {
      return [channel, { ok: false, error: error instanceof Error ? error.message : String(error) }];
    }
  })));
}

// For initial beta seeding when the beta feed now offers only the stable upgrade.
// The local file only identifies a candidate; fetch its metadata and notes again.
export async function resolveSnapshot(release) {
  if (!['stable', 'beta'].includes(release?.channel) || !validRelease(release, release.channel)) {
    throw new Error('Invalid candidate release snapshot');
  }
  return describe(release.channel, {
    version: release.version,
    build: release.build,
    minimumSystem: release.minimumMacOS,
    enclosure: release.downloadURL.replace(/\.dmg$/, '.zip'),
  });
}

async function text(url) {
  const controller = new AbortController();
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      const error = new Error(`Fetch timed out after ${FETCH_TIMEOUT_MS}ms`);
      controller.abort(error);
      reject(error);
    }, FETCH_TIMEOUT_MS);
  });
  try {
    return await Promise.race([timeout, (async () => {
      const response = await fetch(url, {
        headers: { 'User-Agent': 'Talkless-website' }, redirect: 'follow', signal: controller.signal,
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      if (Number(response.headers.get('Content-Length')) > MAX_RESPONSE_BYTES) {
        throw new Error('Release response exceeds size limit');
      }
      if (!response.body) return '';
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let size = 0;
      let value = '';
      try {
        while (true) {
          const chunk = await reader.read();
          if (chunk.done) break;
          size += chunk.value.byteLength;
          if (size > MAX_RESPONSE_BYTES) throw new Error('Release response exceeds size limit');
          value += decoder.decode(chunk.value, { stream: true });
        }
        return value + decoder.decode();
      } finally {
        reader.releaseLock();
      }
    })()]);
  } finally {
    clearTimeout(timer);
    controller.abort();
  }
}

// A stable publication can also be offered in the beta feed for in-app upgrades.
// Select the actual release channel, not the feed's audience; describe still validates it.
export function latestItem(xml, channel) {
  const items = [...xml.matchAll(/<item>([\s\S]*?)<\/item>/g)].map(([, body]) => ({
    build: tag(body, 'sparkle:version'),
    version: tag(body, 'sparkle:shortVersionString'),
    channel: tag(body, 'sparkle:channel'),
    minimumSystem: tag(body, 'sparkle:minimumSystemVersion'),
    enclosure: body.match(/<enclosure\s[^>]*url="([^"]+)"/)?.[1],
  })).filter(item => {
    if (!item.build || !item.version || !item.enclosure) return false;
    if (!channel) return true;
    const releaseTag = item.enclosure.split('/').at(-2);
    const actualChannel = /-beta\.\d+$/.test(releaseTag) ? 'beta' : 'stable';
    return actualChannel === channel && (!item.channel || item.channel === channel);
  });
  return items.sort((a, b) => Number(b.build) - Number(a.build))[0];
}

function tag(body, name) {
  return body.match(new RegExp(`<${name}>([^<]*)</${name}>`))?.[1]?.trim();
}

async function describe(channel, item) {
  const pattern = new RegExp(`^${DOWNLOADS.replace(/[.]/g, '\\.')}/(v([0-9.]+)(?:-beta\\.([0-9]+))?)/Talkless-([0-9.]+)-([0-9]+)-arm64\\.zip$`);
  const match = item.enclosure.match(pattern);
  if (!match || match[2] !== item.version || match[4] !== item.version || match[5] !== item.build
      || (channel === 'beta' ? match[3] !== item.build : match[3] !== undefined)) {
    throw new Error('Feed item does not match the release naming scheme');
  }
  const releaseTag = match[1];
  const base = `${DOWNLOADS}/${releaseTag}`;
  const dmg = `Talkless-${item.version}-${item.build}-arm64.dmg`;
  const [metadata, notes] = await Promise.all([text(`${base}/release-metadata.json`).then(JSON.parse), text(`${base}/release-notes.md`)]);
  if (metadata.tag !== releaseTag || metadata.version !== item.version || metadata.build_number !== item.build
      || metadata.release_channel !== channel || metadata.notarized !== true || !metadata.files?.[dmg]) {
    throw new Error('Release metadata does not describe a notarized DMG for this feed item');
  }
  return {
    version: item.version,
    build: item.build,
    channel,
    architecture: 'arm64',
    minimumMacOS: (item.minimumSystem || '26').replace(/\.0$/, ''),
    downloadURL: `${base}/${dmg}`,
    releaseURL: `https://github.com/x2x3studio/talkless/releases/tag/${releaseTag}`,
    publishedDate: publishedDate(item.version),
    notes: parseNotes(notes),
  };
}

// Calendar versions are YEAR.MMDD.SECONDS (UTC), e.g. 2026.1031.40954 -> 2026-10-31.
export function publishedDate(version) {
  const match = version.match(/^(\d{4})\.(\d{2})(\d{2})\./);
  if (!match) throw new Error('Unexpected version format');
  return `${match[1]}-${match[2]}-${match[3]}`;
}

// release-notes.md has "## English" and Simplified Chinese sections of "### Heading" and "- bullet" lines.
export function parseNotes(markdown) {
  const notes = { en: [], 'zh-Hans': [] };
  let section = null;
  for (const line of markdown.split('\n')) {
    if (line.startsWith('## ')) {
      const title = line.slice(3).trim();
      section = title === 'English' ? 'en' : title === '\u7b80\u4f53\u4e2d\u6587' ? 'zh-Hans' : null;
    } else if (section && line.startsWith('- ')) {
      notes[section].push(line.slice(2).trim());
    }
  }
  if (!notes.en.length || notes.en.length !== notes['zh-Hans'].length) throw new Error('Release notes need paired translations');
  return notes;
}
