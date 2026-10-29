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
// Upstream push registration (not overlaid): subscribe and post to the server.
const pushHelperSource = strip(
  readFileSync(
    resolve(upstream, 'app/javascript/dashboard/helper/pushHelper.js'),
    'utf8'
  )
);
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
// The 1500ms push-unsubscribe bound runs as this many ms inside the test VM.
const PUSH_BOUND = 150;
const PUSH_RESTORE = 'toybaco:push-restore';
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
  navigator,
  page = { unloaded: false },
  notification,
  posted = [],
  postFailures = [],
} = {}) => {
  const body = node();
  const events = {};
  const cookies = new Map([['cw_d_session_info', 'fixture-token']]);
  const session = storage();
  const redirects = [];
  const win = {
    indexedDB: database,
    sessionStorage: session,
    navigator,
    Notification: notification,
    chatwootConfig: { vapidPublicKey: 'fixture-vapid-key' },
    globalConfig: {},
    addEventListener: (name, callback) => {
      events[name] = callback;
    },
    set location(value) {
      redirects.push(value);
      // Navigation unloads the document: pending page work never resumes.
      page.unloaded = true;
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
    // Shorten only the bounds (IDB failure, push unsubscribe); IDB itself is
    // real asynchronous fake-indexeddb.
    setTimeout: (f, ms) =>
      setTimeout(f, ms === 5000 ? 60 : ms === 1500 ? PUSH_BOUND : ms),
    clearTimeout,
    queueMicrotask,
    // Upstream registerSubscription logs the failures the restore test injects.
    console: {
      ...console,
      error: (...args) => {
        if (!String(args[0]).startsWith('Push subscription registration failed')) console.error(...args);
      },
    },
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
    navigator,
    btoa,
    useAlert: () => {},
    NotificationSubscriptions: {
      create: async payload => {
        if (postFailures.shift()) throw new Error('server unavailable');
        posted.push(payload);
      },
    },
  });
  vm.runInContext(
    `${constants}\n${managerSource}\n${cleanupSource}\n${helpersSource}\n${authSource}\n${pushHelperSource}`,
    context
  );
  const api = vm.runInContext(
    `({ DataManager, stopBrowserCache, clearCookiesOnLogout, setAuthCredentials, isSessionEnding, auth, setUser,
      registerSubscription,
      unsubscribeBrowserPush: typeof unsubscribeBrowserPush === 'function' ? unsubscribeBrowserPush : undefined,
      pendingBrowserPushRestore: typeof pendingBrowserPushRestore === 'function' ? pendingBrowserPushRestore : undefined,
      restoreBrowserPushOnLogin: typeof restoreBrowserPushOnLogin === 'function' ? restoreBrowserPushOnLogin : undefined })`,
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
// A browser push subscription that the signed-out browser keeps would go on
// showing customer message previews. The service worker answers after a delay,
// and a continuation that would resume after navigation never runs (the page
// is gone), so only an unsubscribe that logout waits for actually happens.
const pushNavigator = (page, calls, { delay = 25, unsubscribe = async () => true, registration } = {}) => {
  const later = value => new Promise(r => setTimeout(() => r(value), delay));
  const alive = () => (page.unloaded ? new Promise(() => {}) : undefined);
  return {
    serviceWorker: {
      getRegistration:
        registration ??
        (async () => {
          calls.registration += 1;
          await later();
          await alive();
          return {
            pushManager: {
              getSubscription: async () => {
                calls.subscription += 1;
                await later();
                await alive();
                return {
                  unsubscribe: async () => {
                    calls.unsubscribe += 1;
                    calls.unloadedAtUnsubscribe = page.unloaded;
                    return unsubscribe();
                  },
                };
              },
            },
          };
        }),
    },
  };
};
const within = (promise, ms, label) =>
  Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error(`${label} did not finish within ${ms}ms`)), ms)),
  ]);

await run(
  'logout waits for a delayed Web Push unsubscribe, runs it once before navigation and removes only toybaco session keys',
  async () => {
    const page = { unloaded: false };
    const calls = { registration: 0, subscription: 0, unsubscribe: 0 };
    const tab = makeTab({ page, navigator: pushNavigator(page, calls) });
    tab.session.setItem('toybaco:ai-reply-draft:1:2', '1');
    tab.session.setItem('toybaco:ai-reply-draft:7:9', '1');
    tab.session.setItem('impersonationUser', 'true');
    tab.session.setItem('unrelated-session-key', 'kept');
    assert.equal(await tab.clearCookiesOnLogout(), true);
    assert.deepEqual(calls, { registration: 1, subscription: 1, unsubscribe: 1, unloadedAtUnsubscribe: false });
    assert.deepEqual(tab.redirects, ['/']);
    assert.equal(await tab.unsubscribeBrowserPush(), true);
    assert.equal(calls.unsubscribe, 1);
    assert.deepEqual(Object.keys(tab.session), ['unrelated-session-key']);
    assert.equal(tab.cookies.size, 0);
  }
);

