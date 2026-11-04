# Talkless website

Public product page: https://typeless.x2x3.com. The product is **Talkless**; the hostname does not rename the app.

Cloudflare Worker `talkless-site` serves `public/` as static assets, following Mateo's static Worker deployment pattern. A small script (`src/worker.js`) handles only `/download` and `/release.json`, with shared KV storing public release snapshots only. No build step, user database, analytics script, or microphone access. The demo is simulated; edited demo text stays in the browser.

## Preview and check

```sh
wrangler dev --config website/wrangler.jsonc --port 4173
python3 -I website/scripts/check.py --links
node website/scripts/test-demo.mjs
node website/scripts/test-worker.mjs
```

If the local Wrangler runtime is older than `compatibility_date`, add `--compatibility-date` with its newest supported date for local preview only. Use Wrangler for route checks: a plain Python file server does not emulate extensionless HTML or `_redirects`. Public routes are `/`, `/guide`, `/privacy`, `/updates`, `/support` and `/download`. The four companion pages are complete static English documents with bilingual content loaded from same-origin catalogs. JavaScript is not required for navigation, reading English or downloading.

Use the language toggle or `?lang=zh-Hans` / `?lang=en`. Selection follows query, stored preference, then the first supported browser language. Internal page links carry the active language so it survives navigation even with local storage blocked. Download links do not carry language parameters. Chinese JSON is Unicode-escaped to preserve repository source rules.

Each page has exactly one GitHub anchor, the repository entry in its header. Guide, privacy, support and release notes stay onsite; there are no visible GitHub blob, issue or release-tag links. Support explains how to reach Issues from that repository entry rather than pretending this static site has a report form. The demo never records audio or calls an AI service.

## Deploy

Requires an authenticated Wrangler CLI with access to the account and zone in `wrangler.jsonc`. Tested with Wrangler 4.154.0. Credentials stay outside the repository.

Bind a shared KV namespace as `RELEASE_CACHE` in `wrangler.jsonc` and configure an hourly cron (`0 * * * *`). Before the first deployment (or immediately after publishing a release), seed both remote channel snapshots with authenticated Wrangler:

```sh
node website/scripts/refresh-cache.mjs --config website/wrangler.jsonc --binding RELEASE_CACHE
wrangler deploy --config website/wrangler.jsonc --dry-run
wrangler deploy --config website/wrangler.jsonc
```

The seed script requires `wrangler` on `PATH`. If using Wrangler through npm rather than a global install, run `npx --yes --package wrangler -c 'node website/scripts/refresh-cache.mjs'` to provide it to the child process.

The seed script uses the same resolver as the scheduled Worker, then runs `wrangler kv key put --remote` for each successful channel. `--config` and `--binding` are optional with the defaults shown above. Keys are `latest-stable` and `latest-beta`; each stores `{ release, fetchedAt }`, with an ISO UTC timestamp and no expiry. A failed or empty channel is left unchanged, the other is still processed, and the script exits nonzero if either channel could not be refreshed. In a beta-only deployment an empty stable feed is expected; it does not prevent beta from being seeded. There is no public cache-write endpoint.

The beta Sparkle feed may offer a stable release so beta app installations can upgrade. The website filters by the actual release channel rather than labeling that stable item as beta; if no beta item remains, it preserves the prior beta KV snapshot. For an initial seed with an empty beta KV, pass `--beta-snapshot website/public/release-beta.json` (also inside the `npx -c` command if used). Only when the beta feed has no beta item, the script checks that `latest-beta` does not exist, then independently re-fetches and validates the candidate's release metadata and bilingual notes before writing it. Existing beta KV is preserved; network failures, failed validation or key-list errors never authorize this fallback. Run this bootstrap before enabling scheduled refreshes; KV is eventually consistent, not a conditional-write database.

The custom-domain route provisions `typeless.x2x3.com`; workers.dev and preview URLs are disabled. Deploy only `public/`, never the repository root. `_headers` applies a same-origin content security policy and disables microphone/camera permissions.

`html_handling: drop-trailing-slash` serves the companion `.html` files at clean paths. `run_worker_first` sends only `/download` and `/release.json` to `src/worker.js`; every other path is a static asset.

Visitor requests read shared KV or deploy-time static snapshots only: neither the Worker request handler nor the browser fetches GitHub release metadata. An hourly scheduled refresh independently reads the public Sparkle feeds (`updates/appcast.xml` and `updates/appcast-beta.xml`), then each release's own `release-metadata.json` and `release-notes.md`. A snapshot is written only if the tag, version, build, channel, notarized DMG and paired notes agree. Each upstream fetch has an eight-second timeout (including body reads) and a 1 MiB body cap. A failure in either channel preserves that channel's last good snapshot without blocking refresh of the other. No GitHub API is used.

`/release.json` and `/download` default to stable, falling back to beta only when no stable snapshot exists. Explicit `?channel=stable` and `?channel=beta` are strict: they never fall back across channels and return **404** if that channel is unavailable; an unknown channel returns **400**. For each channel, KV takes precedence over a matching static snapshot. `public/release.json` remains a single default release object (not the KV envelope); optional `public/release-beta.json` provides a separate beta fallback after the default snapshot becomes stable. A static snapshot is used only for its actual channel, so a beta-only deployment returns 404 for explicit stable. A static stable snapshot also takes precedence over a cached beta for the default route.

`/download` is an uncached **302** to the resolved, immutable GitHub DMG, so download buttons stay same-origin and can carry the desired channel. GitHub still serves the binary and applies its own privacy policy; `/privacy` discloses that boundary. KV propagation and the JSON response's 60-second browser cache can briefly delay visibility after a refresh.

`app.js` fetches `/release.json` after load to update version, build, date, release notes and the Beta tag. The static markup is the no-JavaScript fallback.

Check all five production page routes, HTTPS/security headers, language switching, keyboard/mobile navigation, the demo, and `/download`'s 302 Location after deployment. A resolver may briefly cache the hostname's earlier negative DNS answer; authoritative/public DNS can resolve before local caches expire.

## Refresh the fallback snapshot

New releases reach `/download` and the page labels after the next successful hourly refresh without a deploy; run the seed script above to refresh immediately. Occasionally refresh `public/release.json` (and `public/release-beta.json` for the beta channel) so the no-JavaScript markup and the Worker's last-resort fallbacks stay recent: set channel, version, build, immutable download/source release URLs, ISO `publishedDate`, and `notes.en` / `notes.zh-Hans` text arrays for already-published, verified releases, then run:

```sh
python3 -I website/scripts/sync-release.py
python3 -I website/scripts/check.py --links
node website/scripts/test-demo.mjs
node website/scripts/test-worker.mjs
```

Website deployment is separate from the macOS release workflow; the Worker serves only releases already present in a published feed.
