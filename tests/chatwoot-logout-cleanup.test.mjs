import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import vm from 'node:vm';

const [overlay, upstream, dependencies] = process.argv
  .slice(2)
  .map(p => resolve(p));
const require = createRequire(resolve(dependencies, 'package.json'));
require('fake-indexeddb/auto');
const { openDB, deleteDB } = require('idb');
const source = path => readFileSync(resolve(overlay, path), 'utf8');
const strip = text =>
  text.replace(/^import [\s\S]*?;\n/gm, '').replace(/^export /gm, '');
const managerSource = strip(
  source('app/javascript/dashboard/helper/CacheHelper/DataManager.js')
);
const cleanupSource = strip(
  source('app/javascript/dashboard/helper/sessionCleanup.js')
);
const helpersSource = strip(
  source('app/javascript/dashboard/store/utils/api.js')
);
const authSource = strip(
  source('app/javascript/dashboard/api/auth.js')
).replace('default {', 'const auth = {');
const constants = readFileSync(
  resolve(upstream, 'app/javascript/dashboard/constants/localStorage.js'),
  'utf8'
).replace('export ', '');
const version = Number(
  readFileSync(
    resolve(upstream, 'app/javascript/dashboard/helper/CacheHelper/version.js'),
    'utf8'
  ).match(/INBOX_CACHE_INVALIDATION_VERSION = (\d+)/)[1]
);
const tick = () => new Promise(r => setImmediate(r));
const storage = () => {
  const object = {};
  Object.defineProperties(object, {
    getItem: { value: key => object[key] ?? null },
    setItem: {
      value: (key, value) => {
        object[key] = String(value);
      },
    },
    removeItem: {
      value: key => {
        delete object[key];
      },
    },
  });
  return object;
};
const node = () => ({
  children: [],
  style: {},
  setAttribute() {},
  focus() {},
  appendChild(child) {
    this.children.push(child);
  },
  replaceChildren() {
    this.children = [];
  },
});
const pending = 'cw-logout-pending';
const registry = 'cw-idb-names';
const makeTab = ({
  local = storage(),
  database = indexedDB,
  open = openDB,
  request,
} = {}) => {
  const body = node();
  const events = {};
  const cookies = new Map([['cw_d_session_info', 'fixture-token']]);
  const session = storage();
  const redirects = [];
  const win = {
    indexedDB: database,
    globalConfig: {},
    addEventListener: (name, callback) => {
      events[name] = callback;
    },
    set location(value) {
      redirects.push(value);
    },
  };
  const document = {
    body,
    createElement: node,
    getElementById: id => body.children.find(n => n.id === id),
  };
  const context = vm.createContext({
    window: win,
    document,
    localStorage: local,
    openDB: open,
    DATA_VERSION: version,
    INBOX_CACHE_INVALIDATION_VERSION: version,
    // Shorten only the failure bound; IDB itself is real asynchronous fake-indexeddb.
    setTimeout: (f, ms) => setTimeout(f, ms === 5000 ? 60 : ms),
    clearTimeout,
    queueMicrotask,
    console,
    fromUnixTime: value => new Date(value * 1000),
    differenceInDays: () => 1,
    Cookies: {
      set: (key, value) => cookies.set(key, value),
      get: key => cookies.get(key),
      remove: key => cookies.delete(key),
    },
    LocalStorage: {
      remove: key => {
        local.removeItem(key);
        local.removeItem(`${key}:ts`);
      },
    },
    SessionStorage: { remove: key => session.removeItem(key) },
    SESSION_STORAGE_KEYS: { IMPERSONATION_USER: 'impersonationUser' },
    emitter: { emit() {} },
    CHATWOOT_RESET: 'reset',
    ANALYTICS_RESET: 'analytics-reset',
    CHATWOOT_SET_USER: 'user',
    ANALYTICS_IDENTITY: 'identity',
    axios: { delete: request ?? (async () => ({ status: 200 })) },
    endPoints: () => ({ url: '/auth/sign_out' }),
  });
  vm.runInContext(
    `${constants}\n${managerSource}\n${cleanupSource}\n${helpersSource}\n${authSource}`,
    context
  );
  const api = vm.runInContext(
    '({ DataManager, stopBrowserCache, clearCookiesOnLogout, setAuthCredentials, isSessionEnding, auth })',
    context
  );
  return { ...api, local, session, events, cookies, redirects, body, context };
};
const names = async () => (await indexedDB.databases()).map(db => db.name);
let count = 0;
const run = async (name, test) => {
  await test();
  count += 1;
  console.log(`PASS ${name}`);
};

