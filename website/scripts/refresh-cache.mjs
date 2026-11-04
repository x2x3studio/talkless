// Seed the shared remote KV using exactly the Worker's feed/metadata/notes resolver.
// No public write endpoint or Cloudflare credentials beyond authenticated Wrangler.
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { fileURLToPath } from 'node:url';
import { refreshReleases, resolveSnapshot } from '../src/worker.js';

const { values } = parseArgs({ options: {
  config: { type: 'string', default: fileURLToPath(new URL('../wrangler.jsonc', import.meta.url)) },
  binding: { type: 'string', default: 'RELEASE_CACHE' },
  'beta-snapshot': { type: 'string' },
  help: { type: 'boolean', default: false },
} });
if (values.help) {
  console.log('Usage: node website/scripts/refresh-cache.mjs [--config website/wrangler.jsonc] [--binding RELEASE_CACHE] [--beta-snapshot website/public/release-beta.json]');
  process.exit(0);
}
function wrangler(args, capture = false) {
  return new Promise((done, reject) => {
    const child = spawn('wrangler', [...args, '--config', resolve(values.config), '--binding', values.binding, '--remote'], {
      stdio: capture ? ['ignore', 'pipe', 'inherit'] : 'inherit',
    });
    let stdout = '';
    if (capture) child.stdout.setEncoding('utf8').on('data', chunk => { stdout += chunk; });
    child.once('error', reject);
    child.once('close', (code, signal) => code === 0 ? done(stdout) : reject(new Error(`Wrangler exited with ${signal || code}`)));
  });
}
const directory = await mkdtemp(join(tmpdir(), 'talkless-release-cache-'));
try {
  const cache = {
    async put(key, value) {
      const path = join(directory, `${key}.json`);
      await writeFile(path, value, { mode: 0o600 });
      await wrangler(['kv', 'key', 'put', key, '--path', path]);
    },
  };
  const results = await refreshReleases({ RELEASE_CACHE: cache });
  if (values['beta-snapshot'] && results.beta.code === 'empty_feed') {
    try {
      // Do not replace an existing beta with an older deploy-time candidate.
      // Listing errors abort instead of being mistaken for an empty namespace.
      const keys = JSON.parse(await wrangler(['kv', 'key', 'list', '--prefix', 'latest-beta'], true));
      if (!Array.isArray(keys)) throw new Error('Unexpected KV key list');
      if (keys.some(key => key.name === 'latest-beta')) {
        results.beta = { ok: true, preserved: true };
      } else {
        const candidate = JSON.parse(await readFile(resolve(values['beta-snapshot']), 'utf8'));
        if (candidate.channel !== 'beta') throw new Error('Beta seed candidate must be a beta release');
        const release = await resolveSnapshot(candidate);
        const snapshot = { release, fetchedAt: new Date().toISOString() };
        await cache.put('latest-beta', JSON.stringify(snapshot));
        results.beta = { ok: true, ...snapshot };
      }
    } catch (error) {
      results.beta = { ok: false, error: error.message };
    }
  }
  for (const [channel, result] of Object.entries(results)) {
    if (result.preserved) console.log(`${channel}: preserved existing snapshot (feed has no beta item)`);
    else if (result.ok) console.log(`${channel}: seeded ${result.release.version} (${result.release.build}) at ${result.fetchedAt}`);
    else {
      console.error(`${channel}: unchanged (${result.error})`);
      process.exitCode = 1;
    }
  }
} finally {
  await rm(directory, { recursive: true, force: true });
}
