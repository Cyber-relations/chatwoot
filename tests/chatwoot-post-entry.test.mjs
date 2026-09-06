import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const entryPath = path.join(root, 'overlay/app/public/brand-assets/toybaco-post-entry.js');
const original = fs.readFileSync(entryPath, 'utf8');
const instrumented = original.replace(
  /\n\}\)\(\);\s*$/,
  '\nwindow.__TOYBACO_POST_ENTRY_TEST__ = { buildSrc: buildSrc, validatePath: validatePath, postOrigin: POST_ORIGIN, postizLogoutUrl: postizLogoutUrl, installLogoutBridge: installLogoutBridge, findMenu: findMenu, placeEntry: placeEntry, inject: inject, openPanel: openPanel, closePanel: closePanel, hideStockNav: hideStockNav, start: start, afterNavChange: afterNavChange, primaryNavList: primaryNavList, rowLooksStock: rowLooksStock, annotateCannedLabels: annotateCannedLabels, hideCaptainWord: hideCaptainWord, CANNED_NAMES: CANNED_NAMES, isComposeTarget: isComposeTarget, cannedQueryFromText: cannedQueryFromText, filterCannedItems: filterCannedItems, cannedResponsesUrl: cannedResponsesUrl, normalizeCannedRecords: normalizeCannedRecords, prefetchCannedResponses: prefetchCannedResponses, openCannedSlash: openCannedSlash, closeCannedSlash: closeCannedSlash, onComposeSlashKeydown: onComposeSlashKeydown, onComposeSlashInput: onComposeSlashInput, insertCannedIntoComposer: insertCannedIntoComposer, pickCannedItem: pickCannedItem, readSessionHeaders: readSessionHeaders, cannedFetchHeaders: cannedFetchHeaders, normalizeAiMode: normalizeAiMode, aiModeLabel: aiModeLabel, aiModeUrl: aiModeUrl, applyAiMode: applyAiMode, prefetchAiMode: prefetchAiMode, saveAiMode: saveAiMode, ensureComposerAiBar: ensureComposerAiBar, openAiModePanel: openAiModePanel, closeAiModePanel: closeAiModePanel, currentAiMode: currentAiMode };\n})();\n'
);
assert.notEqual(instrumented, original, 'test instrumentation anchor was not found');

function loadEntry(postUrl, globalConfig = {}) {
  const registered = [];
  const window = {
    TOYBACO_POST_URL: postUrl,
    globalConfig,
    location: {
      hash: '',
      pathname: '/app/accounts/1/inbox',
      protocol: typeof postUrl === 'string' && postUrl.startsWith('http:') ? 'http:' : 'https:',
    },
    addEventListener() {},
  };
  const document = {
    readyState: 'loading',
    addEventListener(name) { registered.push(name); },
  };
  const sandbox = {
    window,
    document,
    URL,
    URLSearchParams,
    sessionStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  };
  vm.runInNewContext(instrumented, sandbox, { filename: entryPath });
  return { api: window.__TOYBACO_POST_ENTRY_TEST__, registered, window, document };
}

function makeRow(name) {
  const row = { name, parentElement: null };
  Object.defineProperties(row, {
    previousElementSibling: {
      get() {
        if (!row.parentElement) return null;
        const index = row.parentElement.children.indexOf(row);
        return index > 0 ? row.parentElement.children[index - 1] : null;
      },
    },
    nextSibling: {
      get() {
        if (!row.parentElement) return null;
        const index = row.parentElement.children.indexOf(row);
        return index >= 0 ? (row.parentElement.children[index + 1] || null) : null;
      },
    },
  });
  return row;
}

function makeList(rows) {
  const ul = {
    children: [...rows],
    insertCalls: 0,
    insertBefore(node, reference) {
      this.insertCalls += 1;
      if (node.parentElement) {
        const previous = node.parentElement.children.indexOf(node);
        if (previous >= 0) node.parentElement.children.splice(previous, 1);
      }
      const index = reference === null ? this.children.length : this.children.indexOf(reference);
      assert.notEqual(index, -1, 'reference row must belong to the destination menu');
      this.children.splice(index, 0, node);
      node.parentElement = this;
    },
  };
  rows.forEach((row) => { row.parentElement = ul; });
  return ul;
}

for (const origin of [
  'https://post.toybaco.jp',
  'https://post.staging.toybaco.jp',
  'https://postiz-dev.toybaco.jp',
  'http://localhost:5000',
  'http://post.toybaco.localhost:4007',
]) {
  const { api, registered, window } = loadEntry(origin);
  assert.ok(api, `${origin} was rejected`);
  assert.equal(api.postOrigin, origin);
  assert.deepEqual(registered, ['keydown', 'input', 'click', 'DOMContentLoaded']);
  const src = new URL(api.buildSrc('/analytics?range=30'));
  assert.equal(src.origin, origin);
  assert.equal(src.pathname, '/toybaco/entry');
  assert.equal(src.searchParams.get('tb_embed'), '1');
  assert.equal(src.searchParams.get('return'), '/analytics?range=30&tb_embed=1');
  assert.equal(api.postizLogoutUrl(), `${origin}/auth/logout`);
  assert.equal(window.globalConfig.LOGOUT_REDIRECT_LINK, `${origin}/auth/logout`);
}

for (const value of [
  undefined,
  '',
  ' https://post.toybaco.jp',
  'http://post.toybaco.jp',
  'https://post.toybaco.jp:444',
  'https://evil.example',
  'https://post.toybaco.jp/path',
  'https://user:secret@post.toybaco.jp',
]) {
  const unchangedConfig = { LOGOUT_REDIRECT_LINK: '/app/login' };
  const { api, registered, window } = loadEntry(value, unchangedConfig);
  assert.equal(api, undefined, `unsafe origin was accepted: ${String(value)}`);
  assert.deepEqual(registered, []);
  assert.equal(window.__TOYBACO_POST_ENTRY_LOADED__, undefined);
  assert.equal(unchangedConfig.LOGOUT_REDIRECT_LINK, '/app/login');
}

const late = loadEntry('https://post.staging.toybaco.jp', null);
assert.ok(late.api, 'late globalConfig fixture was rejected');
late.window.globalConfig = {};
assert.equal(late.api.installLogoutBridge(), true);
assert.equal(
  late.window.globalConfig.LOGOUT_REDIRECT_LINK,
  'https://post.staging.toybaco.jp/auth/logout'
);

const { api } = loadEntry('https://post.staging.toybaco.jp');
assert.equal(api.validatePath('//evil.example'), '/launches');
assert.equal(api.validatePath('/oauth'), '/launches');
assert.equal(api.validatePath('/launches/../oauth'), '/launches');
assert.equal(api.validatePath('/media?folder=images'), '/media?folder=images');
assert.equal(api.validatePath('/settings/templates'), '/launches');
assert.equal(api.validatePath('/settings/templates/x'), '/launches');

const menuFixture = loadEntry('https://post.staging.toybaco.jp');
const postingFirst = makeRow('posting');
const inbox = makeRow('inbox');
const conversations = makeRow('conversations');
const primaryList = makeList([postingFirst, inbox, conversations]);
const inboxInner = {};
inbox.querySelector = (selector) => {
  assert.equal(selector, 'a, [role="button"]');
  return inboxInner;
};
primaryList.querySelector = (selector) => {
  assert.equal(selector, ':scope > li:not([data-toybaco-post-entry-wrap])');
  return inbox;
};
const nav = {
  querySelector(selector) {
    assert.equal(selector, 'ul');
    return primaryList;
  },
};
menuFixture.document.querySelectorAll = (selector) => {
  assert.equal(selector, 'nav');
  return [nav];
};
const menu = menuFixture.api.findMenu();
assert.equal(menu.li, inbox, 'posting row must not become the primary navigation sample');
menuFixture.api.placeEntry(menu, postingFirst);
assert.deepEqual(primaryList.children.map((row) => row.name), ['inbox', 'posting', 'conversations']);
assert.equal(primaryList.insertCalls, 1, 'posting-first drift must be repaired once');
menuFixture.api.placeEntry(menu, postingFirst);
assert.equal(primaryList.insertCalls, 1, 'repeated injection must not move an already-correct entry');

const stalePosting = makeRow('posting');
const staleList = makeList([stalePosting]);
const freshInbox = makeRow('fresh-inbox');
const freshOther = makeRow('fresh-other');
const freshList = makeList([freshInbox, freshOther]);
menuFixture.api.placeEntry({ ul: freshList, li: freshInbox }, stalePosting);
assert.deepEqual(staleList.children, [], 'entry must leave a stale Vue navigation list');
assert.deepEqual(freshList.children.map((row) => row.name), ['fresh-inbox', 'posting', 'fresh-other']);

assert.doesNotMatch(original, /var POST_ORIGIN\s*=\s*['"]https:\/\//);
assert.ok(
  original.includes(`      if (existing && existing.getAttribute('data-account') === id) {
        var existingWrap = existing.parentElement;
        if (existingWrap && existingWrap.getAttribute('data-' + MARK + '-wrap') === '1') {
          // Vueがナビ項目を差し替えても、主機能の位置を受信トレイ直後へ戻す。
          placeEntry(sample, existingWrap);
          ensurePostingContract();
          syncPostingSelection();
          return;
        }
      }`),
  'existing posting entry must return to the primary navigation position after Vue redraws'
);
assert.ok(
  original.includes(`      removePostEntry();
      var now = findMenu();
      if (!now) return;
      if (document.querySelector('[data-' + MARK + ']')) return;
      // 投稿は受信箱と並ぶ主機能。設定・請求項目の下へ埋もれないよう、
      // 最初のtop-level行（私の受信トレイ）の直後へ置く。
      placeEntry(now, buildEntry(now, id));`),
  'posting entry must be injected immediately after the primary inbox navigation row'
);
assert.doesNotMatch(
  original,
  /now\.ul\.appendChild\(buildEntry\(now, id\)\)/,
  'posting entry must not be appended below settings and billing navigation'
);

function matchesAttrSelector(node, raw) {
  const exact = raw.match(/^\[([^\]]+?)="([^"]*)"\]$/);
  if (exact) return node.getAttribute(exact[1]) === exact[2];
  const bare = raw.match(/^\[([^\]]+)\]$/);
  return bare ? node.getAttribute(bare[1]) !== null : false;
}

function matchesSimpleSelector(node, selector) {
  const parts = selector.split(',').map((part) => part.trim()).filter(Boolean);
  return parts.some((part) => {
    if (part === ':scope > li:not([data-toybaco-post-entry-wrap])') return false;
    if (part === 'aside nav > ul' || part === 'aside nav ul') return false;
    if (part.startsWith('[')) return matchesAttrSelector(node, part);
    const tagged = part.match(/^([A-Za-z0-9-]+)(.*)$/);
    if (!tagged) return false;
    if (node.tagName !== tagged[1].toUpperCase()) return false;
    return tagged[2] ? matchesAttrSelector(node, tagged[2]) : true;
  });
}

function queryNavList(root, selector) {
  if (selector !== 'aside nav' && selector !== 'aside nav > ul' && selector !== 'aside nav ul') return null;
  const asides = [root, ...(root.children || [])].filter((node) => node && node.tagName === 'ASIDE');
  const aside = asides[0] || walkQuery(root, 'aside', true);
  if (!aside) return null;
  const nav = walkQuery(aside, 'nav', true);
  if (selector === 'aside nav') return nav;
  return nav ? walkQuery(nav, 'ul', true) : null;
}

function walkQuery(root, selector, firstOnly) {
  const found = [];
  const visit = (node) => {
    if (selector === ':scope > li:not([data-toybaco-post-entry-wrap])') {
      if (
        node.tagName === 'LI' &&
        node.parentElement === root &&
        node.getAttribute('data-toybaco-post-entry-wrap') === null
      ) {
        found.push(node);
      }
      return;
    }
    if (matchesSimpleSelector(node, selector)) found.push(node);
    if (firstOnly && found.length) return;
    (node.children || []).forEach((child) => {
      if (firstOnly && found.length) return;
      visit(child);
    });
  };
  if (selector === ':scope > li:not([data-toybaco-post-entry-wrap])') {
    (root.children || []).forEach(visit);
  } else {
    (root.children || []).forEach(visit);
  }
  return firstOnly ? (found[0] || null) : found;
}

function createDomNode(tag) {
  const attrs = Object.create(null);
  const node = {
    tagName: String(tag).toUpperCase(),
    className: '',
    children: [],
    parentElement: null,
    textContent: '',
    href: '',
    title: '',
    type: '',
    name: tag,
    style: { cssText: '' },
    listeners: {},
    setAttribute(name, value) { attrs[name] = String(value); },
    getAttribute(name) {
      return Object.prototype.hasOwnProperty.call(attrs, name) ? attrs[name] : null;
    },
    removeAttribute(name) { delete attrs[name]; },
    appendChild(child) {
      if (child.parentElement) child.parentElement.removeChild(child);
      this.children.push(child);
      child.parentElement = this;
      return child;
    },
    insertBefore(child, reference) {
      if (child.parentElement) child.parentElement.removeChild(child);
      const index = reference == null ? this.children.length : this.children.indexOf(reference);
      assert.notEqual(index, -1, 'insertBefore reference must belong to the parent');
      this.children.splice(index, 0, child);
      child.parentElement = this;
      return child;
    },
    removeChild(child) {
      const index = this.children.indexOf(child);
      if (index >= 0) this.children.splice(index, 1);
      child.parentElement = null;
      return child;
    },
    remove() {
      if (this.parentElement) this.parentElement.removeChild(this);
    },
    addEventListener(type, fn) {
      this.listeners[type] = this.listeners[type] || [];
      this.listeners[type].push(fn);
    },
    nodeType: 1,
    get childNodes() {
      if (node.children.length) return node.children;
      if (node.textContent) return [{ nodeType: 3, textContent: node.textContent }];
      return [];
    },
    querySelector(selector) { return queryNavList(this, selector) || walkQuery(this, selector, true); },
    querySelectorAll(selector) { return walkQuery(this, selector, false); },
    closest(selector) {
      let current = this;
      while (current) {
        if (matchesSimpleSelector(current, selector)) return current;
        current = current.parentElement;
      }
      return null;
    },
    getBoundingClientRect() { return { width: 220, right: 220, left: 0, top: 0, bottom: 0 }; },
  };
  Object.defineProperties(node, {
    parentNode: { get() { return node.parentElement; } },
    firstChild: { get() { return node.children[0] || null; } },
    previousElementSibling: {
      get() {
        if (!node.parentElement) return null;
        const index = node.parentElement.children.indexOf(node);
        return index > 0 ? node.parentElement.children[index - 1] : null;
      },
    },
    nextSibling: {
      get() {
        if (!node.parentElement) return null;
        const index = node.parentElement.children.indexOf(node);
        return index >= 0 ? (node.parentElement.children[index + 1] || null) : null;
      },
    },
    nextElementSibling: {
      get() {
        if (!node.parentElement) return null;
        const index = node.parentElement.children.indexOf(node);
        return index >= 0 ? (node.parentElement.children[index + 1] || null) : null;
      },
    },
    innerHTML: {
      get() { return node._innerHTML || node.textContent; },
      set(value) {
        node._innerHTML = String(value);
        node.textContent = String(value).replace(/<[^>]+>/g, '');
        node.children = [];
      },
    },
  });
  return node;
}

