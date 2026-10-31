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
  append(child) { this.children.push(child); }
  addEventListener(name, listener) { this.listeners[name] = listener; }
  querySelector(selector) { return selector === 'strong' ? this.strong : this.children.find(child => child.className === selector.slice(1)); }
  focus() { this.focused = true; this.listeners.focus?.(); }
}

async function boot({ languages = ['en-US'], reduced = true, stored = null, search = '', failCatalog = null, page = 'home', blockedStorage = false } = {}) {
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
  const requests = [];
  const storage = new Map(stored ? [['talkless.website.language', stored]] : []);
  const document = {
    documentElement: { lang: 'en' },
    body: { dataset: { page } },
    querySelector(selector) { return elements[selector] ?? (selector.startsWith('meta[') ? new Element() : null); },
    querySelectorAll(selector) { return ({ '[data-locale]': locales, '.download-link': downloads, '[data-release-notes]': notes, '[data-site-link]': siteLinks, '[data-i18n]': localized, '[data-release-version]': [elements['#release-version']] })[selector] || []; },
    createElement() { return new Element(); },
    createTextNode(value) { const node = new Element(); node.textContent = value; return node; },
    addEventListener(name, listener) { this[name] = listener; },
  };
  const context = vm.createContext({
    document,
    window: { matchMedia: () => ({ matches: reduced }) },
    navigator: { languages },
    location: { search, href: `https://typeless.x2x3.com/${search}` },
    history: { replaceState() {} },
    localStorage: { getItem: key => { if (blockedStorage) throw new Error('Storage blocked'); return storage.get(key); }, setItem: (key, value) => { if (blockedStorage) throw new Error('Storage blocked'); storage.set(key, value); } },
    URL, URLSearchParams, setTimeout: (callback) => setTimeout(callback, 0),
    fetch: async path => {
      requests.push(path);
      assert(path.startsWith('/locales/'), 'Only locale catalogs may be fetched');
      return { ok: !path.includes(failCatalog || 'never-match'), json: async () => path === '/locales/en.json' ? en : zh };
    },
  });
  await vm.runInContext(`(async () => { ${source}\n})();`, context, { filename: fileURLToPath(new URL('app.js', publicDirectory)) });
  await new Promise(resolve => setTimeout(resolve, 0));
  return { elements, locales, downloads, notes, document, context, requests, storage, siteLinks, localized, headingKey };
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
assert(!source.includes("fetch('/release.json')"), 'Release notes and version remain deployment-synchronized, not runtime-rewritten');
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
assert(basic.requests.every(path => path.startsWith('/locales/')), 'Only local language data may be requested');
console.log('PASS: all companion page locales and metadata, cross-page language with blocked storage, static downloads, browser/stored/query selection, demo completion/cancellation, dictionary highlight, edit preservation and same-origin-only requests');
