# Talkless website

Public product page: https://typeless.x2x3.com. The product is **Talkless**; the hostname does not rename the app.

Cloudflare Worker `talkless-site` serves `public/` as static assets, following Mateo's static Worker deployment pattern. A small script (`src/worker.js`) handles only `/download` and `/release.json`. No build step, database, analytics script, or microphone access. The demo is simulated; edited demo text stays in the browser.

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

```sh
wrangler deploy --config website/wrangler.jsonc --dry-run
wrangler deploy --config website/wrangler.jsonc
```

The custom-domain route provisions `typeless.x2x3.com`; workers.dev and preview URLs are disabled. Deploy only `public/`, never the repository root. `_headers` applies a same-origin content security policy and disables microphone/camera permissions.

`html_handling: drop-trailing-slash` serves the companion `.html` files at clean paths. `run_worker_first` sends only `/download` and `/release.json` to `src/worker.js`; every other path is a static asset.

The Worker reads the public Sparkle feeds (`updates/appcast.xml`, then `updates/appcast-beta.xml`), so a published stable release takes precedence over betas. It then reads that release's own `release-metadata.json` and `release-notes.md`, and serves the result only if the tag, version, build, channel and notarized DMG all agree. It does not call the GitHub API, so no API rate limit applies. Results are cached at the edge for five minutes and kept for a week as the last good answer. If upstream fails and no cached answer exists, it serves the deploy-time `public/release.json` snapshot. `/download` is an uncached **302** to the resolved, immutable GitHub DMG, so every download button stays same-origin. GitHub still serves the binary and applies its own privacy policy; `/privacy` discloses that boundary.

`app.js` fetches `/release.json` after load to update version, build, date, release notes and the Beta tag. The static markup is the no-JavaScript fallback.

Check all five production page routes, HTTPS/security headers, language switching, keyboard/mobile navigation, the demo, and `/download`'s 302 Location after deployment. A resolver may briefly cache the hostname's earlier negative DNS answer; authoritative/public DNS can resolve before local caches expire.

## Refresh the fallback snapshot

New releases reach `/download` and the page labels within about five minutes without a deploy. Occasionally refresh `public/release.json` so the no-JavaScript markup and the Worker's last-resort fallback stay recent: set version, build, immutable download/source release URLs, ISO `publishedDate`, and `notes.en` / `notes.zh-Hans` text arrays for an already-published, verified release, then run:

```sh
python3 -I website/scripts/sync-release.py
python3 -I website/scripts/check.py --links
node website/scripts/test-demo.mjs
node website/scripts/test-worker.mjs
```

Website deployment is separate from the macOS release workflow; the Worker serves only releases already present in a published feed.