function createStockRow(title, icon, href) {
  const li = createDomNode('li');
  li.name = title;
  const a = createDomNode(href ? 'a' : 'div');
  a.setAttribute('title', title);
  a.title = title;
  if (href) {
    a.setAttribute('href', href);
    a.href = href;
  }
  a.setAttribute('role', 'button');
  const iconEl = createDomNode('span');
  iconEl.className = icon;
  a.appendChild(iconEl);
  const text = createDomNode('span');
  text.textContent = title;
  a.appendChild(text);
  li.appendChild(a);
  return li;
}

function createMenuTree(withStock = false) {
  const body = createDomNode('body');
  const main = createDomNode('main');
  const aside = createDomNode('aside');
  const nav = createDomNode('nav');
  const ul = createDomNode('ul');
  const content = createDomNode('div');
  content.name = 'main-content';
  const inbox = createStockRow('会話', 'i-lucide-inbox', '/app/accounts/1/inbox-view');
  inbox.name = 'inbox';
  ul.appendChild(inbox);
  const extra = [];
  if (withStock) {
    extra.push(createStockRow('連絡先', 'i-lucide-contact', '/app/accounts/1/contacts'));
    extra.push(createStockRow('キャンペーン', 'i-lucide-megaphone', '/app/accounts/1/campaigns'));
    extra.push(createStockRow('ヘルプセンター', 'i-lucide-library-big', '/app/accounts/1/portals'));
    extra.push(createStockRow('会話データ', 'i-lucide-messages-square', '/app/accounts/1/mentions'));
    extra.push(createStockRow('レポート', 'i-lucide-chart-spline', '/app/accounts/1/reports/overview'));
    extra.push(createStockRow('設定', 'i-lucide-bolt', '/app/accounts/1/settings/general'));
    extra.push(createStockRow('担当者', 'i-lucide-user', '/app/accounts/1/settings/agents'));
    extra.push(createStockRow('AIアシスタント', 'i-woot-captain', '/app/accounts/1/captain'));
    extra.forEach((row) => ul.appendChild(row));
  } else {
    const other = createDomNode('li');
    other.name = 'other';
    ul.appendChild(other);
  }
  nav.appendChild(ul);
  aside.appendChild(nav);
  main.appendChild(aside);
  main.appendChild(content);
  body.appendChild(main);
  return { body, main, aside, nav, ul, inbox, extra, content };
}

async function flush() {
  for (let i = 0; i < 30; i += 1) await Promise.resolve();
}

function loadInjectEntry(fetchImpl, pathname = '/app/accounts/1/inbox', options = {}) {
  const { body } = options.body
    ? { body: options.body }
    : createMenuTree(options.withStock);
  const fetches = [];
  const registered = [];
  const docListeners = {};
  const windowListeners = {};
  const window = {
    TOYBACO_POST_URL: 'https://post.staging.toybaco.jp',
    globalConfig: {},
    location: {
      hash: '',
      pathname,
      search: '',
      protocol: 'https:',
      origin: 'https://app.staging.toybaco.jp',
      href: `https://app.staging.toybaco.jp${pathname}`,
      replace(url) {
        this.replaced = String(url);
        this.pathname = String(url);
        this.href = `https://app.staging.toybaco.jp${url}`;
      },
    },
    addEventListener(name, fn) {
      (windowListeners[name] ||= []).push(fn);
    },
    removeEventListener(name, fn) {
      windowListeners[name] = (windowListeners[name] || []).filter((item) => item !== fn);
    },
    history: { pushState() {}, replaceState() {} },
    requestAnimationFrame(cb) { return globalThis.setTimeout(cb, 0); },
    setInterval() { return 0; },
    clearInterval() {},
    fetch(url, opts) {
      fetches.push({ url: String(url), opts });
      return fetchImpl(url, opts);
    },
  };
  const document = {
    readyState: 'loading',
    body,
    cookie: '',
    addEventListener(name, fn) {
      registered.push(name);
      if (typeof fn === 'function') {
        docListeners[name] = docListeners[name] || [];
        docListeners[name].push(fn);
      }
    },
    removeEventListener(name, fn) {
      const list = docListeners[name] || [];
      docListeners[name] = list.filter((item) => item !== fn);
    },
    createElement: createDomNode,
    execCommand() { return false; },
    querySelector(selector) {
      if (matchesSimpleSelector(body, selector)) return body;
      return queryNavList(body, selector) || body.querySelector(selector);
    },
    querySelectorAll(selector) {
      const hit = matchesSimpleSelector(body, selector) ? [body] : [];
      return hit.concat(body.querySelectorAll(selector));
    },
    documentElement: body,
  };
  const sandboxObservers = [];
  const sandbox = {
    window,
    document,
    URL,
    URLSearchParams,
    Promise,
    setTimeout(fn, ms) {
      if (options.setTimeout) return options.setTimeout(fn, ms);
      const id = globalThis.setTimeout(fn, ms);
      if (id && typeof id.unref === 'function') id.unref();
      return id;
    },
    clearTimeout: options.clearTimeout || clearTimeout,
    setInterval() { return 0; },
    clearInterval() {},
    fetch: window.fetch,
    sessionStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
    MutationObserver: class {
      constructor(cb) {
        this.cb = cb;
        sandboxObservers.push(this);
      }
      observe(root, opts) {
        this.root = root;
        this.opts = opts;
      }
      disconnect() {}
      fire() { this.cb(); }
    },
  };
  vm.runInNewContext(instrumented, sandbox, { filename: entryPath });
  return { api: window.__TOYBACO_POST_ENTRY_TEST__, fetches, window, document, body, observers: sandboxObservers, docListeners, windowListeners };
}

function postingEntry(document) {
  return document.querySelector('[data-toybaco-post-entry]');
}

function postingStatusFetches(env) {
  return env.fetches.filter((item) => String(item.url).includes('/toybaco/posting_status'));
}

function billingEntry(document) {
  return document.querySelector('[data-toybaco-billing-entry]');
}

function aiModeEntry(document) {
  return document.querySelector('[data-toybaco-ai-mode-entry]');
}

function collectText(node) {
  let out = node.textContent || '';
  for (const child of node.children || []) out += collectText(child);
  return out;
}

