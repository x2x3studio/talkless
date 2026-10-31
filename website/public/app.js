// The page is usable without JavaScript. All demo input is prerecorded text,
// not audio: no microphone, speech API, AI request, or third-party script.
const root = document.documentElement;
const localeButtons = [...document.querySelectorAll('[data-locale]')];
const playButton = document.querySelector('#play-demo');
const output = document.querySelector('#demo-output');
const transcript = document.querySelector('#demo-transcript');
const pill = document.querySelector('#dictation-pill');
const announcement = document.querySelector('#demo-announcement') || document.querySelector('#locale-announcement');
const page = document.body.dataset.page || 'home';
const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
const catalogs = new Map();
let currentLocale = 'en';
let catalog = {};
let localeRequest = 0;
let demoRun = 0;
let demoPlaying = false;
let noteEdited = false;
let runtimeNotes = null;
let releaseChannel = 'beta';

function preferredLocale(languages) {
  for (const language of languages) {
    if (/^en(?:-|$)/i.test(language)) return 'en';
    if (/^zh(?:-Hans(?:-|$)|-(?:CN|SG)(?:-|$)|$)/i.test(language)) return 'zh-Hans';
  }
  return 'en';
}

function chosenLocale() {
  const queryLocale = new URLSearchParams(location.search).get('lang');
  if (['en', 'zh-Hans'].includes(queryLocale)) return queryLocale;
  try {
    const stored = localStorage.getItem('talkless.website.language');
    if (['en', 'zh-Hans'].includes(stored)) return stored;
  } catch { /* Language selection also works when local storage is disabled. */ }
  return preferredLocale(navigator.languages || [navigator.language || 'en']);
}

function text(key) {
  const note = key.match(/^release\.note\.(\d+)$/);
  if (note && runtimeNotes) return runtimeNotes[currentLocale]?.[note[1]] || runtimeNotes.en[note[1]] || key;
  // Copy that mentions the beta has a ".stable" variant used once a stable release is current.
  if (releaseChannel === 'stable' && (catalog[`${key}.stable`] || catalogs.get('en')?.[`${key}.stable`])) key = `${key}.stable`;
  return catalog[key] || catalogs.get('en')?.[key] || key;
}

function renderText() {
  const metaPrefix = page === 'home' ? 'meta' : `${page}.meta`;
  document.title = text(`${metaPrefix}.title`);
  document.querySelector('meta[name="description"]').content = text(`${metaPrefix}.description`);
  document.querySelector('meta[property="og:title"]').content = text(`${metaPrefix}.title`);
  document.querySelector('meta[property="og:description"]').content = text(`${metaPrefix}.description`);
  for (const element of document.querySelectorAll('[data-i18n]')) {
    element.textContent = text(element.dataset.i18n);
  }
  for (const element of document.querySelectorAll('[data-i18n-aria]')) {
    element.setAttribute('aria-label', text(element.dataset.i18nAria));
  }
}

async function loadCatalog(locale) {
  if (catalogs.has(locale)) return catalogs.get(locale);
  const response = await fetch(`/locales/${locale}.json`);
  if (!response.ok) throw new Error('Language file unavailable');
  const strings = await response.json();
  catalogs.set(locale, strings);
  return strings;
}

function stopDemo() {
  demoRun += 1;
  demoPlaying = false;
  playButton?.removeAttribute('aria-disabled');
  if (pill) pill.dataset.state = 'idle';
}

async function setLocale(locale, remember = false) {
  const request = ++localeRequest;
  try {
    const strings = await loadCatalog(locale);
    if (request !== localeRequest) return;
    stopDemo();
    currentLocale = locale;
    catalog = strings;
    if (playButton) playButton.disabled = false;
    root.lang = locale;
    // Carry language through navigation even when browser storage is blocked.
    for (const link of document.querySelectorAll('[data-site-link]')) {
      const url = new URL(link.href, location.href);
      url.searchParams.set('lang', locale);
      link.href = `${url.pathname}${url.search}${url.hash}`;
    }
    renderText();
    for (const button of localeButtons) button.setAttribute('aria-pressed', String(button.dataset.locale === locale));
    if (output && !noteEdited) resetNote();
    announcement.textContent = '';
    if (remember) {
      try { localStorage.setItem('talkless.website.language', locale); } catch { /* Optional preference only. */ }
      const url = new URL(location.href);
      url.searchParams.set('lang', locale);
      history.replaceState(null, '', url);
    }
  } catch {
    // Keep the complete English document when a locale cannot be loaded.
    announcement.textContent = locale === 'en' ? 'Language unavailable. Please try again.' : 'Chinese could not be loaded. Please try again.';
  }
}

function resetNote() {
  const placeholder = document.createElement('span');
  placeholder.className = 'note-placeholder';
  placeholder.dataset.i18n = 'demo.placeholder';
  placeholder.textContent = text('demo.placeholder');
  output.replaceChildren(placeholder);
}

function showTranscript(value) {
  // A highlighted name means only that this confirmed spelling is present.
  const pieces = value.split('Talkless');
  transcript.replaceChildren();
  pieces.forEach((piece, index) => {
    if (index) {
      const match = document.createElement('mark');
      match.textContent = 'Talkless';
      transcript.append(match);
    }
    transcript.append(document.createTextNode(piece));
  });
}

const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

