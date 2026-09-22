import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import vm from 'node:vm';

const [overlay, upstream, dependencies] = process.argv.slice(2).map(path => resolve(path));
assert(overlay && upstream && dependencies, 'Pass overlay, upstream and dependency roots');
const require = createRequire(resolve(dependencies, 'package.json'));
require('fake-indexeddb/auto');
const { openDB, deleteDB } = require('idb');
const versionSource = readFileSync(resolve(upstream, 'app/javascript/dashboard/helper/CacheHelper/version.js'), 'utf8');
const version = Number(versionSource.match(/INBOX_CACHE_INVALIDATION_VERSION = (\d+)/)[1]);
const managerSource = readFileSync(resolve(overlay, 'app/javascript/dashboard/helper/CacheHelper/DataManager.js'), 'utf8')
  .replace(/^import .*;\n/gm, '').replace('export class DataManager', 'class DataManager');
const apiSource = readFileSync(resolve(upstream, 'app/javascript/dashboard/api/CacheEnabledApiClient.js'), 'utf8')
  .replace(/^import .*;\n/gm, '').replace('export default CacheEnabledApiClient;', '');
const storage = new Map();
const requests = [];
class ApiClient {
  constructor(resource, { accountId }) { this.resource = resource; this.accountIdFromRoute = accountId; }
  get url() { return `/api/v1/accounts/${this.accountIdFromRoute}/${this.resource}`; }
}
const context = vm.createContext({
  openDB, DATA_VERSION: version, INBOX_CACHE_INVALIDATION_VERSION: version,
  localStorage: { getItem: k => storage.get(k) ?? null, setItem: (k, v) => storage.set(k, v) },
  ApiClient,
  axios: { get: async url => {
    requests.push(url);
    return url.endsWith('/cache_keys')
      ? { data: { cache_keys: { inbox: 'current-key' } } }
      : { data: { payload: [{ id: 'network-result', account: url.split('/')[4] }] } };
  } },
});
const DataManager = vm.runInContext(`${managerSource}\nDataManager`, context);
context.DataManager = DataManager;
const CacheClient = vm.runInContext(`${apiSource}\nCacheEnabledApiClient`, context);
class Inboxes extends CacheClient { get cacheModelName() { return 'inbox'; } }
const deadlines = new Set();
const bounded = promise => Promise.race([promise, new Promise((_, reject) => {
  const timer = setTimeout(() => reject(new Error('Cache operation did not settle')), 1500);
  deadlines.add(timer);
})]);
const tick = () => new Promise(resolveTick => setImmediate(resolveTick));
const connections = [];
const remember = db => { connections.push(db); return db; };
const legacy = async account => remember(await openDB(`cw-store-${account}`, version - 1, {
  upgrade(db) {
    db.createObjectStore('cache-keys');
    for (const name of ['inbox', 'label', 'team', 'canned_response']) db.createObjectStore(name, { keyPath: 'id' });
  },
}));
const accounts = ['blocked', 'concurrent', 'invalidation', 'future', 'other'];
try {
  // Real IDB blocked events, keeping a pre-update connection open throughout.
  const old = await legacy('blocked');
  await old.put('inbox', { id: 'obsolete-secret' });
  await old.put('cache-keys', 'current-key', 'inbox');
  const client = new Inboxes('inboxes', { accountId: 'blocked' });
  assert.equal((await bounded(client.get(true))).data.payload[0].id, 'network-result');
  assert.equal(client.dataManager.db, null);
  assert.equal(client.dataManager.cacheDisabled, true);
  assert.deepEqual(requests, ['/api/v1/accounts/blocked/inboxes']);
  assert.equal((await bounded(client.get(true))).data.payload[0].id, 'network-result');
  assert.equal((await bounded(client.refetchAndCommit('new-key'))).data.payload[0].id, 'network-result');
  assert.equal(requests.length, 3, 'repeat reads and cache writes must settle without opening more blocked requests');

  // Another account must still use its own cache, with no obsolete tenant rows.
  client.accountIdFromRoute = 'other';
  const other = await bounded(client.get(true));
  assert.equal(other.data.payload[0].account, 'other');
  const otherManager = client.dataManager;
  remember(otherManager.db);
  assert.equal(otherManager.cacheDisabled, false);
  const beforeCache = requests.length;
  assert.equal((await bounded(client.get(true))).data.payload[0].account, 'other');
  assert.equal(requests.length, beforeCache + 1, 'valid cache only checks cache key');

  // The abandoned open must close itself once the old tab releases the lock.
  old.close();
  await bounded(deleteDB('cw-store-blocked'));

  const concurrent = new DataManager('concurrent');
  const [first, second] = await bounded(Promise.all([concurrent.initDb(), concurrent.initDb()]));
  remember(first);
  assert.equal(first, second, 'concurrent reads share one opening connection');

  // Preserve the upstream security invalidation while keeping unrelated caches.
  const outdated = await legacy('invalidation');
  await outdated.put('inbox', { id: 'stale-inbox' });
  await outdated.put('label', { id: 'retained-label' });
  await outdated.put('cache-keys', 'old-key', 'inbox');
  outdated.close();
  const migrated = new DataManager('invalidation');
  remember(await bounded(migrated.initDb()));
  assert.equal((await migrated.get({ modelName: 'inbox' })).length, 0);
  assert.equal(await migrated.getCacheKey('inbox'), undefined);
  assert.equal((await migrated.get({ modelName: 'label' }))[0].id, 'retained-label');

  // This version releases its own open handles for a later update.
  const future = new DataManager('future');
  remember(await bounded(future.initDb()));
  const next = remember(await bounded(openDB('cw-store-future', version + 1)));
  assert.equal(future.db, null);
  next.close();
  await assert.rejects(bounded(future.initDb()), { name: 'VersionError' });
  assert.equal(future.dbOpening, null);
  await tick();
  console.log('TOYBACO_CACHE_UPGRADE=PASS blocked-network-fallback repeated-read write-fallback account-isolation valid-cache late-close concurrent-open security-invalidation versionchange');
} finally {
  try {
    for (const db of connections) db.close();
    for (const account of accounts) await bounded(deleteDB(`cw-store-${account}`));
  } finally {
    for (const timer of deadlines) clearTimeout(timer);
  }
}
