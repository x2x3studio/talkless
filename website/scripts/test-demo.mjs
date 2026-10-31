// Model-free DOM harness for locale, demo, and download state transitions.
// Visual and layout checks still require a browser.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const publicDirectory = new URL('../public/', import.meta.url);
const source = await readFile(new URL('app.js', publicDirectory), 'utf8');
const en = JSON.parse(await readFile(new URL('locales/en.json', publicDirectory), 'utf8'));
const zh = JSON.parse(await readFile(new URL('locales/zh-Hans.json', publicDirectory), 'utf8'));
const release = JSON.parse(await readFile(new URL('release.json', publicDirectory), 'utf8'));

class Element {
  constructor(data = {}) { this.dataset = data; this.attributes = {}; this.children = []; this.value = ''; this.listeners = {}; this.disabled = true; }
  set textContent(value) { this.value = value; this.children = []; }
  get textContent() { return this.value + this.children.map(child => child.textContent).join(''); }
  setAttribute(name, value) { this.attributes[name] = value; }
  removeAttribute(name) { delete this.attributes[name]; }
  replaceChildren(...children) { this.value = ''; this.children = children; }
  append(...nodes) { this.children.push(...nodes); }
  addEventListener(name, listener) { this.listeners[name] = listener; }
  querySelector(selector) { return selector === 'strong' ? this.strong : this.children.find(child => child.className === selector.slice(1)); }
  focus() { this.focused = true; this.listeners.focus?.(); }
  after(node) { this.next = node; }
}