assert.ok(
  original.includes("fetch('/toybaco/posting_status?account_id=' + encodeURIComponent(accountId), {"),
  'sidebar posting status must use /toybaco/posting_status'
);
assert.ok(
  original.includes("credentials: 'same-origin'"),
  'posting_status must be same-origin'
);
assert.doesNotMatch(
  original,
  /fetch\('\/toybaco\/feature_access/,
  'posting_status must not use the feature_access alias'
);
assert.ok(
  original.includes('この会社の契約には投稿が含まれていません'),
  'denied panel must show a Japanese contract message'
);
assert.ok(
  original.includes('placeEntry(now, buildEntry(now, id));\n      reconcilePostingAccess(id);'),
  'posting entry must appear synchronously before posting_status returns'
);

{
  const pending = loadInjectEntry(() => new Promise(() => {}));
  pending.api.inject();
  assert.ok(postingEntry(pending.document), 'posting entry must appear before posting_status resolves');
  assert.ok(billingEntry(pending.document), 'billing entry must remain while posting_status is pending');
  assert.equal(postingStatusFetches(pending).length, 1);
  assert.match(postingStatusFetches(pending)[0].url, /\/toybaco\/posting_status\?account_id=1$/);
  assert.equal(postingStatusFetches(pending)[0].opts.credentials, 'same-origin');
}

{
  const denied = loadInjectEntry(async () => ({
    ok: true,
    json: async () => ({ enabled: false }),
  }));
  denied.api.inject();
  assert.ok(postingEntry(denied.document), 'posting entry must appear synchronously even when the company is not contracted');
  await flush();
  assert.equal(postingEntry(denied.document), null, 'enabled:false must remove the posting entry');
  assert.ok(billingEntry(denied.document), 'billing entry must remain after posting is hidden');
  denied.api.inject();
  assert.equal(postingEntry(denied.document), null, 'cached enabled:false must not re-inject the posting entry');
  assert.equal(postingStatusFetches(denied).length, 1, 'the same account_id must not refetch posting_status');
}

{
  const failed = loadInjectEntry(async () => { throw new Error('network'); });
  failed.api.inject();
  assert.ok(postingEntry(failed.document), 'posting entry must appear before a failed posting_status');
  await flush();
  assert.ok(postingEntry(failed.document), 'fetch failure must keep the posting entry');
  assert.ok(billingEntry(failed.document), 'billing entry must remain after a failed posting_status');
}

{
  const notOk = loadInjectEntry(async () => ({ ok: false, status: 500, json: async () => ({ enabled: false }) }));
  notOk.api.inject();
  await flush();
  assert.ok(postingEntry(notOk.document), 'non-200 posting_status must keep the posting entry');
}

{
  const broken = loadInjectEntry(async () => ({
    ok: true,
    json: async () => { throw new SyntaxError('broken'); },
  }));
  broken.api.inject();
  await flush();
  assert.ok(postingEntry(broken.document), 'broken JSON must keep the posting entry');
}

{
  const switched = loadInjectEntry(async (url) => {
    const id = String(url).split('account_id=')[1];
    return { ok: true, json: async () => ({ enabled: id !== '2' }) };
  });
  switched.api.inject();
  await flush();
  assert.ok(postingEntry(switched.document), 'enabled account must keep the posting entry');
  switched.window.location.pathname = '/app/accounts/2/inbox';
  switched.api.inject();
  assert.ok(postingEntry(switched.document), 'account switch must show posting until the new status returns');
  await flush();
  assert.equal(postingEntry(switched.document), null, 'enabled:false on the new account must hide posting');
  assert.equal(postingStatusFetches(switched).length, 2, 'account switch must fetch posting_status again');
  assert.match(postingStatusFetches(switched)[1].url, /account_id=2$/);
}

{
  const panelDenied = loadInjectEntry(async () => ({
    ok: true,
    json: async () => ({ enabled: false }),
  }));
  panelDenied.api.inject();
  panelDenied.api.openPanel('/launches', true);
  assert.ok(
    panelDenied.document.querySelector('iframe'),
    'unknown contract status must still open the posting iframe'
  );
  await flush();
  assert.equal(panelDenied.document.querySelector('iframe'), null, 'enabled:false must unload the Postiz iframe');
  assert.match(
    collectText(panelDenied.document.body),
    /この会社の契約には投稿が含まれていません/
  );
  assert.ok(
    panelDenied.document.querySelector('[data-toybaco-post-entry-panel]'),
    'denied message must stay in the closable panel'
  );
}

// A paid contract must update this tab's cached navigation without reloading its workspace.
function openBillingThroughUi(env) {
  fireClick(billingEntry(env.document), env.docListeners.click || []);
  assert.ok(env.document.querySelector('[data-toybaco-billing-panel]'));
}
function closeBillingThroughUi(env) {
  const panel = env.document.querySelector('[data-toybaco-billing-panel]');
  assert.ok(panel);
  fireClick(panel.querySelector('button'), env.docListeners.click || []);
  assert.equal(env.document.querySelector('[data-toybaco-billing-panel]'), null);
}
function statusResponse(enabled) { return { ok: true, status: 200, json: async () => ({ enabled }) }; }
{
  let allowed = false;
  const env = loadInjectEntry(async () => statusResponse(allowed));
  env.api.inject(); await flush();
  assert.equal(postingEntry(env.document), null);
  const unsaved = createDomNode('textarea');
  unsaved.value = '未保存の本文';
  unsaved.files = [{ name: 'owned.jpg', size: 71926 }];
  env.body.appendChild(unsaved);
  const selectedFiles = unsaved.files;
  openBillingThroughUi(env);
  allowed = true;
  closeBillingThroughUi(env);
  assert.equal(postingStatusFetches(env).length, 2, 'closing billing after payment must GET current eligibility once');
  assert.equal(postingEntry(env.document), null, 'previous denial stays while the paid eligibility GET is pending');
  await flush();
  assert.ok(postingEntry(env.document), 'the existing tab must expose posting after the server confirms paid eligibility');
  assert.equal(unsaved.parentElement, env.body);
  assert.equal(unsaved.value, '未保存の本文');
  assert.equal(unsaved.files, selectedFiles, 'local unsaved input references are not replaced (not a real composer/BU proof)');
  for (let i = 0; i < 5; i += 1) env.api.afterNavChange();
  assert.equal(postingStatusFetches(env).length, 2, 'ordinary redraws must not poll eligibility');
  assert.ok(postingStatusFetches(env).every(({ opts }) => !opts.method || opts.method === 'GET'));
  assert.ok(postingStatusFetches(env).every(({ opts }) => opts.credentials === 'same-origin'));
}
{
  let allowed = true;
  const env = loadInjectEntry(async () => statusResponse(allowed));
  env.api.inject(); await flush(); openBillingThroughUi(env);
  allowed = false;
  env.window.location.pathname = '/app/accounts/1/settings/agents';
  env.api.afterNavChange(); await flush();
  assert.equal(postingStatusFetches(env).length, 2, 'same-account native navigation closes billing and checks once');
  assert.equal(postingEntry(env.document), null, 'a confirmed revoked entitlement must remove the old entry');
}
{
  const pending = [];
  const env = loadInjectEntry((url) => String(url).includes('/toybaco/posting_status')
    ? new Promise((resolve) => pending.push(resolve))
    : Promise.resolve({ ok: true, json: async () => ({}) }));
  env.api.inject(); openBillingThroughUi(env); closeBillingThroughUi(env);
  assert.equal(pending.length, 2, 'billing close must supersede a pre-payment in-flight lookup');
  pending[1](statusResponse(true)); await flush();
  pending[0](statusResponse(false)); await flush();
  assert.ok(postingEntry(env.document), 'stale pre-payment denial must not overwrite the paid response');
}
{
  const pending = [];
  const env = loadInjectEntry((url) => String(url).includes('/toybaco/posting_status')
    ? new Promise((resolve) => pending.push(resolve))
    : Promise.resolve({ ok: true, json: async () => ({}) }));
  env.api.inject(); pending[0](statusResponse(false)); await flush();
  openBillingThroughUi(env); closeBillingThroughUi(env);
  openBillingThroughUi(env); closeBillingThroughUi(env);
  assert.equal(pending.length, 3, 'each completed billing visit has one bounded new lookup');
  pending[2](statusResponse(true)); await flush();
  pending[1](statusResponse(false)); await flush();
  assert.ok(postingEntry(env.document), 'a prior billing visit cannot overwrite the latest visit');
}
{
  const pending = [];
  const env = loadInjectEntry((url) => String(url).includes('/toybaco/posting_status')
    ? new Promise((resolve) => pending.push({ url: String(url), resolve }))
    : Promise.resolve({ ok: true, json: async () => ({}) }));
  env.api.inject(); pending[0].resolve(statusResponse(false)); await flush();
  openBillingThroughUi(env);
  env.window.location.pathname = '/app/accounts/2/inbox';
  env.api.afterNavChange();
  assert.equal(pending.length, 2, 'closing during a tenant switch must not refetch the previous tenant');
  assert.match(pending[1].url, /account_id=2$/);
  pending[1].resolve(statusResponse(false)); await flush();
  assert.equal(postingEntry(env.document), null);
}
{
  const pending = [];
  const env = loadInjectEntry((url) => String(url).includes('/toybaco/posting_status')
    ? new Promise((resolve) => pending.push(resolve))
    : Promise.resolve({ ok: true, json: async () => ({}) }));
  env.api.inject(); pending[0](statusResponse(false)); await flush();
  openBillingThroughUi(env); closeBillingThroughUi(env);
  env.window.location.pathname = '/app/logout'; env.api.afterNavChange();
  pending[1](statusResponse(true)); await flush();
  assert.equal(postingEntry(env.document), null, 'late success after logout cannot restore navigation');
  env.window.location.pathname = '/app/accounts/1/inbox'; env.api.afterNavChange();
  assert.equal(pending.length, 3, 'return after logout must not reuse the old session eligibility');
  pending[2](statusResponse(false)); await flush();
  assert.equal(postingEntry(env.document), null);
}
for (const failure of [
  () => Promise.reject(new Error('network')),
  async () => ({ ok: false, status: 500 }),
  async () => ({ ok: false, status: 401 }),
  async () => ({ ok: false, status: 403 }),
  async () => ({ ok: true, status: 200, json: async () => ({}) }),
  async () => ({ ok: true, status: 200, json: async () => ({ enabled: 'true' }) }),
  async () => ({ ok: true, status: 200, json: async () => { throw new SyntaxError('broken'); } }),
]) {
  let next = async () => statusResponse(false);
  const env = loadInjectEntry(() => next());
  env.api.inject(); await flush(); next = failure;
  openBillingThroughUi(env); closeBillingThroughUi(env); await flush();
  assert.equal(postingEntry(env.document), null, 'unverified billing refresh must not promote a known denial');
  env.api.inject(); assert.equal(postingStatusFetches(env).length, 2, 'failure must not trigger automatic retry');
  next = async () => statusResponse(true);
  openBillingThroughUi(env); closeBillingThroughUi(env); await flush();
  assert.ok(postingEntry(env.document), 'a later deliberate billing visit may confirm eligibility');
}
for (const status of [401, 403]) {
  let next = async () => statusResponse(true);
  const env = loadInjectEntry(() => next());
  env.api.inject(); await flush(); next = async () => ({ ok: false, status });
  openBillingThroughUi(env); closeBillingThroughUi(env); await flush();
  assert.equal(postingEntry(env.document), null, 'session/membership rejection cannot preserve an old allowed entry');
}

{
  const pending = [];
  const env = loadInjectEntry((url) => String(url).includes('/toybaco/posting_status')
    ? new Promise((resolve) => pending.push(resolve))
    : Promise.resolve({ ok: true, json: async () => ({}) }));
  env.api.inject(); pending[0](statusResponse(false)); await flush();
  openBillingThroughUi(env); closeBillingThroughUi(env);
  env.window.location.pathname = '/app/accounts/2/inbox'; env.api.afterNavChange();
  env.window.location.pathname = '/app/accounts/1/inbox'; env.api.afterNavChange();
  pending[1](statusResponse(true)); pending[2](statusResponse(true)); await flush();
  assert.equal(postingEntry(env.document), null, 'A→B→A must not revive an older request from either view');
  openBillingThroughUi(env); closeBillingThroughUi(env);
  pending[3](statusResponse(true)); await flush();
  assert.ok(postingEntry(env.document), 'only a current A lookup may restore the A entry');
}
{
  const timers = new Map(); let timerId = 0; let resolveLate; let count = 0;
  const env = loadInjectEntry((url) => {
    if (!String(url).includes('/toybaco/posting_status')) return Promise.resolve({ ok: true, json: async () => ({}) });
    count += 1;
    return count === 2 ? new Promise((resolve) => { resolveLate = resolve; }) : Promise.resolve(statusResponse(count > 2));
  }, '/app/accounts/1/inbox', {
    setTimeout(fn, ms) { const id = ++timerId; timers.set(id, { fn, ms }); return id; },
    clearTimeout(id) { timers.delete(id); },
  });
  env.api.inject(); await flush(); openBillingThroughUi(env); closeBillingThroughUi(env);
  const timeout = [...timers.values()].filter((t) => t.ms === 5000);
  assert.equal(timeout.length, 1);
  timeout[0].fn(); await flush();
  assert.equal(postingEntry(env.document), null, 'a timed-out contract lookup preserves a confirmed denial');
  resolveLate(statusResponse(true)); await flush();
  assert.equal(postingEntry(env.document), null, 'success after the deadline cannot overwrite timeout state');
  env.api.inject(); assert.equal(count, 2, 'timeout does not cause background polling');
  openBillingThroughUi(env); closeBillingThroughUi(env); await flush();
  assert.ok(postingEntry(env.document), 'next natural billing visit can retry after a timeout');
}

// Postiz control snapshot は brand CSS を含めない。
const brandCssPath = path.join(root, 'overlay/app/public/toybaco-brand.css');
if (fs.existsSync(brandCssPath)) {
  const brandCss = fs.readFileSync(brandCssPath, 'utf8');
  assert.match(brandCss, /\[title="レポート"\]/);
  assert.match(brandCss, /\[title="設定"\]/);
  assert.match(brandCss, /order: 4;/);
  assert.match(brandCss, /order: 5;/);
  assert.doesNotMatch(brandCss, /aside nav > ul > li ul\s*\{\s*display:\s*none\s*!important/,
    'native settings/report children must not be hidden by the blanket subtree rule');
  assert.match(brandCss, /li:not\(\[data-toybaco-primary-nav="settings"\]\):not\(\[data-toybaco-primary-nav="reports"\]\) ul/);
  assert.match(brandCss, /aside nav\s*\{\s*min-height:\s*0;/,
    'the native scrolling nav must be able to shrink above the sidebar footer');
  assert.match(brandCss, /aside nav > ul > li\[data-toybaco-nav-duplicate="1"\]\s*\{\s*display: none !important;/);
  assert.match(brandCss, /help\.chatwoot\.com/);
  assert.match(brandCss, /data-toybaco-canned-name/);
  assert.match(brandCss, /data-toybaco-slash-canned/);
  assert.match(brandCss, /data-toybaco-slash-item/);
  assert.match(brandCss, /data-toybaco-ai-mode-bar/);
  assert.match(brandCss, /data-toybaco-ai-mode-panel/);
  assert.doesNotMatch(brandCss, /data-toybaco-ai-mode-entry/);
  assert.match(brandCss, /#fcfbf8/);
  assert.match(brandCss, /captain-panel/);
  const whatsapp = fs.readFileSync(
    path.join(root, 'overlay/app/app/javascript/dashboard/i18n/locale/ja/whatsappTemplateMgmt.json'),
    'utf8'
  );
  assert.match(whatsapp, /"KNOW_MORE": ""/);
  assert.match(whatsapp, /"EMPTY": "テンプレートは見つかりませんでした。"/);
  assert.doesNotMatch(whatsapp, /WhatsApp テンプレートは見つかりませんでした/);
  assert.doesNotMatch(whatsapp, /WhatsApp 受信トレイから同期された/);
  assert.doesNotMatch(whatsapp, /詳細を見る/);
  const notFound = fs.readFileSync(path.join(root, 'overlay/app/public/404.html'), 'utf8');
  assert.match(notFound, /lang="ja"/);
  assert.match(notFound, /ページが見つかりません/);
  assert.match(notFound, /ホームへ戻る/);
  assert.doesNotMatch(notFound, /Page not found/);
  assert.doesNotMatch(notFound, /Back to home/);
  assert.doesNotMatch(notFound, /Chatwoot|Postiz|chatwoot|postiz/);
  assert.doesNotMatch(notFound, /#2781F6|#2781f6|rgb\(39, 129, 246\)/);
  const conversation = fs.readFileSync(
    path.join(root, 'overlay/app/app/javascript/dashboard/i18n/locale/ja/conversation.json'),
    'utf8'
  );
  assert.match(conversation, /"COPILOT_THINKING": "✦ AI が考え中"/);
  assert.match(conversation, /"COPILOT": "AI"/);
  assert.match(conversation, /"MSG_INPUT": "返信を入力\(\/ で定型文\)"/);
  assert.doesNotMatch(conversation, /Copilotが考え中/);
  const settingsJa = fs.readFileSync(
    path.join(root, 'overlay/app/app/javascript/dashboard/i18n/locale/ja/settings.json'),
    'utf8'
  );
  assert.match(settingsJa, /"CAPTAIN": "AIアシスタント"/);
  assert.match(settingsJa, /"CAPTAIN_AI": "AI"/);
  assert.match(settingsJa, /"REPORTS": "レポート"/);
  assert.match(settingsJa, /"SETTINGS": "設定"/);
}
assert.match(original, /INJECT_RETRY_MS/);
assert.match(original, /hideStockNav\(\)/);
assert.match(original, /annotateCannedLabels\(\)/);
assert.match(original, /hideCaptainWord\(\)/);
assert.match(original, /'yoyaku-uketsuke': '予約受付'/);
assert.match(original, /prefetchCannedResponses\(currentAccountId\(\)\)/);
assert.match(original, /prefetchAiMode\(currentAccountId\(\)\)/);
assert.match(original, /ensureComposerAiBar\(\)/);
assert.doesNotMatch(original, /injectAiMode\(/);
assert.match(original, /\/toybaco\/ai_reply_mode\?account_id=/);
assert.match(original, /AI_MODE_LABELS\[AI_MODE_AUTO\] = '全自動'/);
assert.match(original, /AI_MODE_LABELS\[AI_MODE_DRAFT\] = '下書き'/);
assert.doesNotMatch(original, /openCaptain|\/captain['"]/);
assert.match(original, /onComposeSlashKeydown/);
assert.match(original, /\/api\/v1\/accounts\/' \+ accountId \+ '\/canned_responses/);
assert.match(original, /openCannedSlash\(e\.target \|\| e\.srcElement, ''\)/);
assert.doesNotMatch(original, /cw_d_session_info=/);
assert.match(original, /requestAnimationFrame/);

{
  const packDir = path.join(root, 'overlay/app/toybaco-packs');
  if (fs.existsSync(packDir)) {
    const packNames = {};
    for (const file of fs.readdirSync(packDir).filter((name) => name.endsWith('.yaml'))) {
      const text = fs.readFileSync(path.join(packDir, file), 'utf8');
      const re = /short_code:\s*([a-z0-9-]+)\n\s*name:\s*(.+)/g;
      let match;
      while ((match = re.exec(text))) packNames[match[1]] = match[2].trim();
    }
    const jsNames = {};
    const block = original.slice(original.indexOf('var CANNED_NAMES = {'), original.indexOf('};', original.indexOf('var CANNED_NAMES = {')));
    const jsRe = /'([a-z0-9-]+)':\s*'([^']+)'/g;
    let jsMatch;
    while ((jsMatch = jsRe.exec(block))) jsNames[jsMatch[1]] = jsMatch[2];
    assert.deepEqual(jsNames, packNames, 'CANNED_NAMES must stay aligned with pack YAML names');
  }
}

{
  const sitePath = path.join(root, 'site/index.html');
  if (fs.existsSync(sitePath)) {
    const site = fs.readFileSync(sitePath, 'utf8');
    assert.match(site, /\.app\.night\{--ab:#121A26/);
    assert.match(site, /--af:#0F151E/);
    assert.match(site, /--al:#22304A/);
    assert.match(site, /--at:#D6E4F2/);
  }
}

{
  const env = loadInjectEntry(() => new Promise(() => {}), '/app/accounts/1/inbox');
  const code = createDomNode('b');
  code.textContent = '/yoyaku-uketsuke';
  env.body.appendChild(code);
  const preview = createDomNode('td');
  preview.textContent = 'お問い合わせありがとうございます。';
  env.body.appendChild(preview);
  const captain = createDomNode('span');
  captain.textContent = 'Captain';
  env.body.appendChild(captain);
  env.api.annotateCannedLabels();
  env.api.hideCaptainWord();
  assert.equal(code.children.length, 1);
  assert.equal(code.children[0].getAttribute('data-toybaco-canned-name'), '1');
  assert.equal(code.children[0].textContent, '予約受付');
  assert.equal(preview.children.length, 0, 'canned body preview must stay untouched');
  assert.equal(captain.textContent, 'AI');
}
assert.match(original, /pushState/);
assert.doesNotMatch(original, /pending = setTimeout\(function \(\) \{\s*pending = null;\s*inject\(\);/);
assert.doesNotMatch(original, /aria-label', '投稿を閉じる/);
assert.doesNotMatch(original, /position:fixed;top:0;bottom:0;right:0;left:/);
assert.match(original, /position:absolute;inset:0;z-index:1/);
assert.match(original, /isLoggedInView\(\) && !document\.querySelector\('\[data-' \+ MARK \+ '\]'\)/);

{
  const stocked = loadInjectEntry(() => new Promise(() => {}), '/app/accounts/1/inbox', { withStock: true });
  stocked.api.inject();
  assert.ok(postingEntry(stocked.document), '投稿 must inject beside stock Chatwoot rows');
  assert.ok(billingEntry(stocked.document), 'ご契約内容 must inject beside stock Chatwoot rows');
  assert.equal(aiModeEntry(stocked.document), null, 'AI応答 must not add a sixth left-nav item');
  const hidden = [...stocked.body.querySelectorAll('li')].filter(
    (row) => row.getAttribute('data-toybaco-stock-hidden') === '1'
  );
  assert.deepEqual(
    hidden.map((row) => row.name),
    ['連絡先', 'キャンペーン', 'ヘルプセンター', '会話データ', '担当者', 'AIアシスタント']
  );
  const visibleNames = [...stocked.body.querySelectorAll('li')]
    .filter((row) => row.getAttribute('data-toybaco-stock-hidden') !== '1')
    .map((row) => row.name);
  assert.ok(visibleNames.includes('inbox'), '会話 row must remain');
  assert.ok(visibleNames.includes('レポート'), 'レポート is canonical and must remain');
  assert.ok(visibleNames.includes('設定'), '設定 is canonical and must remain');
  const inboxRow = [...stocked.body.querySelectorAll('li')].find((row) => row.name === 'inbox');
  assert.ok(inboxRow, '会話 row must remain');
  assert.equal(inboxRow.getAttribute('data-toybaco-stock-hidden'), null);
  assert.equal(postingEntry(stocked.document).parentElement.getAttribute('data-toybaco-stock-hidden'), null);
}

{
  const settingsLanding = loadInjectEntry(
    () => new Promise(() => {}),
    '/app/accounts/1/settings/general',
    { withStock: true }
  );
  settingsLanding.api.inject();
  const hidden = [...settingsLanding.body.querySelectorAll('li')]
    .filter((row) => row.getAttribute('data-toybaco-stock-hidden') === '1')
    .map((row) => row.name);
  assert.ok(hidden.includes('キャンペーン'), 'settings landing must hide leftover キャンペーン');
  assert.ok(hidden.includes('ヘルプセンター'), 'settings landing must hide leftover ヘルプセンター');
  assert.ok(hidden.includes('会話データ'), 'settings landing must hide 会話データ');
  assert.ok(hidden.includes('担当者'), 'settings landing must hide settings inventory from the global rail');
  assert.ok(postingEntry(settingsLanding.document), '投稿 must stay on settings landings');
  assert.ok(billingEntry(settingsLanding.document), 'ご契約内容 must stay on settings landings');
  assert.ok(
    [...settingsLanding.body.querySelectorAll('li')].some(
      (row) => row.name === '設定' && row.getAttribute('data-toybaco-stock-hidden') !== '1'
    ),
    '設定 must remain in the product chrome on settings landings'
  );
}

{
  const remount = loadInjectEntry(() => new Promise(() => {}), '/app/accounts/1/inbox', { withStock: true });
  remount.api.inject();
  const posting = postingEntry(remount.document);
  const billing = billingEntry(remount.document);
  assert.ok(posting && billing);
  posting.parentElement.remove();
  billing.parentElement.remove();
  assert.equal(postingEntry(remount.document), null);
  remount.api.afterNavChange();
  assert.ok(postingEntry(remount.document), 'Vue wipe must be repaired without waiting for F5');
  assert.ok(billingEntry(remount.document), 'billing entry must return after Vue remount');
  assert.equal(aiModeEntry(remount.document), null, 'AI応答 must stay off the left nav after remount');
}

{
  const empty = createDomNode('body');
  const late = loadInjectEntry(() => new Promise(() => {}), '/app/accounts/1/inbox', { body: empty });
  late.api.start();
  assert.equal(postingEntry(late.document), null, '投稿 must not require a menu that has not mounted yet');
  const { aside } = createMenuTree(true);
  empty.appendChild(aside);
  late.api.afterNavChange();
  assert.ok(postingEntry(late.document), '投稿 must appear on first paint after Vue mounts the nav');
  assert.ok(billingEntry(late.document), 'ご契約内容 must appear on first paint after Vue mounts the nav');
  assert.equal(aiModeEntry(late.document), null, 'AI応答 must not join the left nav on first paint');
  const hidden = [...late.body.querySelectorAll('li')].filter(
    (row) => row.getAttribute('data-toybaco-stock-hidden') === '1'
  );
  assert.ok(hidden.some((row) => row.name === '連絡先'));
  assert.ok(hidden.some((row) => row.name === '会話データ'));
  assert.ok(hidden.some((row) => row.name === '担当者'));
  assert.ok([...late.body.querySelectorAll('li')].some((row) => row.name === '設定' && row.getAttribute('data-toybaco-stock-hidden') !== '1'));
  assert.ok([...late.body.querySelectorAll('li')].some((row) => row.name === 'レポート' && row.getAttribute('data-toybaco-stock-hidden') !== '1'));
}

{
  const observerCase = loadInjectEntry(() => new Promise(() => {}), '/app/login');
  observerCase.api.start();
  observerCase.window.location.pathname = '/app/accounts/1/inbox';
  const observer = observerCase.observers[0];
  assert.ok(observer, 'MutationObserver must watch for the first Chatwoot nav mount');
  observer.fire();
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.ok(postingEntry(observerCase.document), 'observer must inject after SPA route reaches /app/accounts/');
}

{
  const empty = createDomNode('body');
  const late = loadInjectEntry(() => new Promise(() => {}), '/app/accounts/1/inbox', { body: empty });
  late.api.start();
  assert.equal(postingEntry(late.document), null, 'first inject must tolerate an empty nav');
  const { aside } = createMenuTree(true);
  empty.appendChild(aside);
  late.observers[0].fire();
  assert.ok(postingEntry(late.document), 'observer must inject when nav appears after an empty first inject');
  assert.ok(billingEntry(late.document), 'billing must appear with posting after a late nav mount');
  assert.equal(aiModeEntry(late.document), null, 'AI応答 must not join the left nav after a late mount');
}

{
  const swapped = loadInjectEntry(() => new Promise(() => {}), '/app/accounts/1/inbox', { withStock: true });
  swapped.api.start();
  assert.ok(postingEntry(swapped.document), 'posting must exist before Vue replaces the ul');
  const nav = swapped.body.querySelector('nav');
  const oldUl = nav.querySelector('ul');
  const fresh = createDomNode('ul');
  const inbox = createStockRow('会話', 'i-lucide-inbox', '/app/accounts/1/inbox-view');
  inbox.name = 'inbox';
  fresh.appendChild(inbox);
  nav.removeChild(oldUl);
  nav.appendChild(fresh);
  assert.equal(postingEntry(swapped.document), null, 'Vue ul swap must drop the previous posting node');
  swapped.observers[0].fire();
  assert.ok(postingEntry(swapped.document), 'observer must restore posting after Vue replaces the ul');
  assert.equal(postingEntry(swapped.document).parentElement.parentElement, fresh);
}

{
  const headed = createMenuTree(true);
  const header = createDomNode('li');
  header.name = 'group-header';
  headed.ul.insertBefore(header, headed.ul.firstChild);
  const skipped = loadInjectEntry(() => new Promise(() => {}), '/app/accounts/1/inbox', { body: headed.body });
  skipped.api.inject();
  assert.ok(postingEntry(skipped.document), 'findMenu must skip a first row without a link');
  assert.equal(postingEntry(skipped.document).parentElement.previousElementSibling.name, 'inbox');
}

{
  const tab = loadInjectEntry(() => new Promise(() => {}));
  tab.api.inject();
  tab.api.openPanel('/launches', true);
  const panel = tab.document.querySelector('[data-toybaco-post-entry-panel]');
  assert.ok(panel, 'posting must open in the inbox main area');
  assert.doesNotMatch(panel.style.cssText, /position:\s*fixed/);
  assert.match(panel.style.cssText, /position:\s*absolute/);
  assert.equal(tab.document.querySelector('[aria-label="投稿を閉じる"]'), null, 'must not show an independent close chrome');
  assert.ok(panel.querySelector('iframe'), 'iframe contract must stay in the main-area host');
  assert.equal(panel.parentElement.name, 'main-content');
  assert.notEqual(panel.parentElement, tab.body);
  assert.match(postingEntry(tab.document).className, /bg-n-alpha-2/);
  (tab.docListeners.keydown || []).forEach((fn) => fn({ key: 'Escape' }));
  assert.equal(tab.document.querySelector('[data-toybaco-post-entry-panel]'), null, 'ESC must close the posting tab');
  assert.doesNotMatch(postingEntry(tab.document).className, /bg-n-alpha-2/);
}

{
  const tab = loadInjectEntry(() => new Promise(() => {}));
  tab.api.openPanel('/launches', false);
  const panel = tab.document.querySelector('[data-toybaco-post-entry-panel]');
  const frame = panel.querySelector('iframe');
  frame.contentWindow = {};
  const send = (data, overrides = {}) => {
    const event = { origin: 'https://post.staging.toybaco.jp', source: frame.contentWindow, data, ...overrides };
    [...(tab.windowListeners.message || [])].forEach((fn) => fn(event));
  };
  send({ type: 'TOYBACO_POSTIZ_READY' });
  assert.equal(tab.windowListeners.message.length, 1, 'the close bridge must remain after READY');
  const close = { type: 'TOYBACO_POSTIZ_CLOSE' };
  for (const overrides of [
    { origin: 'https://evil.example' },
    { origin: 'https://post.toybaco.jp' },
    { source: {} },
    { data: { type: 'toybaco_postiz_close' } },
    { data: 'TOYBACO_POSTIZ_CLOSE' },
    { data: null },
  ]) {
    send(close, overrides);
    assert.equal(tab.document.querySelector('[data-toybaco-post-entry-panel]'), panel, 'untrusted close messages cannot close the panel');
  }
  const oldHandler = tab.windowListeners.message[0];
  send(close);
  assert.equal(tab.document.querySelector('[data-toybaco-post-entry-panel]'), null, 'current iframe shell Escape must close the parent panel');
  assert.equal(tab.windowListeners.message.length, 0, 'closing must detach the bridge');
  tab.api.openPanel('/launches', false);
  const reopened = tab.document.querySelector('[data-toybaco-post-entry-panel]');
  oldHandler({ origin: 'https://post.staging.toybaco.jp', source: frame.contentWindow, data: close });
  assert.equal(tab.document.querySelector('[data-toybaco-post-entry-panel]'), reopened, 'a stale frame handler cannot close a reopened panel');
  for (const extra of [{ isComposing: true }, { keyCode: 229 }, { defaultPrevented: true }]) {
    (tab.docListeners.keydown || []).forEach((fn) => fn({ key: 'Escape', ...extra }));
    assert.equal(tab.document.querySelector('[data-toybaco-post-entry-panel]'), reopened, 'consumed or composing parent Escape cannot close the panel');
  }
  (tab.docListeners.keydown || []).forEach((fn) => fn({ key: 'Escape' }));
  assert.equal(tab.windowListeners.message.length, 0);
}

{
  const empty = createDomNode('body');
  const noHost = loadInjectEntry(() => new Promise(() => {}), '/app/accounts/1/inbox', { body: empty });
  noHost.api.openPanel('/launches', false);
  assert.equal(
    noHost.document.querySelector('[data-toybaco-post-entry-panel]'),
    null,
    'must not fall back to a body-fixed chrome panel'
  );
}

function fireClick(node, extraListeners = []) {
  const event = {
    target: node,
    prevented: false,
    stopped: false,
    preventDefault() { this.prevented = true; },
    stopPropagation() { this.stopped = true; },
    stopImmediatePropagation() { this.stopped = true; },
  };
  extraListeners.forEach((fn) => fn(event));
  if (!event.stopped) (node.listeners.click || []).forEach((fn) => fn(event));
  return event;
}

{
  const mix = loadInjectEntry(() => new Promise(() => {}));
  mix.api.start();
  const entry = postingEntry(mix.document);
  const billing = billingEntry(mix.document);
  assert.ok(entry && billing, '投稿 and ご契約内容 must both exist');
  assert.match(entry.getAttribute('href') || entry.href, /#\/toybaco\/posting\?path=%2Flaunches/);
  fireClick(entry, mix.docListeners.click || []);
  const panel = mix.document.querySelector('[data-toybaco-post-entry-panel]');
  assert.ok(panel, '投稿 must open the posting calendar tab');
  const iframe = panel.querySelector('iframe');
  assert.ok(iframe, '投稿 must mount the launches iframe');
  assert.match(String(iframe.src || ''), /return=%2Flaunches/);
  assert.equal(mix.document.querySelector('[data-toybaco-billing-panel]'), null, '投稿 must not open ご契約内容');
}

{
  const billed = loadInjectEntry(() => new Promise(() => {}));
  billed.api.start();
  fireClick(billingEntry(billed.document), billed.docListeners.click || []);
  assert.ok(billed.document.querySelector('[data-toybaco-billing-panel]'), 'ご契約内容 must stay on the billing entry');
  assert.equal(billed.document.querySelector('[data-toybaco-post-entry-panel]'), null, 'ご契約内容 must not open the calendar');
}

{
  const headed = createMenuTree(true);
  const templates = createStockRow('テンプレート', 'i-lucide-file-text', '/app/accounts/1/settings/templates');
  templates.name = 'templates';
  headed.ul.insertBefore(templates, headed.ul.firstChild);
  const skipped = loadInjectEntry(() => new Promise(() => {}), '/app/accounts/1/inbox', { body: headed.body });
  skipped.api.start();
  const entry = postingEntry(skipped.document);
  assert.ok(entry, 'findMenu must not treat settings/templates as the posting sample');
  assert.equal(entry.parentElement.previousElementSibling.name, 'inbox');
  assert.match(entry.getAttribute('href') || entry.href, /#\/toybaco\/posting\?path=%2Flaunches/);
  entry.setAttribute('href', '/app/accounts/1/settings/templates');
  entry.href = '/app/accounts/1/settings/templates';
  fireClick(entry, skipped.docListeners.click || []);
  const stolenPanel = skipped.document.querySelector('[data-toybaco-post-entry-panel]');
  assert.ok(stolenPanel, 'stolen settings/templates href must still open posting');
  const iframe = stolenPanel.querySelector('iframe');
  assert.ok(iframe, 'stolen settings/templates href must still mount the launches iframe');
  assert.match(String(iframe.src || ''), /return=%2Flaunches/);
  assert.equal(skipped.document.querySelector('[data-toybaco-billing-panel]'), null);
}

{
  const dash = loadInjectEntry(() => new Promise(() => {}), '/app/accounts/9/dashboard');
  dash.api.start();
  assert.equal(dash.window.location.replaced, undefined, 'the conversations dashboard must not redirect into the notifications inbox');
}

function createComposer(privateNote = false) {
  const box = createDomNode('div');
  box.className = privateNote ? 'reply-box is-private' : 'reply-box';
  const editor = createDomNode('div');
  editor.className = 'ProseMirror';
  editor.setAttribute('contenteditable', 'true');
  editor.textContent = '';
  box.appendChild(editor);
  return { box, editor };
}

function cannedPayload() {
  return [
    { short_code: 'yoyaku-uketsuke', content: 'ご希望の日時・メニュー・指名の有無をお知らせください。' },
    { short_code: 'yoyaku-cancel', content: 'ご予約をキャンセルいたしました。' },
    { short_code: 'menu-annai', content: 'メニューのご案内です。' },
  ];
}

function cannedAwareFetch(url) {
  const href = String(url);
  if (href.includes('/canned_responses')) {
    return Promise.resolve({
      ok: true,
      json: async () => cannedPayload(),
    });
  }
  return new Promise(() => {});
}

function slashPanel(document) {
  return document.querySelector('[data-toybaco-slash-canned]');
}

function fireSlashKey(api, editor, key, extra = {}) {
  const event = {
    key,
    target: editor,
    shiftKey: false,
    prevented: false,
    stopped: false,
    preventDefault() { this.prevented = true; },
    stopPropagation() { this.stopped = true; },
    stopImmediatePropagation() { this.stopped = true; },
    ...extra,
  };
  api.onComposeSlashKeydown(event);
  return event;
}

{
  const { api } = loadInjectEntry(cannedAwareFetch);
  assert.equal(api.cannedResponsesUrl('12'), '/api/v1/accounts/12/canned_responses');
  assert.equal(api.cannedResponsesUrl('../12'), '');
  assert.equal(api.cannedResponsesUrl('12/../9'), '');
  assert.equal(api.cannedQueryFromText(''), null);
  assert.equal(api.cannedQueryFromText('返信'), null);
  assert.equal(api.cannedQueryFromText('/'), '');
  assert.equal(api.cannedQueryFromText('/yoyaku'), 'yoyaku');
  assert.equal(api.cannedQueryFromText('先に一文\n/yoyaku-uke'), 'yoyaku-uke');
  const filtered = api.filterCannedItems(api.normalizeCannedRecords(cannedPayload()), '予約');
  assert.deepEqual([...filtered].map((item) => String(item.short_code)), ['yoyaku-uketsuke', 'yoyaku-cancel']);
  assert.equal(filtered[0].name, '予約受付');
  const records = api.normalizeCannedRecords([{ short_code: 'evil code', content: 'x' }, { short_code: 'menu-annai', content: 'メニューのご案内です。' }]);
  assert.deepEqual([...records].map((item) => String(item.short_code)), ['menu-annai']);
}

{
  const env = loadInjectEntry(cannedAwareFetch);
  const { box, editor } = createComposer();
  env.body.appendChild(box);
  assert.equal(env.api.isComposeTarget(editor), true);
  assert.equal(env.api.isComposeTarget(env.body), false);
  const priv = createComposer(true);
  env.body.appendChild(priv.box);
  assert.equal(env.api.isComposeTarget(priv.editor), false);
}

{
  const env = loadInjectEntry(cannedAwareFetch);
  env.document.cookie = `${['cw_d_session', 'info'].join('_')}=${encodeURIComponent(JSON.stringify({
    'access-token': 'tok-test',
    client: 'client-test',
    uid: 'agent@example.com',
  }))}`;
  const auth = env.api.readSessionHeaders();
  assert.equal(auth.token, 'tok-test');
  assert.equal(auth.client, 'client-test');
  assert.equal(auth.uid, 'agent@example.com');
  const headers = env.api.cannedFetchHeaders();
  assert.equal(headers['access-token'], 'tok-test');
  assert.equal(headers['token-type'], 'Bearer');
  env.api.prefetchCannedResponses('1');
  const cannedCall = env.fetches.find((item) => String(item.url).includes('/canned_responses'));
  assert.ok(cannedCall, 'compose slash must prefetch Chatwoot canned responses');
  assert.equal(cannedCall.url, '/api/v1/accounts/1/canned_responses');
  assert.equal(cannedCall.opts.credentials, 'same-origin');
  assert.equal(cannedCall.opts.headers['access-token'], 'tok-test');
  assert.equal(cannedCall.opts.headers.uid, 'agent@example.com');
}

{
  const env = loadInjectEntry(cannedAwareFetch);
  const { box, editor } = createComposer();
  env.body.appendChild(box);
  env.api.prefetchCannedResponses('1');
  await flush();
  const outside = fireSlashKey(env.api, env.body, '/');
  assert.equal(slashPanel(env.document), null, '/ outside compose must not open canned replies');
  assert.equal(outside.prevented, false);
  const first = fireSlashKey(env.api, editor, '/');
  assert.equal(first.prevented, false, 'the slash key itself must still type into the composer');
  const panel = slashPanel(env.document);
  assert.ok(panel, 'first / in compose must show canned replies immediately');
  assert.equal(panel.getAttribute('aria-label'), '定型文');
  const heading = panel.querySelector('[data-toybaco-slash-h]');
  assert.ok(heading);
  assert.equal(heading.textContent, '定型文');
  const items = panel.querySelectorAll('[data-toybaco-slash-item]');
  assert.equal(items.length, 3, 'empty query after first / must list canned replies without extra typing');
  assert.equal(items[0].getAttribute('data-toybaco-slash-item'), 'yoyaku-uketsuke');
  assert.ok(items[0].querySelector('[data-toybaco-canned-name]'));
  assert.equal(items[0].querySelector('[data-toybaco-canned-name]').textContent, '予約受付');
  assert.doesNotMatch(collectText(panel), /Captain|Copilot|CAPTAIN/);
}

{
  const env = loadInjectEntry(cannedAwareFetch);
  const { box, editor } = createComposer();
  env.body.appendChild(box);
  env.api.prefetchCannedResponses('1');
  await flush();
  fireSlashKey(env.api, editor, '/');
  editor.textContent = '/yoyaku-c';
  env.api.onComposeSlashInput({ target: editor });
  let items = slashPanel(env.document).querySelectorAll('[data-toybaco-slash-item]');
  assert.deepEqual([...items].map((row) => row.getAttribute('data-toybaco-slash-item')), ['yoyaku-cancel']);
  editor.textContent = '通常の返信';
  env.api.onComposeSlashInput({ target: editor });
  assert.equal(slashPanel(env.document), null, 'deleting the slash token must close the list');
}

{
  const env = loadInjectEntry(cannedAwareFetch);
  const { box, editor } = createComposer();
  env.body.appendChild(box);
  env.api.prefetchCannedResponses('1');
  await flush();
  fireSlashKey(env.api, editor, '/');
  editor.textContent = '/';
  const enter = fireSlashKey(env.api, editor, 'Enter');
  assert.equal(enter.prevented, true, 'Enter on the canned list must not send the conversation');
  assert.equal(slashPanel(env.document), null);
  assert.match(editor.textContent, /ご希望の日時/);
}

{
  const env = loadInjectEntry(cannedAwareFetch);
  env.api.inject();
  const cannedCall = env.fetches.find((item) => String(item.url).includes('/canned_responses'));
  assert.ok(cannedCall, 'inbox inject must prefetch canned replies before the first /');
  assert.equal(cannedCall.url, '/api/v1/accounts/1/canned_responses');
}

function aiModeAwareFetch(url, opts) {
  if (String(url).includes('/ai_usage')) return Promise.resolve(usageResponse());
  const href = String(url);
  if (href.includes('/ai_readiness')) return Promise.resolve(readinessResponse());
  if (href.includes('/ai_reply_mode')) {
    const incoming = opts && opts.body ? JSON.parse(opts.body) : null;
    return Promise.resolve({
      ok: true,
      json: async () => ({
        mode: incoming && incoming.mode === 'draft' ? 'draft' : 'auto',
        label: incoming && incoming.mode === 'draft' ? '下書き' : '全自動',
        modes: [
          { mode: 'auto', label: '全自動' },
          { mode: 'draft', label: '下書き' },
        ],
      }),
    });
  }
  return cannedAwareFetch(url, opts);
}

function readinessResponse(overrides = {}) {
  return { ok: true, json: async () => ({ connection: 'configured', configured_inboxes: 1,
    total_inboxes: 1, live_verification: 'unverified', ...overrides }) };
}

{
  const env = loadInjectEntry(aiModeAwareFetch);
  const { box } = createComposer();
  env.body.appendChild(box);
  assert.equal(env.api.currentAiMode(), null, 'unread settings must not select 全自動');
  assert.equal(env.api.normalizeAiMode('下書き'), 'draft');
  assert.equal(env.api.normalizeAiMode('全自動'), 'auto');
  assert.equal(env.api.aiModeLabel('draft'), '下書き');
  assert.equal(env.api.aiModeLabel('auto'), '全自動');
  assert.equal(env.api.aiModeUrl('8'), '/toybaco/ai_reply_mode?account_id=8');
  assert.equal(env.api.aiModeUrl('../8'), '');
  env.api.inject();
  assert.equal(
    env.document.querySelector('aside [data-toybaco-ai-mode-entry], nav [data-toybaco-ai-mode-entry]'),
    null,
    'AI応答 must stay off the canonical left nav'
  );
  const entry = aiModeEntry(env.document);
  assert.ok(entry, 'AI応答 must sit next to the reply box');
  assert.equal(entry.textContent, 'AI応答');
  const prefetch = env.fetches.find((item) => String(item.url).includes('/ai_reply_mode'));
  assert.ok(prefetch, 'inbox inject must read the saved AI reply mode');
  assert.equal(prefetch.url, '/toybaco/ai_reply_mode?account_id=1');
  assert.equal(prefetch.opts.credentials, 'same-origin');
  fireClick(entry, env.docListeners.click || []);
  const panel = env.document.querySelector('[data-toybaco-ai-mode-panel]');
  assert.ok(panel, 'AI応答 must open the two-mode panel rather than Captain');
  assert.doesNotMatch(collectText(panel), /Captain|Copilot|CAPTAIN|Auto|Draft/);
  assert.match(collectText(panel), /全自動/);
  assert.match(collectText(panel), /下書き/);
  assert.equal(env.document.querySelector('[data-toybaco-post-entry-panel]'), null);
  assert.equal(env.document.querySelector('[data-toybaco-billing-panel]'), null);
  const draft = panel.querySelector('[data-toybaco-ai-mode="draft"]');
  assert.ok(draft);
  await flush();
  fireClick(draft, env.docListeners.click || []);
  const saved = env.fetches.find((item) => item.opts && item.opts.method === 'PUT');
  assert.ok(saved, 'choosing 下書き must persist the mode');
  assert.equal(saved.url, '/toybaco/ai_reply_mode?account_id=1');
  assert.equal(JSON.parse(saved.opts.body).mode, 'draft');
  assert.equal(env.api.currentAiMode(), 'auto', 'save must keep the last confirmed mode until acknowledged');
  await flush();
  assert.equal(env.api.currentAiMode(), 'draft');
}

{
  const env = loadInjectEntry(aiModeAwareFetch);
  const { box } = createComposer();
  env.body.appendChild(box);
  env.api.inject();
  const bar = env.document.querySelector('[data-toybaco-ai-mode-bar]');
  assert.ok(bar, 'two modes must sit next to the reply box');
  assert.equal(bar.querySelector('[data-toybaco-ai-mode-h]').textContent, 'AI応答');
  const modes = [...bar.querySelectorAll('[data-toybaco-ai-mode]')].map((btn) => btn.textContent);
  assert.deepEqual(modes, ['全自動', '下書き']);
  assert.doesNotMatch(collectText(bar), /Captain|Copilot|Auto|Draft/);
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

{
  // Reloaded v4.17.1 sidebar: notifications Inbox and the Conversation group coexist.
  const tree = createMenuTree();
  const notification = tree.inbox.querySelector('a');
  notification.setAttribute('name', 'Inbox');
  notification.setAttribute('title', 'Inbox');
  notification.setAttribute('href', '/app/accounts/4/inbox-view');
  notification.href = '/app/accounts/4/inbox-view';
  const conversations = createStockRow('Conversations', 'i-lucide-message-circle');
  const conversationControl = conversations.querySelector('[role="button"]');
  conversationControl.setAttribute('name', 'Conversation');
  const children = createDomNode('ul');
  const all = createStockRow('All', 'i-lucide-inbox', '/app/accounts/4/dashboard');
  const channel = createStockRow('店舗A', 'i-lucide-mail', '/app/accounts/4/inbox/7');
  children.appendChild(all);
  children.appendChild(channel);
  conversations.appendChild(children);
  tree.ul.appendChild(conversations);
  const storeSwitch = createDomNode('button');
  storeSwitch.setAttribute('aria-label', '店舗を切り替える');
  tree.aside.appendChild(storeSwitch);
  const env = loadInjectEntry(() => new Promise(() => {}), '/app/accounts/4/dashboard', { body: tree.body });
  const visited = [];
  all.querySelector('a').click = () => { visited.push('all'); };
  channel.querySelector('a').click = () => { visited.push('channel'); };
  const primaryConversations = () => tree.ul.children.filter((row) => row.getAttribute('data-toybaco-primary-nav') === 'inbox');

  env.api.inject();
  assert.equal(primaryConversations().length, 1, 'reloaded Inbox + Conversation must expose exactly one primary 会話 row');
  assert.equal(primaryConversations()[0], conversations, 'the native conversation group is the canonical entry');
  assert.equal(tree.inbox.getAttribute('data-toybaco-nav-duplicate'), '1');
  assert.equal(conversations.getAttribute('data-toybaco-nav-duplicate'), null);
  assert.equal(conversationControl.getAttribute('role'), 'button');
  assert.equal(conversationControl.getAttribute('tabindex'), '0');
  assert.equal(conversationControl.getAttribute('aria-current'), 'page');
  assert.equal(notification.getAttribute('aria-current'), null, 'the duplicate cannot also announce the current page');
  assert.equal(postingEntry(env.document).parentElement.previousElementSibling, conversations);
  assert.equal(storeSwitch.parentElement, tree.aside, 'store switching must remain outside nav filtering');
  assert.equal(fireClick(storeSwitch, env.docListeners.click || []).prevented, false);
  assert.equal(channel.querySelector('a').getAttribute('href'), '/app/accounts/4/inbox/7');
  assert.equal(channel.querySelector('a').getAttribute('data-toybaco-nav-link'), null, 'child channel links must retain their native behavior');
  assert.equal(fireClick(channel.querySelector('a'), env.docListeners.click || []).prevented, false);
  channel.querySelector('a').click();

  env.window.location.pathname = '/app/accounts/4/settings/general';
  env.api.afterNavChange();
  fireClick(conversationControl, env.docListeners.click || []);
  assert.deepEqual(visited, ['channel', 'all'], '会話 must use the native All route, not the rewritten notifications anchor');
  for (const key of ['Enter', ' ']) {
    const event = { key, preventDefault() {}, stopPropagation() {}, stopImmediatePropagation() {} };
    for (const listener of conversationControl.listeners.keydown) listener.call(conversationControl, event);
  }
  assert.deepEqual(visited, ['channel', 'all', 'all', 'all'], 'the retained button must remain keyboard navigable');
  env.window.location.pathname = '/app/accounts/4/conversations/42';
  env.api.afterNavChange();
  fireClick(postingEntry(env.document), env.docListeners.click || []);
  fireClick(conversationControl, env.docListeners.click || []);
  assert.equal(env.window.location.pathname, '/app/accounts/4/conversations/42');
  assert.equal(env.document.querySelector('[data-toybaco-post-entry-panel]'), null);

  // A role/account redraw can temporarily remove the group; the remaining entry must recover.
  conversations.remove();
  env.window.location.pathname = '/app/accounts/9/dashboard';
  env.api.afterNavChange();
  assert.equal(primaryConversations().length, 1);
  assert.equal(primaryConversations()[0], tree.inbox);
  assert.equal(tree.inbox.getAttribute('data-toybaco-nav-duplicate'), null, 'the fallback must become visible again');
  assert.equal(notification.getAttribute('href'), '/app/accounts/9/dashboard');
  assert.equal(notification.getAttribute('aria-current'), 'page');
  assert.equal(postingEntry(env.document).getAttribute('data-account'), '9');
  assert.equal(env.document.querySelector('[data-toybaco-primary-nav="settings"]'), null, 'a missing role-gated entry must not be created');
  conversationControl.setAttribute('title', '会話');
  tree.ul.appendChild(conversations);
  env.api.afterNavChange();
  assert.equal(primaryConversations().length, 1, 'the late-mounted group must replace the fallback without a second primary row');
  assert.equal(primaryConversations()[0], conversations);
  assert.equal(tree.inbox.getAttribute('data-toybaco-nav-duplicate'), '1');
  assert.equal(notification.getAttribute('aria-current'), null);
  assert.equal(postingEntry(env.document).parentElement.previousElementSibling, conversations);
}

{
  // Match SidebarGroup's parent control + nested UL. These links are not a
  // second global menu: the native component filters roles and owns expansion.
  const tree = createMenuTree();
  const settings = createStockRow('設定', 'i-lucide-bolt');
  const reports = createStockRow('レポート', 'i-lucide-chart-spline');
  const settingsChildren = createDomNode('ul');
  settingsChildren.className = 'grid m-0 list-none min-w-0';
  const reportChildren = createDomNode('ul');
  const settingsRows = [
    ['アカウント設定', 'general'], ['受信箱', 'inboxes/list'],
    ['担当者', 'agents/list'], ['定型文', 'canned-response/list'],
  ].map(([label, suffix]) => createStockRow(label, 'i-lucide-users', `/app/accounts/4/settings/${suffix}`));
  const overview = createStockRow('概要', 'i-lucide-messages-square', '/app/accounts/4/reports/overview');
  settingsRows.forEach((row) => settingsChildren.appendChild(row));
  reportChildren.appendChild(overview);
  settings.appendChild(settingsChildren); reports.appendChild(reportChildren);
  tree.ul.appendChild(reports); tree.ul.appendChild(settings);
  const stock = createStockRow('連絡先', 'i-lucide-contact', '/app/accounts/4/contacts');
  tree.ul.appendChild(stock);
  const env = loadInjectEntry(() => new Promise(() => {}), '/app/accounts/4/settings/general', { body: tree.body });
  const visits = [];
  let expanded = null;
  const groups = [[settings, settingsChildren, settingsRows[0]], [reports, reportChildren, overview]];
  function renderNativeChildren() {
    for (const [row, children] of groups) {
      const active = children.children.find((child) => child.querySelector('a').href === env.window.location.pathname);
      children.style.display = expanded === row || active ? '' : 'none';
      for (const child of children.children) child.style.display = expanded === row || child === active ? '' : 'none';
    }
  }
  for (const [row, children, first] of groups) {
    const control = row.querySelector('[role="button"]');
    children.style.display = 'none';
    control.addEventListener('click', () => {
      assert.equal(env.document.querySelector('[data-toybaco-post-entry-panel]'), null, 'close posting before the native group handler runs');
      assert.equal(env.document.querySelector('[data-toybaco-billing-panel]'), null, 'close billing before the native group handler runs');
      expanded = expanded === row ? null : row;
      if (expanded === row) first.querySelector('a').click();
      renderNativeChildren();
    });
    control.click = () => fireClick(control, env.docListeners.click || []);
  }
  for (const row of [...settingsRows, overview]) {
    const link = row.querySelector('a');
    link.addEventListener('click', () => { visits.push(link.href); env.window.location.pathname = link.href; env.api.afterNavChange(); });
    link.click = () => fireClick(link, env.docListeners.click || []);
  }
  env.api.inject();
  for (const row of [...settingsRows, overview]) {
    for (const node of [row, ...row.querySelectorAll('a, span')]) {
      assert.equal(node.getAttribute('data-toybaco-stock-hidden'), null, 'role-allowed settings/report children must stay reachable');
      assert.notEqual(node.style.display, 'none');
    }
    assert.equal(row.querySelector('a').getAttribute('data-toybaco-nav-link'), null, 'child links must not become primary controls');
  }
  assert.equal(stock.getAttribute('data-toybaco-stock-hidden'), '1', 'unrelated global inventory stays hidden');
  const settingsControl = settings.querySelector('[role="button"]');
  const reportsControl = reports.querySelector('[role="button"]');
  const primaryCount = () => tree.ul.children.filter((row) => row.getAttribute('data-toybaco-primary-nav') || row.getAttribute('data-toybaco-post-entry-wrap') || row.querySelector('[data-toybaco-billing-entry]')).length;
  assert.equal(primaryCount(), 5, 'child expansion must preserve the five primary functions');
  fireClick(postingEntry(env.document), env.docListeners.click || []);
  assert.equal(fireClick(settingsControl, env.docListeners.click || []).prevented, false, 'native settings click must be allowed');
  assert.equal(settingsChildren.style.display, '');
  for (const row of settingsRows.slice(1)) {
    assert.equal(fireClick(row.querySelector('a'), env.docListeners.click || []).prevented, false);
    assert.equal(env.window.location.pathname, row.querySelector('a').href, 'each child must reach its own native destination');
  }
  fireClick(reportsControl, env.docListeners.click || []);
  assert.equal(reportChildren.style.display, '');
  fireClick(settingsControl, env.docListeners.click || []);
  assert.equal(settingsChildren.style.display, '', 'returning from reports must reopen all settings children');
  fireClick(settingsControl, env.docListeners.click || []);
  assert.equal(settingsChildren.style.display, '', 'native collapse retains the active child');
  assert.equal(settingsRows[1].style.display, 'none', 'native collapse hides inactive children');
  const key = { key: 'Enter', preventDefault() {}, stopPropagation() {}, stopImmediatePropagation() {} };
  settingsControl.listeners.keydown[0].call(settingsControl, key);
  assert.equal(settingsChildren.style.display, '', 'Enter must activate native settings expansion');
  assert.equal(settingsRows[1].style.display, '', 'Enter exposes all permitted children');
  settingsControl.listeners.keydown[0].call(settingsControl, { ...key, key: ' ' });
  assert.equal(settingsRows[1].style.display, 'none', 'Space must activate native collapse');
  settingsRows[1].remove();
  env.api.inject();
  assert.equal(settingsChildren.children.length, 3, 'do not recreate a child removed by role policy');
  assert.equal(primaryCount(), 5);
  assert.ok(visits.includes('/app/accounts/4/settings/canned-response/list'));
}

{
  const tree = createMenuTree();
  const settings = createStockRow('Settings', 'i-lucide-bolt', '/app/accounts/4/settings/profile');
  tree.ul.appendChild(settings);
  const env = loadInjectEntry(() => new Promise(() => {}), '/app/accounts/4/conversations/42', { body: tree.body });
  env.api.inject();
  const link = settings.querySelector('a');
  assert.equal(link.getAttribute('href'), '/app/accounts/4/settings/profile', 'retain the native role-specific settings destination');
  assert.equal(link.getAttribute('data-toybaco-nav-keyboard'), null, 'anchors retain native keyboard activation');
  assert.equal(fireClick(link, env.docListeners.click || []).prevented, false);
  assert.equal(settings.querySelector('ul'), null, 'do not manufacture a settings submenu');
}

{
  const tree = createMenuTree();
  const inboxControl = tree.inbox.querySelector('a');
  inboxControl.className = 'flex gap-2 router-link-active router-link-exact-active bg-n-alpha-2';
  const reports = createStockRow('レポート', 'i-lucide-chart-spline');
  const reportChildren = createDomNode('ul');
  const overview = createStockRow('概要', 'i-lucide-messages-square', '/app/accounts/1/reports/overview');
  reportChildren.appendChild(overview);
  reports.appendChild(reportChildren);
  tree.ul.appendChild(reports);
  const settings = createStockRow('設定', 'i-lucide-bolt');
  const settingsChildren = createDomNode('ul');
  const general = createStockRow('アカウント設定', 'i-lucide-users', '/app/accounts/1/settings/general');
  settingsChildren.appendChild(general);
  settings.appendChild(settingsChildren);
  tree.ul.appendChild(settings);
  const allConversations = createStockRow('すべての会話', 'i-lucide-inbox', '/app/accounts/1/dashboard');
  tree.ul.appendChild(allConversations);
  const env = loadInjectEntry(() => new Promise(() => {}), '/app/accounts/1/inbox-view', { body: tree.body });
  const visited = [];
  for (const row of [overview, general, allConversations]) {
    const link = row.querySelector('a');
    link.click = () => {
      visited.push(link.href);
      env.window.location.pathname = link.href;
      env.api.afterNavChange();
    };
  }
  for (const [row, first] of [[reports, overview], [settings, general]]) {
    row.querySelector('[role="button"]').addEventListener('click', () => first.querySelector('a').click());
  }
  env.api.inject();
  for (const entry of [postingEntry(env.document), billingEntry(env.document)]) {
    assert.doesNotMatch(entry.className, /router-link-active|router-link-exact-active|bg-n-alpha-2/, 'new entries cannot inherit the active inbox classes');
    assert.equal(entry.getAttribute('data-toybaco-nav-current'), 'false');
  }
  assert.equal(inboxControl.getAttribute('href'), '/app/accounts/1/dashboard');
  fireClick(inboxControl, env.docListeners.click || []);
  assert.deepEqual(visited, ['/app/accounts/1/dashboard'], '会話 must use the existing conversations route, not notifications');
  for (const row of [reports, settings]) {
    assert.equal(row.getAttribute('data-toybaco-stock-hidden'), null, 'stock children must not hide a canonical parent');
    const control = row.querySelector('[role="button"]');
    assert.equal(control.getAttribute('tabindex'), '0');
    fireClick(control, env.docListeners.click || []);
    assert.equal(control.getAttribute('data-toybaco-nav-current'), 'true');
    assert.equal(inboxControl.getAttribute('data-toybaco-nav-current'), 'false');
  }
  assert.deepEqual(visited, ['/app/accounts/1/dashboard', '/app/accounts/1/reports/overview', '/app/accounts/1/settings/general']);
  const settingsControl = settings.querySelector('[role="button"]');
  fireClick(postingEntry(env.document), env.docListeners.click || []);
  assert.equal(settingsControl.getAttribute('data-toybaco-nav-current'), 'false');
  assert.equal(postingEntry(env.document).getAttribute('data-toybaco-nav-current'), 'true');
  fireClick(billingEntry(env.document), env.docListeners.click || []);
  assert.equal(env.document.querySelector('[data-toybaco-post-entry-panel]'), null, 'billing and posting must not stack two work surfaces');
  assert.equal(billingEntry(env.document).getAttribute('data-toybaco-nav-current'), 'true');
  assert.equal(postingEntry(env.document).getAttribute('data-toybaco-nav-current'), 'false');
  fireClick(postingEntry(env.document), env.docListeners.click || []);
  assert.equal(env.document.querySelector('[data-toybaco-billing-panel]'), null, 'posting must replace the billing surface');
  env.api.closePanel();
  env.window.location.pathname = '/app/accounts/1/conversations/42';
  env.api.afterNavChange();
  fireClick(postingEntry(env.document), env.docListeners.click || []);
  fireClick(inboxControl, env.docListeners.click || []);
  assert.equal(env.window.location.pathname, '/app/accounts/1/conversations/42', 'returning from posting must preserve the open conversation');
  assert.equal(env.document.querySelector('[data-toybaco-post-entry-panel]'), null);
  assert.equal(inboxControl.getAttribute('aria-current'), 'page');
}

function modeResponse(mode) {
  return { ok: true, json: async () => ({ mode }) };
}

{
  const env = loadInjectEntry(aiModeAwareFetch);
  const createElement = env.document.createElement;
  env.document.createElement = (tag) => {
    const node = createElement(tag);
    node.focus = () => { env.document.activeElement = node; };
    return node;
  };
  const opener = env.document.createElement('button');
  env.body.appendChild(opener);
  opener.focus();
  env.api.openAiModePanel();
  const panel = env.document.querySelector('[data-toybaco-ai-mode-panel]');
  assert.equal(panel.getAttribute('role'), 'dialog');
  assert.equal(panel.getAttribute('aria-label'), '店舗全体のAI応答設定');
  assert.equal(env.document.activeElement.textContent, '閉じる', 'opening AI settings must place keyboard focus inside');
  for (const listener of env.docListeners.keydown) listener({ key: 'Escape' });
  assert.equal(env.document.querySelector('[data-toybaco-ai-mode-panel]'), null);
  assert.equal(env.document.activeElement, opener, 'closing AI settings must return focus to its entry');
}

function createAiModeEnv(handler, options = {}) {
  const calls = [];
  const env = loadInjectEntry((url, opts) => {
    if (!String(url).includes('/ai_reply_mode')) return aiModeAwareFetch(url, opts);
    calls.push({ url: String(url), method: opts.method || 'GET' });
    return handler(url, opts, calls.length);
  }, '/app/accounts/1/inbox', options);
  const { box } = createComposer();
  env.body.appendChild(box);
  env.api.inject();
  env.aiCalls = calls;
  env.aiBar = env.document.querySelector('[data-toybaco-ai-mode-bar]');
  return env;
}

{
  const read = deferred();
  const write = deferred();
  const env = createAiModeEnv((url, opts) => opts.method === 'PUT' ? write.promise : read.promise);
  const auto = env.aiBar.querySelector('[data-toybaco-ai-mode="auto"]');
  const draft = env.aiBar.querySelector('[data-toybaco-ai-mode="draft"]');
  assert.equal(env.api.currentAiMode(), null);
  assert.equal(auto.getAttribute('aria-pressed'), 'false');
  assert.equal(draft.getAttribute('aria-pressed'), 'false');
  assert.equal(draft.disabled, true);
  env.api.saveAiMode('draft');
  assert.equal(env.aiCalls.length, 1, 'no write before the current setting is known');
  read.resolve(modeResponse('auto'));
  await flush();
  const saving = env.api.saveAiMode('draft');
  env.api.saveAiMode('auto');
  env.api.saveAiMode('draft');
  assert.equal(env.aiCalls.length, 2, 'rapid toggles must not create concurrent writes');
  assert.equal(env.api.currentAiMode(), 'auto');
  assert.equal(draft.getAttribute('aria-pressed'), 'false');
  assert.equal(env.aiBar.getAttribute('data-toybaco-ai-state'), 'saving');
  assert.equal(env.aiBar.getAttribute('aria-busy'), 'true');
  write.resolve(modeResponse('draft'));
  await saving;
  assert.equal(env.api.currentAiMode(), 'draft');
  assert.equal(draft.disabled, false);
  assert.equal(draft.getAttribute('aria-pressed'), 'true');
  env.api.inject();
  assert.equal(env.aiCalls.length, 2, 'DOM repaint must not refetch and overwrite a confirmed save');
  assert.match(collectText(env.aiBar), /店舗全体/);
}

for (const invalid of [null, '', 'unexpected']) {
  const env = createAiModeEnv(() => Promise.resolve(modeResponse(invalid)));
  await flush();
  assert.equal(env.api.currentAiMode(), null, 'malformed responses must not turn into 全自動');
  assert.equal(env.aiBar.getAttribute('data-toybaco-ai-state'), 'error');
  assert.equal(env.aiBar.querySelector('[data-toybaco-ai-retry]').hidden, false);
}

for (const savedOnServer of [false, true]) {
  let serverMode = 'auto';
  const env = createAiModeEnv((url, opts) => {
    if (opts.method !== 'PUT') return Promise.resolve(modeResponse(serverMode));
    if (!savedOnServer) return Promise.resolve({ ok: false, status: 403 });
    serverMode = 'draft';
    return Promise.reject(new Error('connection lost after persistence'));
  });
  await flush();
  await env.api.saveAiMode('draft');
  assert.deepEqual(env.aiCalls.map((item) => item.method), ['GET', 'PUT', 'GET']);
  assert.equal(env.api.currentAiMode(), savedOnServer ? 'draft' : 'auto', 'read-back, not optimism or blind rollback, determines the displayed mode');
  assert.match(collectText(env.aiBar), /変更の応答を確認できませんでした。現在の設定/);
}

{
  let failRead = false;
  const env = createAiModeEnv((url, opts) => {
    if (opts.method === 'PUT') {
      failRead = true;
      return Promise.reject(new Error('offline'));
    }
    return failRead ? Promise.reject(new Error('offline')) : Promise.resolve(modeResponse('auto'));
  });
  await flush();
  await env.api.saveAiMode('draft');
  assert.equal(env.api.currentAiMode(), null, 'failed read-back must leave both settings unconfirmed');
  assert.equal(env.aiBar.getAttribute('data-toybaco-ai-state'), 'error');
  assert.match(collectText(env.aiBar), /保存結果を確認できませんでした/);
  env.api.inject();
  assert.equal(env.aiCalls.length, 3, 'failed requests must not loop on DOM mutations');
  failRead = false;
  fireClick(env.aiBar.querySelector('[data-toybaco-ai-retry]'));
  await flush();
  assert.equal(env.api.currentAiMode(), 'auto', 'retry must restore controls using a fresh GET');
}

{
  const accountA = deferred();
  const accountB = deferred();
  const env = createAiModeEnv((url) => String(url).endsWith('=1') ? accountA.promise : accountB.promise);
  env.window.location.pathname = '/app/accounts/2/inbox';
  env.api.inject();
  accountB.resolve(modeResponse('draft'));
  await flush();
  accountA.resolve(modeResponse('auto'));
  await flush();
  assert.equal(env.api.currentAiMode(), 'draft');
  assert.equal(env.aiBar.getAttribute('data-toybaco-ai-current'), 'draft', 'a late read from A must not repaint B');
}

{
  const writeA = deferred();
  const env = createAiModeEnv((url, opts) => opts.method === 'PUT' ? writeA.promise : Promise.resolve(modeResponse('auto')));
  await flush();
  const saving = env.api.saveAiMode('draft');
  env.window.location.pathname = '/app/accounts/2/inbox';
  env.api.inject();
  await flush();
  writeA.resolve(modeResponse('draft'));
  await saving;
  assert.equal(env.api.currentAiMode('1'), 'draft');
  assert.equal(env.api.currentAiMode(), 'auto');
  assert.equal(env.aiBar.getAttribute('data-toybaco-ai-current'), 'auto', 'a late save from A must not repaint B');
}

{
  const stalled = deferred();
  const timers = [];
  const env = createAiModeEnv(() => stalled.promise, {
    setTimeout(fn, ms) { const timer = { fn, ms }; timers.push(timer); return timer; },
    clearTimeout() {},
  });
  const timeout = timers.find((timer) => timer.ms === 10000);
  assert.ok(timeout, 'mode reads must have a bounded wait');
  timers.filter((timer) => timer.ms === 10000).forEach((timer) => timer.fn());
  await flush();
  assert.equal(env.aiBar.getAttribute('data-toybaco-ai-state'), 'error');
  stalled.resolve(modeResponse('auto'));
  await flush();
  assert.equal(env.api.currentAiMode(), null, 'a timed-out response cannot silently become a confirmed setting');
}

function createAiReadinessEnv(handler) {
  const calls = [];
  const env = loadInjectEntry((url, opts) => {
    if (!String(url).includes('/ai_readiness')) return aiModeAwareFetch(url, opts);
    calls.push({ url: String(url), opts });
    return handler(url, opts, calls.length);
  });
  const { box } = createComposer();
  env.body.appendChild(box);
  env.api.inject();
  env.connectionCalls = calls;
  env.aiBar = env.document.querySelector('[data-toybaco-ai-mode-bar]');
  return env;
}

{
  const env = createAiReadinessEnv(() => Promise.resolve(readinessResponse({ connection: 'unconnected', configured_inboxes: 0 })));
  await flush();
  assert.equal(env.api.currentAiMode(), 'auto', 'missing Bot must preserve the saved mode');
  assert.match(collectText(env.aiBar), /保存された設定：全自動/);
  assert.match(collectText(env.aiBar), /AI応答は未接続です。担当者が返信してください/);
  assert.doesNotMatch(collectText(env.aiBar), /AIがお客様へ送信します|稼働中|準備完了/);
  assert.equal(env.aiBar.querySelector('[data-toybaco-ai-mode="draft"]').disabled, true);
  await env.api.saveAiMode('draft');
  assert.equal(env.fetches.filter((call) => call.opts?.method === 'PUT').length, 0);
  env.api.inject();
  env.api.inject();
  assert.equal(env.connectionCalls.length, 1, 'missing Bot must not trigger a polling loop');
  assert.equal(env.connectionCalls[0].opts.credentials, 'same-origin');
  assert.equal(env.connectionCalls[0].opts.cache, 'no-store');
}

{
  const env = createAiReadinessEnv(() => Promise.resolve(readinessResponse({ configured_inboxes: 1, total_inboxes: 3 })));
  await flush();
  assert.match(collectText(env.aiBar), /接続設定あり（受信箱 1 \/ 3 件）/);
  assert.match(collectText(env.aiBar), /外部への応答動作は未確認/);
  assert.match(collectText(env.aiBar), /ご契約の利用状況/);
  assert.doesNotMatch(collectText(env.aiBar), /AIがお客様へ送信します|稼働中|準備完了/);
  assert.equal(env.aiBar.querySelector('[data-toybaco-ai-mode="draft"]').disabled, false);
}

for (const result of [
  () => Promise.reject(new Error('offline')),
  () => Promise.resolve({ ok: false, status: 503 }),
  () => Promise.resolve(readinessResponse({ connection: 'ready' })),
  () => Promise.resolve(readinessResponse({ live_verification: 'verified' })),
  () => Promise.resolve(readinessResponse({ connection: 'unknown', configured_inboxes: 0 })),
]) {
  let recover = false;
  const env = createAiReadinessEnv(() => recover ? Promise.resolve(readinessResponse()) : result());
  await flush();
  assert.equal(env.api.currentAiMode(), 'auto');
  assert.match(collectText(env.aiBar), /接続状態を確認できません/);
  assert.doesNotMatch(collectText(env.aiBar), /AI応答は未接続です/);
  assert.equal(env.aiBar.querySelector('[data-toybaco-ai-mode="draft"]').disabled, true);
  env.api.inject();
  assert.equal(env.connectionCalls.length, 1, 'connection errors must wait for explicit retry');
  recover = true;
  fireClick(env.aiBar.querySelector('[data-toybaco-ai-retry]'));
  await flush();
  assert.equal(env.connectionCalls.length, 2);
  assert.equal(env.aiBar.querySelector('[data-toybaco-ai-mode="draft"]').disabled, false);
}

{
  const accountA = deferred();
  const accountB = deferred();
  const env = createAiReadinessEnv((url) => String(url).endsWith('=1') ? accountA.promise : accountB.promise);
  await flush();
  env.window.location.pathname = '/app/accounts/2/inbox';
  env.api.inject();
  assert.equal(env.aiBar.querySelector('[data-toybaco-ai-mode="draft"]').disabled, true);
  accountB.resolve(readinessResponse({ connection: 'unconnected', configured_inboxes: 0 }));
  await flush();
  accountA.resolve(readinessResponse());
  await flush();
  assert.equal(env.aiBar.getAttribute('data-toybaco-ai-connection'), 'unconnected');
  assert.equal(env.aiBar.querySelector('[data-toybaco-ai-mode="draft"]').disabled, true,
    'late connection response from A must not enable B');
}

function usageBody(overrides = {}) {
  return { enabled: true, used: 100, reserved: 2, limit: 500, remaining: 398,
    period: '2026-09', resets_at: '2026-09-30T15:00:00Z', reason: null, ...overrides };
}

function usageResponse(overrides = {}) {
  return { ok: true, json: async () => usageBody(overrides) };
}

function createAiContractEnv(usageHandler, connection = {}) {
  const calls = [];
  const env = loadInjectEntry((url, opts) => {
    if (String(url).includes('/ai_readiness')) return Promise.resolve(readinessResponse(connection));
    if (!String(url).includes('/ai_usage')) return aiModeAwareFetch(url, opts);
    calls.push({ url: String(url), opts });
    return usageHandler(url, opts, calls.length);
  });
  env.body.appendChild(createComposer().box);
  env.api.inject();
  env.aiBar = env.document.querySelector('[data-toybaco-ai-mode-bar]');
  env.contractCalls = calls;
  return env;
}

for (const connection of [
  { connection: 'unconnected', configured_inboxes: 0 },
  { connection: 'configured', configured_inboxes: 1 },
]) {
  const env = createAiContractEnv(() => Promise.resolve(usageResponse({ enabled: false, reason: 'disabled', limit: 0, remaining: 0 })), connection);
  await flush();
  assert.match(collectText(env.aiBar), /現在のご契約にはAI応答が含まれていません/);
  assert.match(collectText(env.aiBar), /保存された設定：全自動（現在のご契約では適用されません）/);
  assert.doesNotMatch(collectText(env.aiBar), /AI応答は未接続です/);
  assert.equal(env.api.currentAiMode(), 'auto', 'contract denial must retain the saved setting');
  assert.equal(env.aiBar.querySelector('[data-toybaco-ai-mode="draft"]').disabled, true);
  await env.api.saveAiMode('draft');
  assert.equal(env.fetches.filter(call => call.opts?.method === 'PUT').length, 0);
  env.api.inject(); env.api.inject();
  assert.equal(env.contractCalls.length, 1, 'DOM updates must not poll contract usage');
  assert.equal(env.contractCalls[0].opts.credentials, 'same-origin');
  assert.equal(env.contractCalls[0].opts.cache, 'no-store');
  assert.equal(env.contractCalls[0].opts.method || 'GET', 'GET');
  env.api.openAiModePanel();
  await flush();
  assert.match(collectText(env.document.querySelector('[data-toybaco-ai-mode-panel]')), /現在のご契約にはAI応答が含まれていません/);
}

{
  const env = createAiContractEnv(() => Promise.resolve(usageResponse()), { connection: 'unconnected', configured_inboxes: 0 });
  await flush();
  assert.match(collectText(env.aiBar), /AI応答は未接続です。担当者が返信してください/);
  assert.doesNotMatch(collectText(env.aiBar), /ご契約にはAI応答が含まれていません|適用されません/);
}

for (const reason of ['unknown_contract', 'account_inactive']) {
  const env = createAiContractEnv(() => Promise.resolve(usageResponse({ enabled: false, reason, limit: 0, remaining: 0 })));
  await flush();
  assert.match(collectText(env.aiBar), reason === 'unknown_contract' ? /利用条件を確認できません/ : /この店舗のAI応答はご利用いただけません/);
  assert.doesNotMatch(collectText(env.aiBar), /ご契約にはAI応答が含まれていません/);
  assert.equal(env.aiBar.querySelector('[data-toybaco-ai-mode="draft"]').disabled, true);
}

{
  const read = deferred();
  let recover = false;
  const env = createAiContractEnv(() => recover ? Promise.resolve(usageResponse()) : read.promise);
  await flush();
  assert.equal(env.aiBar.querySelector('[data-toybaco-ai-mode="draft"]').disabled, true, 'Bot + saved mode cannot enable controls before contract readback');
  assert.match(collectText(env.aiBar), /AI応答の利用条件を確認しています/);
  read.resolve({ ok: false, status: 503 });
  await flush();
  assert.match(collectText(env.aiBar), /AI応答の利用条件を取得できませんでした/);
  assert.equal(env.aiBar.querySelector('[data-toybaco-ai-retry]').hidden, false);
  assert.equal(env.api.currentAiMode(), 'auto');
  env.api.inject();
  assert.equal(env.contractCalls.length, 1);
  recover = true;
  const retry = env.aiBar.querySelector('[data-toybaco-ai-retry]');
  fireClick(retry); fireClick(retry);
  await flush();
  assert.equal(env.contractCalls.length, 2, 'simultaneous explicit retries share one GET');
  assert.equal(env.aiBar.querySelector('[data-toybaco-ai-mode="draft"]').disabled, false);
}

{
  const env = createAiContractEnv(() => Promise.resolve(usageResponse({ used: 500, reserved: 0, remaining: 0, reason: 'limit_reached' })));
  await flush();
  assert.match(collectText(env.aiBar), /利用できる残り枠がありません/);
  assert.doesNotMatch(collectText(env.aiBar), /ご契約にはAI応答が含まれていません/);
  assert.equal(env.aiBar.querySelector('[data-toybaco-ai-mode="draft"]').disabled, false, 'quota exhaustion does not remove the contract or its saved-mode controls');
}

{
  const accountA = deferred();
  const accountB = deferred();
  const env = createAiContractEnv(url => String(url).endsWith('=1') ? accountA.promise : accountB.promise);
  env.window.location.pathname = '/app/accounts/2/inbox';
  env.api.inject();
  assert.equal(env.aiBar.querySelector('[data-toybaco-ai-mode="draft"]').disabled, true);
  accountB.resolve(usageResponse({ enabled: false, reason: 'disabled', limit: 0, remaining: 0 }));
  await flush();
  accountA.resolve(usageResponse());
  await flush();
  assert.match(collectText(env.aiBar), /現在のご契約にはAI応答が含まれていません/);
  assert.equal(env.aiBar.querySelector('[data-toybaco-ai-mode="draft"]').disabled, true, 'late enabled A must not enable disabled B');
  assert.equal(env.contractCalls.length, 2);
}

function createAiUsageEnv(handler, options = {}) {
  const calls = [];
  const env = loadInjectEntry((url, opts) => {
    if (!String(url).includes('/ai_usage')) return aiModeAwareFetch(url, opts);
    calls.push({ url: String(url), opts });
    return handler(url, opts, calls.length);
  }, '/app/accounts/1/inbox', options);
  const { box } = createComposer();
  env.body.appendChild(box);
  env.api.inject();
  assert.equal(calls.length, 1, 'the composer must read contract rights once before enabling AI controls');
  env.api.openAiModePanel();
  env.usageCard = env.document.querySelector('[data-toybaco-ai-usage]');
  env.usageCalls = calls;
  return env;
}

{
  const read = deferred();
  const refresh = deferred();
  const env = createAiUsageEnv((url, opts, call) => call === 1 ? read.promise : refresh.promise);
  const value = env.usageCard.querySelector('[data-toybaco-ai-usage-value]');
  const meter = env.usageCard.querySelector('[data-toybaco-ai-usage-meter]');
  const button = env.usageCard.querySelector('[data-toybaco-ai-usage-refresh]');
  assert.equal(value.textContent, '', 'loading must not invent a zero count or a plan quota');
  assert.equal(env.usageCard.getAttribute('aria-busy'), 'true');
  assert.equal(button.disabled, true);
  assert.match(collectText(env.usageCard), /利用状況を確認しています/);
  assert.equal(env.usageCalls[0].url, '/toybaco/ai_usage?account_id=1');
  assert.equal(env.usageCalls[0].opts.credentials, 'same-origin');
  assert.equal(env.usageCalls[0].opts.cache, 'no-store');
  const heading = env.usageCard.querySelector('[data-toybaco-ai-usage-heading]');
  let headingText = heading.textContent;
  let headingWrites = 0;
  Object.defineProperty(heading, 'textContent', { get() { return headingText; }, set(value) { headingWrites += 1; headingText = value; } });
  env.api.inject(); env.api.inject();
  assert.equal(headingWrites, 0, 'an in-flight contract read must not rewrite usage text on DOM mutation and trigger another observer pass');
  await flush();
  assert.equal(env.api.currentAiMode(), 'auto', 'mode confirmation is independent of usage loading');
  read.resolve(usageResponse());
  await flush();
  assert.equal(value.textContent, '100 / 500 件');
  assert.match(collectText(env.usageCard), /残り 398 件 · 処理中 2 件/);
  assert.match(collectText(env.usageCard), /2026年10月1日 0:00（日本時間）に更新/);
  assert.equal(meter.getAttribute('aria-valuenow'), '100');
  assert.equal(meter.getAttribute('aria-valuemax'), '500');
  assert.equal(meter.querySelector('[data-toybaco-ai-usage-used]').style.width, '20%');
  fireClick(button);
  assert.equal(value.textContent, '', 'refresh must clear the previous count until confirmed');
  refresh.reject(new Error('offline'));
  await flush();
  assert.equal(meter.hidden, true);
  assert.match(collectText(env.usageCard), /利用状況を取得できません/);
  assert.equal(button.textContent, '再確認');
  assert.equal(button.disabled, false);
  assert.equal(env.api.currentAiMode(), 'auto', 'usage failure must not change the confirmed mode');
  env.api.inject();
  assert.equal(env.usageCalls.length, 2, 'DOM mutations must not retry unavailable usage in a loop');
}

for (const [reason, expected] of [
  ['disabled', /現在のご契約にはAI応答が含まれていません/],
  ['unknown_contract', /AI応答の利用条件を確認できません/],
  ['account_inactive', /現在、この店舗のAI応答はご利用いただけません/],
]) {
  const env = createAiUsageEnv(() => Promise.resolve(usageResponse({ enabled: false, reason, limit: 0, remaining: 0 })));
  await flush();
  assert.match(collectText(env.usageCard), expected);
  assert.doesNotMatch(collectText(env.usageCard), /unknown_contract|account_inactive|disabled|500|残り/);
  assert.equal(env.usageCard.querySelector('[data-toybaco-ai-usage-value]').textContent, '');
  assert.equal(env.api.currentAiMode(), 'auto');
}

{
  const read = deferred();
  const env = createAiUsageEnv(() => read.promise);
  env.api.closeAiModePanel();
  env.api.openAiModePanel();
  const reopened = env.document.querySelector('[data-toybaco-ai-usage]');
  assert.equal(env.usageCalls.length, 1, 'reopening during a read must reuse the request');
  assert.equal(reopened.getAttribute('aria-busy'), 'true');
  assert.match(collectText(reopened), /利用状況を確認しています/);
  read.resolve(usageResponse());
  await flush();
  assert.equal(reopened.querySelector('[data-toybaco-ai-usage-value]').textContent, '100 / 500 件');
}

for (const [overrides, expected, meterHidden] of [
  [{ used: 499, reserved: 1, remaining: 0, reason: 'limit_reached' }, /残り 0 件 · 処理中 1 件/, false],
  [{ limit: null, remaining: null }, /利用上限なし/, true],
  [{ used: 1200, reserved: 0, limit: 500, remaining: 0, reason: 'limit_reached' }, /1,200 \/ 500 件/, false],
]) {
  const env = createAiUsageEnv(() => Promise.resolve(usageResponse(overrides)));
  await flush();
  assert.match(collectText(env.usageCard), expected);
  assert.equal(env.usageCard.querySelector('[data-toybaco-ai-usage-meter]').hidden, meterHidden);
  if (overrides.remaining === 0) assert.match(collectText(env.usageCard), /現在、利用できる残り枠がありません/);
}

for (const invalid of [
  { used: -1 }, { used: '100' }, { limit: undefined }, { limit: null, remaining: 20 },
  { resets_at: '1' }, { resets_at: 'invalid' }, { period: '2026-99' },
  { reason: 'unexpected_code' }, { enabled: true, reason: 'disabled' },
]) {
  const env = createAiUsageEnv(() => Promise.resolve(usageResponse(invalid)));
  await flush();
  assert.equal(env.usageCard.getAttribute('data-toybaco-ai-usage-state'), 'error');
  assert.equal(env.usageCard.querySelector('[data-toybaco-ai-usage-value]').textContent, '');
  assert.equal(env.document.querySelector('[data-toybaco-ai-mode-bar]').querySelector('[data-toybaco-ai-mode="draft"]').disabled, true, 'malformed usage must not enable composer mode changes');
  assert.doesNotMatch(collectText(env.usageCard), /unexpected_code|invalid/);
}

{
  const accountA = deferred();
  const accountB = deferred();
  const env = createAiUsageEnv((url) => String(url).endsWith('=1') ? accountA.promise : accountB.promise);
  env.window.location.pathname = '/app/accounts/2/inbox';
  env.api.inject();
  env.api.openAiModePanel();
  const cardB = env.document.querySelector('[data-toybaco-ai-usage]');
  accountB.resolve(usageResponse({ used: 400, reserved: 0, remaining: 100 }));
  await flush();
  accountA.resolve(usageResponse());
  await flush();
  assert.equal(cardB.getAttribute('data-account'), '2');
  assert.equal(cardB.querySelector('[data-toybaco-ai-usage-value]').textContent, '400 / 500 件', 'late usage from another tenant must not repaint this tenant');
}

{
  const stalled = deferred();
  const timers = [];
  const env = createAiUsageEnv(() => stalled.promise, {
    setTimeout(fn, ms) { const timer = { fn, ms }; timers.push(timer); return timer; },
    clearTimeout() {},
  });
  timers.filter(timer => timer.ms === 10000).at(-1).fn();
  await flush();
  assert.equal(env.usageCard.getAttribute('data-toybaco-ai-usage-state'), 'error');
  stalled.resolve(usageResponse());
  await flush();
  assert.equal(env.usageCard.querySelector('[data-toybaco-ai-usage-value]').textContent, '', 'a late timed-out response cannot restore stale usage');
}

// The stock settings header count changes only after the agents store accepts a save/delete.
// Exercise the shipped seat script through DOM observers and native navigation events.
const seatPath = path.join(root, 'overlay/app/public/brand-assets/toybaco-agent-seat.js');
const seatSource = fs.readFileSync(seatPath, 'utf8');
function loadSeatUi(fetchImpl, nativeDisabled = false) {
  function element(tag) {
    const node = createDomNode(tag);
    let text = '';
    Object.defineProperty(node, 'textContent', {
      get() { return text; },
      set(value) { text = String(value); node.children.forEach(child => { child.parentElement = null; }); node.children.length = 0; },
    });
    return node;
  }
  const body = element('body');
  const main = element('main');
  const actions = element('div');
  const count = element('span');
  count.textContent = '1 エージェント';
  const add = element('button');
  add.textContent = '担当者を追加';
  add.disabled = nativeDisabled;
  if (nativeDisabled) add.setAttribute('aria-disabled', 'true');
  actions.appendChild(count);
  actions.appendChild(add);
  body.appendChild(actions);
  body.appendChild(main);
  const timers = new Set();
  const observers = [];
  const windowEvents = {};
  const documentEvents = {};
  const calls = [];
  const window = {
    location: { pathname: '/app/accounts/5/settings/agents' },
    setTimeout(fn, ms) { const timer = { fn, ms }; timers.add(timer); return timer; },
    clearTimeout(timer) { timers.delete(timer); },
    addEventListener(type, fn) { windowEvents[type] = fn; },
  };
  const document = {
    body, readyState: 'complete', hidden: false,
    createElement: element,
    querySelector: selector => body.querySelector(selector),
    querySelectorAll: selector => body.querySelectorAll(selector),
    addEventListener(type, fn) { documentEvents[type] = fn; },
  };
  const history = { pushState() {}, replaceState() {} };
  vm.runInNewContext(seatSource, {
    window, document, history, WeakMap,
    MutationObserver: class { constructor(fn) { observers.push(fn); } observe() {} },
    fetch(url, options) { calls.push({ url, options }); return fetchImpl(url, options); },
  }, { filename: seatPath });
  return {
    window, document, history, count, add, calls,
    mutate() { observers.forEach(fn => fn([])); },
    runTimers(ms = 80) { [...timers].filter(t => t.ms === ms).forEach(t => { timers.delete(t); t.fn(); }); },
    focus() { windowEvents.focus?.(); },
    visibility() { documentEvents.visibilitychange?.(); },
    banner() { return collectText(body.querySelector('[data-toybaco-agent-seat-banner]')); },
  };
}
function seatResponse(count, capped = true) {
  return Promise.resolve({ ok: true, json: async () => ({ capped, at_limit: capped && count >= 3, title: '利用は3名まで', message: `現在${count}名が利用しています。` }) });
}
{
  let saved = 1;
  const env = loadSeatUi(() => seatResponse(saved));
  env.runTimers(); await flush();
  assert.match(env.banner(), /現在1名/);
  saved = 2; env.count.textContent = '2 エージェント'; env.mutate(); env.runTimers(); await flush();
  assert.match(env.banner(), /現在2名/, 'same-route successful addition must refresh the seat banner');
  saved = 3; env.count.textContent = '3 エージェント'; env.mutate(); env.runTimers(); await flush();
  assert.equal(env.add.disabled, true);
  saved = 2; env.count.textContent = '2 エージェント'; env.mutate(); env.runTimers(); await flush();
  assert.match(env.banner(), /現在2名/, 'successful deletion must refresh and unlock only the overlay lock');
  assert.equal(env.add.disabled, false);
  assert.equal(env.add.getAttribute('aria-disabled'), null);
  for (let i = 0; i < 100; i += 1) env.mutate();
  env.runTimers(); await flush();
  assert.equal(env.calls.length, 4, 'unrelated DOM/redraw/search changes must not fetch');
  assert.ok(env.calls.every(call => call.options.method === 'GET' && call.options.credentials === 'same-origin'));
}
{
  const pending = deferred();
  const env = loadSeatUi(() => env.calls.length === 1 ? pending.promise : seatResponse(3));
  env.runTimers();
  env.count.textContent = '2 エージェント'; env.mutate(); env.runTimers();
  env.count.textContent = '3 エージェント'; env.mutate(); env.runTimers();
  assert.equal(env.calls.length, 1, 'same-account inflight reads coalesce');
  pending.resolve(await seatResponse(1)); await flush();
  assert.doesNotMatch(env.banner(), /現在1名/, 'an obsolete read cannot repaint the saved count');
  env.runTimers(); await flush();
  assert.equal(env.calls.length, 2, 'one trailing read captures the latest successful mutations');
  assert.match(env.banner(), /現在3名/);
}
{
  const accountA = deferred();
  const env = loadSeatUi(url => url.endsWith('=5') ? accountA.promise : seatResponse(2));
  env.runTimers();
  env.window.location.pathname = '/app/accounts/6/settings/agents';
  env.history.pushState(); env.runTimers(); await flush();
  assert.match(env.banner(), /現在2名/);
  accountA.resolve(await seatResponse(3)); await flush();
  assert.match(env.banner(), /現在2名/, 'late previous-account reads cannot change this account');
  assert.equal(env.add.disabled, false);
}
{
  const env = loadSeatUi(() => seatResponse(1));
  env.runTimers(); await flush();
  env.focus(); env.visibility(); env.runTimers(); await flush();
  assert.equal(env.calls.length, 2, 'focus/visible return share one confirmation without polling');
  env.document.hidden = true; env.visibility(); env.focus(); env.runTimers(); await flush();
  assert.equal(env.calls.length, 2);
  env.window.location.pathname = '/app/accounts/5/inbox'; env.history.pushState();
  assert.equal(env.document.querySelector('[data-toybaco-agent-seat-banner]'), null);
  assert.equal(env.add.disabled, false);
}
for (const fail of [() => Promise.reject(new Error('offline')), () => Promise.resolve({ ok: false }), () => Promise.resolve({ ok: true, json: async () => ({}) })]) {
  let broken = false;
  const env = loadSeatUi(() => broken ? fail() : seatResponse(1));
  env.runTimers(); await flush();
  broken = true; env.focus(); env.runTimers(); await flush();
  assert.match(env.banner(), /確認できませんでした/);
  assert.doesNotMatch(env.banner(), /現在1名/);
  assert.equal(env.add.disabled, true);
  const count = env.calls.length; env.mutate(); env.runTimers(); await flush();
  assert.equal(env.calls.length, count, 'errors must not start a retry loop');
  broken = false; env.focus(); env.runTimers(); await flush();
  assert.equal(env.add.disabled, false);
}
{
  const env = loadSeatUi(() => seatResponse(1), true);
  env.runTimers(); await flush();
  assert.equal(env.add.disabled, true, 'native disabled must survive overlay unlock');
  assert.equal(env.add.getAttribute('aria-disabled'), 'true');
}
{
  const pending = deferred();
  const env = loadSeatUi(() => pending.promise);
  env.runTimers(); env.runTimers(10000); await flush();
  assert.match(env.banner(), /確認できませんでした/);
  pending.resolve(await seatResponse(1)); await flush();
  assert.doesNotMatch(env.banner(), /現在1名/, 'timed-out reads cannot restore stale counts');
}

console.log('TOYBACO_CHATWOOT_POST_ENTRY=PASS origin=dynamic invalid=fail-closed paths=allowlisted posting-status=fail-open stock-nav=hidden first-paint=retry in-app-tab=main-area posting-vs-billing=distinct slash-canned=first-keypress ai-modes=confirmed-readback ai-usage=server-confirmed tenant-races=isolated');