await run(
  'a failed cleanup that keeps the page still unsubscribes Web Push once',
  async () => {
    const page = { unloaded: false };
    const calls = { registration: 0, subscription: 0, unsubscribe: 0 };
    const blocking = await openDB('cw-store-push-blocking-tab', 1);
    const tab = makeTab({ page, navigator: pushNavigator(page, calls) });
    assert.equal(await tab.clearCookiesOnLogout(), false);
    await new Promise(r => setTimeout(r, 100));
    assert.equal(tab.redirects.length, 0);
    assert.equal(calls.unsubscribe, 1);
    blocking.close();
    await tick();
    assert.equal(await tab.clearCookiesOnLogout(), true);
    assert.deepEqual(tab.redirects, ['/']);
    assert.equal(calls.unsubscribe, 1);
  }
);

await run(
  'rejected, denied, hanging, too slow or unsupported push cleanup still finishes logout within the bound',
  async () => {
    const rejectedPage = { unloaded: false };
    const calls = { registration: 0, subscription: 0, unsubscribe: 0 };
    const rejected = makeTab({
      page: rejectedPage,
      navigator: pushNavigator(rejectedPage, calls, {
        unsubscribe: async () => {
          throw new Error('push service unavailable');
        },
      }),
    });
    assert.equal(await rejected.clearCookiesOnLogout(), true);
    assert.equal(calls.unsubscribe, 1);
    assert.equal(calls.unloadedAtUnsubscribe, false);
    assert.equal(rejected.local.getItem(PUSH_RESTORE), null);
    assert.equal(await rejected.unsubscribeBrowserPush(), false);
    assert.deepEqual(rejected.redirects, ['/']);
    assert.equal(rejected.cookies.size, 0);
    const deniedPage = { unloaded: false };
    const denied = makeTab({
      page: deniedPage,
      navigator: pushNavigator(deniedPage, calls, {
        registration: async () => {
          throw new Error('denied');
        },
      }),
    });
    assert.equal(await denied.clearCookiesOnLogout(), true);
    assert.equal(await denied.unsubscribeBrowserPush(), false);
    assert.deepEqual(denied.redirects, ['/']);
    for (const [label, delay] of [['hanging', null], ['too slow', PUSH_BOUND * 4]]) {
      const page = { unloaded: false };
      const slowCalls = { registration: 0, subscription: 0, unsubscribe: 0 };
      const navigator =
        delay === null
          ? { serviceWorker: { getRegistration: () => new Promise(() => {}) } }
          : pushNavigator(page, slowCalls, { delay });
      const tab = makeTab({ page, navigator });
      const started = Date.now();
      assert.equal(await within(tab.clearCookiesOnLogout(), PUSH_BOUND * 10, `${label} logout`), true);
      const elapsed = Date.now() - started;
      assert(elapsed >= PUSH_BOUND - 10, `${label}: navigation waited only ${elapsed}ms`);
      assert.deepEqual(tab.redirects, ['/']);
      assert.equal(tab.cookies.size, 0);
      assert.equal(slowCalls.unsubscribe, 0);
    }
    const unsupported = makeTab();
    assert.equal(await unsupported.clearCookiesOnLogout(), true);
    assert.equal(await unsupported.unsubscribeBrowserPush(), undefined);
    assert.deepEqual(unsupported.redirects, ['/']);
  }
);
// After logout removed the subscription, the next login (App.vue
// initializeAccount) subscribes again through the upstream registration and
// posts it to the server, for whoever signs in (as upstream re-binds a kept
// subscription). The marker holds no user data.
const loginNavigator = (subscribed, existing = null, subscribeFailures = []) => {
  const registration = {
    pushManager: {
      getSubscription: async () => existing,
      subscribe: async options => {
        subscribed.push(options);
        if (subscribeFailures.shift()) throw new Error('push service unavailable');
        return {
          endpoint: 'https://push.example.test/endpoint-1',
          getKey: name => new TextEncoder().encode(`${name}-key`).buffer,
        };
      },
    },
  };
  return {
    registration,
    navigator: { serviceWorker: { ready: Promise.resolve(registration) } },
  };
};
const storedValues = local =>
  Object.keys(local).map(key => [key, local.getItem(key)]);

