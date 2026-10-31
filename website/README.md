# Talkless website

Public product page: https://typeless.x2x3.com. The product is **Talkless**; the hostname does not rename the app.

Cloudflare Worker `talkless-site` serves `public/` as static assets, following Mateo's static Worker deployment pattern. No build step, server-side application, database, analytics script, or microphone access. The demo is simulated; edited demo text stays in the browser.

## Preview and check

```sh
wrangler dev --config website/wrangler.jsonc --port 4173
python3 -I website/scripts/check.py --links
node website/scripts/test-demo.mjs
```

Use Wrangler for route checks: a plain Python file server does not emulate extensionless HTML or `_redirects`. Public routes are `/`, `/guide`, `/privacy`, `/updates`, `/support` and `/download`. The four companion pages are complete static English documents with bilingual content loaded from same-origin catalogs. JavaScript is not required for navigation, reading English or downloading.

Use the language toggle or `?lang=zh-Hans` / `?lang=en`. Selection follows query, stored preference, then the first supported browser language. Internal page links carry the active language so it survives navigation even with local storage blocked. Download links do not carry language parameters. Chinese JSON is Unicode-escaped to preserve repository source rules.

Each page has exactly one GitHub anchor, the repository entry in its header. Guide, privacy, support and release notes stay onsite; there are no visible GitHub blob, issue or release-tag links. Support explains how to reach Issues from that repository entry rather than pretending this static site has a report form. The demo never records audio or calls an AI service.

## Deploy

Requires an authenticated Wrangler CLI with access to the account and zone in `wrangler.jsonc`. Tested with Wrangler 4.154.0. Credentials stay outside the repository.

```sh
wrangler deploy --config website/wrangler.jsonc --dry-run
wrangler deploy --config website/wrangler.jsonc
```

The custom-domain route provisions `typeless.x2x3.com`; workers.dev and preview URLs are disabled. Deploy only `public/`, never the repository root. `_headers` applies a same-origin content security policy and disables microphone/camera permissions.

`html_handling: drop-trailing-slash` serves the companion `.html` files at clean paths. Static asset `_redirects` serves `/download` as a temporary **302** to the immutable, published GitHub DMG. This keeps every download button same-origin without a Worker script, GitHub API call or fragile `latest` URL. GitHub still serves the binary and applies its own privacy policy; `/privacy` discloses that boundary.

Check all five production page routes, HTTPS/security headers, language switching, keyboard/mobile navigation, the demo, and `/download`'s 302 Location after deployment. A resolver may briefly cache the hostname's earlier negative DNS answer; authoritative/public DNS can resolve before local caches expire.

## Refresh the download

Update `public/release.json` to an already-published, verified release. Set version, build, immutable download/source release URLs, ISO `publishedDate`, and corresponding `notes.en` / `notes.zh-Hans` text arrays. Keep notes about the shipped client, not pending work. Synchronize the redirect, both static version labels, publication date, English release notes and their locale keys, then validate:

```sh
python3 -I website/scripts/sync-release.py
python3 -I website/scripts/check.py --links
node website/scripts/test-demo.mjs
```

Deploy after those checks. Website deployment is separate from the macOS release workflow; this page never links to an unpublished client preview.
