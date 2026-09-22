import { openDB } from 'idb';
import { DATA_VERSION, INBOX_CACHE_INVALIDATION_VERSION } from './version';

export class DataManager {
  constructor(accountId) {
    this.modelsToSync = ['inbox', 'label', 'team', 'canned_response'];
    this.accountId = accountId;
    this.db = null;
    this.dbOpening = null;
    this.cacheDisabled = false;
  }

  async initDb() {
    if (this.cacheDisabled) throw new Error('Browser cache upgrade is blocked');
    if (this.db) return this.db;
    if (this.dbOpening) return this.dbOpening;
    const dbName = `cw-store-${this.accountId}`;
    let connection;
    let rejectBlocked;
    const blocked = new Promise((_, reject) => {
      rejectBlocked = reject;
    });
    const opening = openDB(dbName, DATA_VERSION, {
      // An older tab may hold this database open indefinitely. The API client
      // already falls back to the network when initDb rejects; never read the
      // obsolete cache or make the user close their other tabs to keep working.
      blocked: () => {
        this.cacheDisabled = true;
        rejectBlocked(new Error('Browser cache upgrade is blocked'));
      },
      blocking: () => {
        connection?.close();
        if (this.db === connection) this.db = null;
      },
      terminated: () => {
        if (this.db === connection) this.db = null;
      },
      upgrade(db, oldVersion, _newVersion, transaction) {
        const shouldInvalidateInboxCache =
          oldVersion > 0 && oldVersion < INBOX_CACHE_INVALIDATION_VERSION;

        if (shouldInvalidateInboxCache) {
          transaction.objectStore('inbox').clear();
          transaction.objectStore('cache-keys').delete('inbox');
        }

        // Existing databases already carry the stores added in earlier versions,
        // and createObjectStore throws on a name that is already taken.
        const createStore = (name, options) => {
          if (db.objectStoreNames.contains(name)) return;
          db.createObjectStore(name, options);
        };

        createStore('cache-keys');
        createStore('inbox', { keyPath: 'id' });
        createStore('label', { keyPath: 'id' });
        createStore('team', { keyPath: 'id' });
        createStore('canned_response', { keyPath: 'id' });
      },
    });

    // A blocked request can still finish when the old tab eventually closes.
    // Release that late connection instead of reviving this disabled cache.
    opening.then(
      db => {
        connection = db;
        if (this.cacheDisabled) db.close();
      },
      () => {}
    );
    this.dbOpening = Promise.race([opening, blocked]);
    try {
      this.db = await this.dbOpening;
      // Store the database name in LocalStorage
      const dbNames = JSON.parse(localStorage.getItem('cw-idb-names') || '[]');
      if (!dbNames.includes(dbName)) {
        dbNames.push(dbName);
        localStorage.setItem('cw-idb-names', JSON.stringify(dbNames));
      }
      return this.db;
    } finally {
      this.dbOpening = null;
    }
  }

  validateModel(name) {
    if (!name) throw new Error('Model name is not defined');
    if (!this.modelsToSync.includes(name)) {
      throw new Error(`Model ${name} is not defined`);
    }
    return true;
  }

  async replace({ modelName, data }) {
    this.validateModel(modelName);

    await this.db.clear(modelName);
    return this.push({ modelName, data });
  }

  async push({ modelName, data }) {
    this.validateModel(modelName);

    if (Array.isArray(data)) {
      const tx = this.db.transaction(modelName, 'readwrite');
      data.forEach(item => {
        tx.store.add(item);
      });
      await tx.done;
    } else {
      await this.db.add(modelName, data);
    }
  }

  async get({ modelName }) {
    this.validateModel(modelName);
    return this.db.getAll(modelName);
  }

  async setCacheKeys(cacheKeys) {
    Object.keys(cacheKeys).forEach(async modelName => {
      this.db.put('cache-keys', cacheKeys[modelName], modelName);
    });
  }

  async getCacheKey(modelName) {
    this.validateModel(modelName);

    return this.db.get('cache-keys', modelName);
  }
}