await run(
  'waits for server revocation, closes live caches, deletes only app databases and sensitive storage',
  async () => {
    let revoked;
    const tab = makeTab({
      request: () =>
        new Promise(r => {
          revoked = r;
        }),
    });
    const manager = new tab.DataManager('logout-a');
    await manager.initDb();
    await manager.push({
      modelName: 'inbox',
      data: { id: 1, synthetic: 'private-inbox' },
    });
    const unrelated = await openDB('unrelated-application');
    unrelated.close();
    [
      'draftMessages',
      'draftMessages:ts',
      'messageReplyTo',
      'recentSearches',
      'widgetBubble_42',
    ].forEach(key => tab.local.setItem(key, 'synthetic'));
    tab.local.setItem('color_scheme', 'dark');
    tab.session.setItem('impersonationUser', 'true');
    const result = tab.auth.logout();
    await tick();
    assert.equal(tab.isSessionEnding(), false);
    assert.equal(tab.cookies.has('cw_d_session_info'), true);
    revoked({ status: 200 });
    assert.equal((await result).status, 200);
    assert.equal(manager.db, null);
    assert.equal(manager.cacheDisabled, true);
    assert.equal((await names()).includes('cw-store-logout-a'), false);
    assert.equal((await names()).includes('unrelated-application'), true);
    assert.equal(tab.local.getItem('color_scheme'), 'dark');
    assert.equal(tab.local.getItem('recentSearches'), null);
    assert.equal(tab.local.getItem('messageReplyTo'), null);
    assert.equal(tab.local.getItem('draftMessages:ts'), null);
    assert.equal(tab.local.getItem('widgetBubble_42'), null);
    assert.equal(tab.session.getItem('impersonationUser'), null);
    assert.equal(tab.cookies.size, 0);
    assert.equal(tab.local.getItem(registry), null);
    assert.equal(tab.local.getItem(pending), null);
    assert.deepEqual(tab.redirects, ['/']);
    await assert.rejects(
      new tab.DataManager('logout-after').initDb(),
      /unavailable/
    );
    assert.throws(
      () => tab.setAuthCredentials({ headers: {}, data: { data: {} } }),
      /ログアウト/
    );
    await deleteDB('unrelated-application');
  }
);

await run(
  'blocked old tab retains pending marker and retry list without successful redirect',
  async () => {
    const old = await openDB('cw-store-blocking-tab', 1);
    const tab = makeTab();
    assert.equal(await tab.clearCookiesOnLogout(), false);
    assert.equal(tab.redirects.length, 0);
    assert(tab.local.getItem(pending));
    assert(
      JSON.parse(tab.local.getItem(registry)).includes('cw-store-blocking-tab')
    );
    assert.equal(tab.cookies.size, 0);
    assert.equal(tab.body.children[0].children[1].textContent, '再試行');
    old.close();
    await tick();
    assert.equal(await tab.clearCookiesOnLogout(), true);
    assert.equal((await names()).includes('cw-store-blocking-tab'), false);
  }
);

await run(
  'late opening closes after logout and cannot recreate a usable cache',
  async () => {
    let finish;
    const tab = makeTab({
      open: () =>
        new Promise(r => {
          finish = r;
        }),
    });
    const manager = new tab.DataManager('late');
    const opening = manager.initDb();
    const rejected = assert.rejects(opening, /unavailable/);
    const ended = tab.clearCookiesOnLogout();
    let closed = false;
    finish({
      close() {
        closed = true;
      },
    });
    await rejected;
    assert.equal(await ended, true);
    assert.equal(closed, true);
    assert.equal(manager.db, null);
  }
);