async function playDemo() {
  if (demoPlaying) return;
  // Never overwrite a note the visitor is editing; they may clear it to replay.
  if (noteEdited && output.textContent.trim()) {
    announcement.textContent = text('demo.keepNote');
    output.focus();
    return;
  }
  noteEdited = false;
  const run = ++demoRun;
  demoPlaying = true;
  playButton.setAttribute('aria-disabled', 'true');
  const sentence = text('demo.sentence');
  output.replaceChildren();
  pill.dataset.state = 'recording';
  announcement.textContent = text('demo.started');
  const characters = [...sentence];
  if (reducedMotion.matches) {
    showTranscript(sentence);
  } else {
    for (let index = 1; index <= characters.length; index += 1) {
      if (run !== demoRun) return;
      showTranscript(characters.slice(0, index).join(''));
      await delay(currentLocale === 'zh-Hans' ? 55 : 29);
    }
  }
  if (run !== demoRun) return;
  // Keep the transcript visible through recognition, with only the icon changing.
  pill.dataset.state = 'processing';
  await delay(reducedMotion.matches ? 0 : 700);
  if (run !== demoRun) return;
  output.textContent = sentence;
  pill.dataset.state = 'done';
  demoPlaying = false;
  playButton.removeAttribute('aria-disabled');
  playButton.querySelector('strong').textContent = text('demo.replay');
  announcement.textContent = text('demo.finished');
}

localeButtons.forEach(button => button.addEventListener('click', () => setLocale(button.dataset.locale, true)));
playButton?.addEventListener('click', playDemo);
output?.addEventListener('focus', () => {
  if (output.querySelector('.note-placeholder')) output.replaceChildren();
});
output?.addEventListener('input', () => { stopDemo(); noteEdited = true; });
output?.addEventListener('blur', () => { if (!output.textContent.trim()) { noteEdited = false; resetNote(); } });
document.addEventListener('keydown', event => {
  if (event.key !== 'Escape') return;
  hideDownloadSteps();
  if (!demoPlaying) return;
  stopDemo();
  transcript.textContent = text('demo.idle');
  announcement.textContent = text('demo.cancelled');
});

// Static markup is the deploy-time snapshot and the no-JavaScript fallback. The Worker's
// /release.json follows the newest published build; /download already redirects to it.
async function applyRelease() {
  try {
    const response = await fetch('/release.json');
    if (!response.ok) return;
    const release = await response.json();
    if (!/^[0-9.]+$/.test(release.version) || !/^[0-9]+$/.test(release.build)
        || !/^\d{4}-\d{2}-\d{2}$/.test(release.publishedDate)) return;
    for (const element of document.querySelectorAll('[data-release-version]')) element.textContent = release.version;
    for (const element of document.querySelectorAll('[data-release-build]')) element.textContent = release.build;
    for (const element of document.querySelectorAll('[data-release-date]')) {
      element.textContent = release.publishedDate;
      element.setAttribute('datetime', release.publishedDate);
    }
    for (const tag of document.querySelectorAll('.download-link .button-tag')) tag.hidden = release.channel !== 'beta';
    if (release.channel === 'stable') releaseChannel = 'stable';
    const list = document.querySelector('[data-release-changes]');
    const notes = release.notes;
    if (list && Array.isArray(notes?.en) && notes.en.length && notes['zh-Hans']?.length === notes.en.length) {
      runtimeNotes = notes;
      list.replaceChildren(...notes.en.map((_, index) => {
        const item = document.createElement('li');
        item.dataset.i18n = `release.note.${index}`;
        item.textContent = text(item.dataset.i18n);
        return item;
      }));
    }
    renderText();
  } catch { /* Keep the static release snapshot. */ }
}

// Talkless is a macOS app: say so before a phone, tablet or PC visitor downloads a DMG.
// Browsers cannot reliably tell Intel from Apple silicon Macs, so Macs see the requirements line only.
function isOtherDevice() {
  const agent = navigator.userAgent || '';
  const touchMac = /Macintosh/.test(agent) && navigator.maxTouchPoints > 1; // iPadOS requests desktop sites.
  return Boolean(navigator.userAgentData?.mobile) || /iPhone|iPad|iPod|Android/i.test(agent) || touchMac || !/Macintosh|Mac OS X/.test(agent);
}

let downloadSteps = null;

function showDownloadSteps() {
  if (!downloadSteps) {
    downloadSteps = document.createElement('aside');
    downloadSteps.className = 'download-steps';
    downloadSteps.setAttribute('role', 'status');
    const title = document.createElement('p');
    title.className = 'download-steps-title';
    title.dataset.i18n = 'download.steps.title';
    const list = document.createElement('ol');
    for (const key of ['download.steps.open', 'download.steps.drag', 'download.steps.launch']) {
      const step = document.createElement('li');
      step.dataset.i18n = key;
      list.append(step);
    }
    const close = document.createElement('button');
    close.type = 'button';
    close.className = 'download-steps-close';
    close.dataset.i18nAria = 'download.steps.close';
    close.textContent = '\u00d7';
    close.addEventListener('click', hideDownloadSteps);
    downloadSteps.append(close, title, list);
    document.body.append(downloadSteps);
    // Localize the new nodes immediately: the catalogs are already loaded.
    title.textContent = text('download.steps.title');
    for (const step of list.children) step.textContent = text(step.dataset.i18n);
    close.setAttribute('aria-label', text('download.steps.close'));
  }
  downloadSteps.hidden = false;
}

function hideDownloadSteps() {
  if (downloadSteps) downloadSteps.hidden = true;
}

function setupDownloads() {
  const otherDevice = isOtherDevice();
  for (const link of document.querySelectorAll('.download-link')) {
    // Never block the download; the browser follows /download as usual.
    link.addEventListener('click', showDownloadSteps);
    if (otherDevice) {
      const note = document.createElement('p');
      note.className = 'download-device-note';
      note.dataset.i18n = 'download.otherDevice';
      link.after(note);
    }
  }
}

setupDownloads();
await loadCatalog('en').then(strings => { catalog = strings; }).catch(() => {});
await setLocale(chosenLocale());
await applyRelease();