async function boot({ languages = ['en-US'], reduced = true, stored = null, search = '', failCatalog = null, page = 'home', blockedStorage = false, runtime = release, agent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15', touchPoints = 0 } = {}) {
  const elements = Object.fromEntries((page === 'home' ? ['#play-demo', '#demo-output', '#demo-transcript', '#dictation-pill', '#demo-announcement', '#release-version'] : ['#locale-announcement', '#release-version']).map(id => [id, new Element()]));
  if (page === 'home') elements['#play-demo'].strong = new Element();
  elements['#release-version'].textContent = release.version;
  const locales = ['en', 'zh-Hans'].map(locale => new Element({ locale }));
  const downloads = [new Element(), new Element()];
  downloads.forEach(link => { link.href = '/download'; });
  const notes = [new Element(), new Element()];
  notes.forEach(link => { link.href = '/updates'; });
  const siteLinks = [new Element(), new Element(), ...notes];
  siteLinks[0].href = '/guide#shortcuts';
  siteLinks[1].href = '/';
  const headingKey = page === 'home' ? 'hero.line1' : page === 'privacy' ? 'privacy.page.title' : `${page}.title`;
  const localized = [new Element({ i18n: headingKey })];
  const build = new Element();
  build.textContent = release.build;
  const published = new Element();
  published.textContent = release.publishedDate;
  const tags = [new Element(), new Element()];
  const changes = new Element();
  const created = [];
  const requests = [];
  const storage = new Map(stored ? [['talkless.website.language', stored]] : []);
  const document = {
    documentElement: { lang: 'en' },
    body: { dataset: { page }, children: [], append(node) { this.children.push(node); } },
    querySelector(selector) { return selector === '[data-release-changes]' ? (page === 'updates' ? changes : null) : elements[selector] ?? (selector.startsWith('meta[') ? new Element() : null); },
    querySelectorAll(selector) { return ({ '[data-locale]': locales, '.download-link': downloads, '[data-release-notes]': notes, '[data-site-link]': siteLinks, '[data-i18n]': [...localized, ...changes.children, ...created.filter(node => node.dataset.i18n)], '[data-i18n-aria]': created.filter(node => node.dataset.i18nAria), '[data-release-version]': [elements['#release-version']], '[data-release-build]': [build], '[data-release-date]': [published], '.download-link .button-tag': tags })[selector] || []; },
    createElement() { const node = new Element(); created.push(node); return node; },
    createTextNode(value) { const node = new Element(); node.textContent = value; return node; },
    addEventListener(name, listener) { this[name] = listener; },
  };
  const context = vm.createContext({
    document,
    window: { matchMedia: () => ({ matches: reduced }) },
    navigator: { languages, userAgent: agent, maxTouchPoints: touchPoints },
    location: { search, href: `https://typeless.x2x3.com/${search}` },
    history: { replaceState() {} },
    localStorage: { getItem: key => { if (blockedStorage) throw new Error('Storage blocked'); return storage.get(key); }, setItem: (key, value) => { if (blockedStorage) throw new Error('Storage blocked'); storage.set(key, value); } },
    URL, URLSearchParams, setTimeout: (callback) => setTimeout(callback, 0),
    fetch: async path => {
      requests.push(path);
      assert(path.startsWith('/locales/') || path === '/release.json', 'Only same-origin locale and release data may be fetched');
      if (path === '/release.json') return { ok: runtime !== null, json: async () => runtime };
      return { ok: !path.includes(failCatalog || 'never-match'), json: async () => path === '/locales/en.json' ? en : zh };
    },
  });
  await vm.runInContext(`(async () => { ${source}\n})();`, context, { filename: fileURLToPath(new URL('app.js', publicDirectory)) });
  await new Promise(resolve => setTimeout(resolve, 0));
  return { elements, locales, downloads, notes, document, context, requests, storage, siteLinks, localized, headingKey, build, published, tags, changes };
}

const basic = await boot();
assert.equal(basic.document.documentElement.lang, 'en');
assert.equal(basic.elements['#play-demo'].disabled, false);
assert.equal(basic.downloads[0].href, '/download');
assert.equal(basic.notes[0].href, '/updates?lang=en');
assert.equal(basic.elements['#release-version'].textContent, release.version);
await basic.elements['#play-demo'].listeners.click();
assert.equal(basic.elements['#demo-output'].textContent, en['demo.sentence']);
assert.equal(basic.elements['#demo-transcript'].textContent, en['demo.sentence']);
assert.equal(basic.elements['#dictation-pill'].dataset.state, 'done');
assert(basic.elements['#demo-transcript'].children.some(child => child.textContent === 'Talkless'));
basic.elements['#demo-output'].textContent = 'My own note';
basic.elements['#demo-output'].listeners.input();
await basic.elements['#play-demo'].listeners.click();
assert.equal(basic.elements['#demo-output'].textContent, 'My own note', 'Replay must keep edited text');
await basic.locales[1].listeners.click();
assert.equal(basic.document.documentElement.lang, 'zh-Hans');
assert.equal(basic.elements['#demo-output'].textContent, 'My own note', 'Locale switch must keep edited text');
assert.equal(basic.storage.get('talkless.website.language'), 'zh-Hans');

for (const [languages, expected] of [[['zh-CN'], 'zh-Hans'], [['zh-Hans-SG'], 'zh-Hans'], [['en-US', 'zh-CN'], 'en'], [['fr-FR', 'zh-SG'], 'zh-Hans'], [['zh-TW'], 'en']]) {
  const result = await boot({ languages });
  assert.equal(result.document.documentElement.lang, expected);
}
assert.equal((await boot({ stored: 'zh-Hans' })).document.documentElement.lang, 'zh-Hans');
assert.equal((await boot({ search: '?lang=en', stored: 'zh-Hans' })).document.documentElement.lang, 'en');
const failedChinese = await boot({ languages: ['zh-CN'], failCatalog: 'zh-Hans' });
assert.equal(failedChinese.document.documentElement.lang, 'en');
assert.match(failedChinese.elements['#demo-announcement'].textContent, /could not be loaded/);
// The Worker's /release.json advances labels and notes past the deploy-time snapshot.
const newer = { ...release, version: '2099.1231.86399', build: '4102444799', channel: 'stable', publishedDate: '2099-12-31',
  notes: { en: ['First runtime note.', 'Second runtime note.'], 'zh-Hans': ['\u7b2c\u4e00\u6761', '\u7b2c\u4e8c\u6761'] } };
const live = await boot({ page: 'updates', runtime: newer });
assert.equal(live.elements['#release-version'].textContent, newer.version);
assert.equal(live.build.textContent, newer.build);
assert.equal(live.published.textContent, newer.publishedDate);
assert.equal(live.published.attributes.datetime, newer.publishedDate);
assert(live.tags.every(tag => tag.hidden), 'Stable builds drop the Beta tag');
assert.deepEqual(live.changes.children.map(item => item.textContent), newer.notes.en);
await live.locales[1].listeners.click();
assert.deepEqual(live.changes.children.map(item => item.textContent), newer.notes['zh-Hans'], 'Runtime notes follow the language switch');
assert((await boot({ runtime: { ...newer, channel: 'beta' } })).tags.every(tag => tag.hidden === false), 'Beta builds keep the tag');
const offline = await boot({ page: 'updates', runtime: null });
assert.equal(offline.elements['#release-version'].textContent, release.version, 'Failed release fetch keeps the static snapshot');
assert.equal(offline.changes.children.length, 0);
assert.equal(live.document.title, zh['updates.meta.title']);
const stableHome = await boot({ runtime: newer });
const badge = new Element({ i18n: 'hero.badge' });
stableHome.localized.push(badge);
await stableHome.locales[1].listeners.click();
assert.equal(badge.textContent, zh['hero.badge.stable'], 'Stable releases swap beta copy for its stable variant');
const betaHome = await boot();
const betaBadge = new Element({ i18n: 'hero.badge' });
betaHome.localized.push(betaBadge);
await betaHome.locales[0].listeners.click();
assert.equal(betaBadge.textContent, en['hero.badge'], 'Beta releases keep beta copy');

// Device note: Macs see only the requirements line; phones, iPads and PCs are told before downloading.
assert(basic.downloads.every(link => !link.next), 'Mac visitors get no device note');
for (const [agent, touchPoints] of [['Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)', 5], ['Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', 5], ['Mozilla/5.0 (Windows NT 10.0; Win64; x64)', 0], ['Mozilla/5.0 (Linux; Android 15)', 5]]) {
  const other = await boot({ agent, touchPoints, languages: ['zh-CN'] });
  assert(other.downloads.every(link => link.next?.textContent === zh['download.otherDevice']), agent);
  assert.equal(other.downloads[0].href, '/download', 'The note never blocks downloading');
}

// Clicking download shows localized install steps without preventing navigation; Escape or close hides them.
const steps = await boot({ languages: ['zh-CN'] });
steps.downloads[0].listeners.click();
const panel = steps.document.body.children[0];
assert.equal(panel.hidden, false);
assert.equal(panel.children[1].textContent, zh['download.steps.title']);
assert.deepEqual(panel.children[2].children.map(step => step.textContent), [zh['download.steps.open'], zh['download.steps.drag'], zh['download.steps.launch']]);
assert.equal(panel.children[0].attributes['aria-label'], zh['download.steps.close']);
steps.document.keydown({ key: 'Escape' });
assert.equal(panel.hidden, true);
steps.downloads[1].listeners.click();
assert.equal(steps.document.body.children.length, 1, 'Steps panel is reused');
await steps.locales[0].listeners.click();
assert.equal(panel.children[1].textContent, en['download.steps.title'], 'Steps follow the language switch');
panel.children[0].listeners.click();
assert.equal(panel.hidden, true);

const malformed = await boot({ runtime: { ...newer, version: '<b>1</b>' } });
assert.equal(malformed.elements['#release-version'].textContent, release.version, 'Malformed runtime metadata is ignored');
for (const page of ['guide', 'privacy', 'updates', 'support']) {
  const local = await boot({ page, search: '?lang=zh-Hans', blockedStorage: true });
  assert.equal(local.document.documentElement.lang, 'zh-Hans');
  assert.equal(local.document.title, zh[`${page}.meta.title`]);
  assert.equal(local.localized[0].textContent, zh[local.headingKey]);
  assert.equal(local.siteLinks[0].href, '/guide?lang=zh-Hans#shortcuts');
  assert.equal(local.notes[0].href, '/updates?lang=zh-Hans');
  assert.equal(local.downloads[0].href, '/download');
  await local.locales[0].listeners.click();
  assert.equal(local.document.title, en[`${page}.meta.title`]);
  assert.equal(local.siteLinks[0].href, '/guide?lang=en#shortcuts');
  const failed = await boot({ page, languages: ['zh-CN'], failCatalog: 'zh-Hans' });
  assert.equal(failed.document.documentElement.lang, 'en');
  assert.match(failed.elements['#locale-announcement'].textContent, /could not be loaded/);
}

const animated = await boot({ reduced: false });
const pending = animated.elements['#play-demo'].listeners.click();
assert.equal(animated.elements['#dictation-pill'].dataset.state, 'recording');
animated.document.keydown({ key: 'Escape' });
await pending;
assert.equal(animated.elements['#dictation-pill'].dataset.state, 'idle');
assert.equal(animated.elements['#demo-output'].textContent, '', 'Escape must prevent insertion');
assert(basic.requests.every(path => path.startsWith('/locales/') || path === '/release.json'), 'Only same-origin data may be requested');
console.log('PASS: all companion page locales and metadata, cross-page language with blocked storage, same-origin /download, runtime release labels/notes with static fallback, stable copy variants, device notes, download steps, browser/stored/query selection, demo completion/cancellation, dictionary highlight, edit preservation and same-origin-only requests');