await run(
  'IDB error keeps failure state and retries without duplicate logout',
  async () => {
    let fail = true;
    const tab = makeTab({
      database: {
        databases: async () => [{ name: 'cw-store-failed' }],
        deleteDatabase: name => {
          if (!fail) return indexedDB.deleteDatabase(name);
          const request = {};
          queueMicrotask(() => request.onerror());
          return request;
        },
      },
    });
    assert.equal(await tab.clearCookiesOnLogout(), false);
    assert.equal(tab.redirects.length, 0);
    assert(tab.local.getItem(pending));
    fail = false;
    assert.equal(await tab.clearCookiesOnLogout(), true);
  }
);

await run(
  'registry fallback works when enumeration is unsupported',
  async () => {
    const local = storage();
    local.setItem(registry, JSON.stringify(['cw-store-fallback', 'unrelated']));
    const db = await openDB('cw-store-fallback');
    db.close();
    const tab = makeTab({
      local,
      database: { deleteDatabase: name => indexedDB.deleteDatabase(name) },
    });
    assert.equal(await tab.clearCookiesOnLogout(), true);
    assert.equal((await names()).includes('cw-store-fallback'), false);
  }
);

await run('corrupt registry requires successful enumeration', async () => {
  const local = storage();
  local.setItem(registry, '{broken');
  const tab = makeTab({
    local,
    database: { deleteDatabase: name => indexedDB.deleteDatabase(name) },
  });
  assert.equal(await tab.clearCookiesOnLogout(), false);
  assert.equal(tab.redirects.length, 0);
  const repair = makeTab({ local });
  await tick();
  await tick();
  assert.equal(repair.redirects.length, 1);
  assert.equal(local.getItem(pending), null);
});

await run(
  'hanging enumeration is bounded and uses the retained registry',
  async () => {
    const local = storage();
    local.setItem(registry, JSON.stringify(['cw-store-enum-timeout']));
    const db = await openDB('cw-store-enum-timeout');
    db.close();
    const tab = makeTab({
      local,
      database: {
        databases: () => new Promise(() => {}),
        deleteDatabase: name => indexedDB.deleteDatabase(name),
      },
    });
    assert.equal(await tab.clearCookiesOnLogout(), true);
    assert.equal((await names()).includes('cw-store-enum-timeout'), false);
  }
);

await run(
  'other tab receives logout and closes its connection before deletion completes',
  async () => {
    const local = storage();
    const first = makeTab({ local });
    const second = makeTab({ local });
    const manager = new second.DataManager('peer');
    await manager.initDb();
    const one = first.clearCookiesOnLogout();
    second.events.storage({ key: pending, newValue: local.getItem(pending) });
    assert.equal(await one, true);
    await tick();
    await tick();
    assert.equal(second.cookies.size, 0);
    assert.equal(manager.db, null);
    assert.equal(manager.cacheDisabled, true);
    assert.equal(second.redirects.length, 1);
    assert.equal((await names()).includes('cw-store-peer'), false);
  }
);

await run(
  'reload retries incomplete cleanup before accepting credentials',
  async () => {
    const local = storage();
    local.setItem(pending, 'prior-cleanup');
    const db = await openDB('cw-store-reload');
    db.close();
    const tab = makeTab({ local });
    assert.throws(
      () => tab.setAuthCredentials({ headers: {}, data: { data: {} } }),
      /ログアウト/
    );
    await tick();
    await tick();
    await tick();
    assert.equal(tab.redirects.length, 1);
    assert.equal((await names()).includes('cw-store-reload'), false);
  }
);

await run(
  '401 still clears data while network/server failure does not claim revocation',
  async () => {
    const expired = makeTab({
      request: async () => {
        throw { response: { status: 401 } };
      },
    });
    assert.equal((await expired.auth.logout()).status, 401);
    assert.equal(expired.cookies.size, 0);
    const failure = makeTab({
      request: async () => {
        throw { response: { status: 500 } };
      },
    });
    await assert.rejects(failure.auth.logout());
    assert.equal(failure.cookies.size, 1);
    assert.equal(failure.redirects.length, 0);
    assert.equal(failure.isSessionEnding(), false);
  }
);
console.log(`TOYBACO_LOGOUT_CLEANUP=PASS ${count} behavioral scenarios`);