await run(
  'logout leaves an identifier-free marker and the next login subscribes Web Push again and registers it with the server',
  async () => {
    const page = { unloaded: false };
    const calls = { registration: 0, subscription: 0, unsubscribe: 0 };
    const local = storage();
    const out = makeTab({ page, local, navigator: pushNavigator(page, calls) });
    out.setUser({ id: 42, email: 'staff-42@example.test', name: 'Fixture Staff' });
    assert.equal(await out.clearCookiesOnLogout(), true);
    assert.equal(calls.unsubscribe, 1);
    assert.deepEqual(storedValues(local), [[PUSH_RESTORE, '1']]);
    const subscribed = [];
    const posted = [];
    const { registration, navigator } = loginNavigator(subscribed);
    const login = makeTab({ local, navigator, notification: { permission: 'granted' }, posted });
    await login.restoreBrowserPushOnLogin(registration, login.registerSubscription);
    await tick();
    await tick();
    assert.equal(subscribed.length, 1);
    assert.equal(subscribed[0].applicationServerKey, 'fixture-vapid-key');
    assert.deepEqual(
      posted.map(payload => [payload.subscription_type, payload.subscription_attributes.endpoint]),
      [['browser_push', 'https://push.example.test/endpoint-1']]
    );
    assert.equal(local.getItem(PUSH_RESTORE), null);
    // Consumed: the following start does not subscribe again.
    let registered = 0;
    const count = () => {
      registered += 1;
    };
    await login.restoreBrowserPushOnLogin(loginNavigator([]).registration, count);
    assert.equal(registered, 0);
    // An existing subscription is registered for whoever signs in (as upstream).
    const existing = loginNavigator([], { endpoint: 'https://push.example.test/existing' });
    await login.restoreBrowserPushOnLogin(existing.registration, count);
    assert.equal(registered, 1);
  }
);

await run('no restore without the notification permission, and the marker is cleared', async () => {
  for (const permission of ['default', 'denied', undefined]) {
    const local = storage();
    local.setItem(PUSH_RESTORE, '1');
    const tab = makeTab({ local, notification: permission && { permission } });
    let registered = 0;
    await tab.restoreBrowserPushOnLogin(loginNavigator([]).registration, () => {
      registered += 1;
    });
    assert.equal(registered, 0, `permission ${permission}`);
    assert.equal(local.getItem(PUSH_RESTORE), null, `permission ${permission}`);
  }
  const granted = storage();
  const tab = makeTab({ local: granted, notification: { permission: 'granted' } });
  assert.equal(tab.pendingBrowserPushRestore(), false);
  granted.setItem(PUSH_RESTORE, 'unexpected');
  assert.equal(tab.pendingBrowserPushRestore(), false);
});

await run(
  'a failed restore keeps the marker and a later startup restores push without touching preferences',
  async () => {
    const local = storage();
    local.setItem(PUSH_RESTORE, '1');
    const subscribed = [];
    const posted = [];
    // 1st startup: the push service rejects subscribe(); upstream swallows it.
    const first = loginNavigator(subscribed, null, [true]);
    const tab1 = makeTab({ local, navigator: first.navigator, notification: { permission: 'granted' }, posted });
    await tab1.restoreBrowserPushOnLogin(first.registration, tab1.registerSubscription);
    await tick();
    await tick();
    assert.deepEqual([subscribed.length, posted.length, local.getItem(PUSH_RESTORE)], [1, 0, '1']);
    // 2nd startup: subscribed, but the server POST fails; still not registered.
    const second = loginNavigator(subscribed);
    const tab2 = makeTab({ local, navigator: second.navigator, notification: { permission: 'granted' }, posted, postFailures: [true] });
    await tab2.restoreBrowserPushOnLogin(second.registration, tab2.registerSubscription);
    await tick();
    await tick();
    assert.deepEqual([subscribed.length, posted.length, local.getItem(PUSH_RESTORE)], [2, 0, '1']);
    // 3rd startup: subscribed and posted; the marker is gone only now.
    const third = loginNavigator(subscribed);
    const tab3 = makeTab({ local, navigator: third.navigator, notification: { permission: 'granted' }, posted });
    await tab3.restoreBrowserPushOnLogin(third.registration, tab3.registerSubscription);
    await tick();
    await tick();
    assert.deepEqual([subscribed.length, posted.length, local.getItem(PUSH_RESTORE)], [3, 1, null]);
  }
);

await run('App.vue restores Web Push through restoreBrowserPushOnLogin at authenticated startup', async () => {
  const app = source('app/javascript/dashboard/App.vue');
  assert.match(app, /import \{ restoreBrowserPushOnLogin \} from 'dashboard\/store\/utils\/api';/);
  assert.match(
    app,
    /verifyServiceWorkerExistence\(registration =>\s*restoreBrowserPushOnLogin\(registration, registerSubscription\)\s*\)/
  );
});
console.log(`TOYBACO_LOGOUT_CLEANUP=PASS ${count} behavioral scenarios`);
