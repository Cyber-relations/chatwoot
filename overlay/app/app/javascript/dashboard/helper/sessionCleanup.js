// This marker contains no identity or credential data. Keep it until every
// application database deletion succeeds, including across reloads and tabs.
const PENDING_KEY = 'cw-logout-pending';
const DATABASES_KEY = 'cw-idb-names';
const DATABASE_PREFIX = 'cw-store-';
let ending = false;
let cleanupPromise;
let channel;

const readPending = () => {
  try {
    return localStorage.getItem(PENDING_KEY);
  } catch {
    return null;
  }
};

export const isSessionEnding = () => ending || Boolean(readPending());

const showStatus = (failed, retry) => {
  if (!document.body) return;
  let panel = document.getElementById('toybaco-session-cleanup');
  if (!panel) {
    panel = document.createElement('section');
    panel.id = 'toybaco-session-cleanup';
    panel.setAttribute('role', 'alert');
    panel.style.cssText =
      'position:fixed;inset:0;z-index:2147483647;background:#fff;color:#171717;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:24px;gap:16px;';
    Array.from(document.body.children).forEach(child => {
      child.inert = true;
    });
    panel.tabIndex = -1;
    document.body.appendChild(panel);
    panel.focus();
  }
  panel.replaceChildren();
  const message = document.createElement('p');
  message.textContent = failed
    ? '保存データを削除できませんでした。他のトイバコのタブを閉じて、再試行してください。'
    : 'ログアウトしています。保存データの削除が終わるまでお待ちください。';
  panel.appendChild(message);
  if (failed) {
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = '再試行';
    button.onclick = retry;
    panel.appendChild(button);
    button.focus();
  }
};

const bounded = operation =>
  new Promise((resolve, reject) => {
    const timeout = setTimeout(
      () => reject(new Error('Cache operation timed out')),
      5000
    );
    Promise.resolve(operation)
      .then(resolve, reject)
      .finally(() => clearTimeout(timeout));
  });

const deleteDatabase = name =>
  new Promise((resolve, reject) => {
    const timeout = setTimeout(
      () => reject(new Error('Cache deletion timed out')),
      5000
    );
    let request;
    try {
      request = window.indexedDB.deleteDatabase(name);
    } catch {
      clearTimeout(timeout);
      reject(new Error('Cache deletion failed'));
      return;
    }
    request.onsuccess = () => {
      clearTimeout(timeout);
      resolve();
    };
    request.onerror = () => {
      clearTimeout(timeout);
      reject(new Error('Cache deletion failed'));
    };
    // A blocked request stays pending. Never equate dispatch with deletion.
  });

const deleteDatabases = async activeNames => {
  if (!window.indexedDB) return;
  let tracked = [];
  let validRegistry = true;
  try {
    tracked = JSON.parse(localStorage.getItem(DATABASES_KEY) || '[]');
    if (!Array.isArray(tracked)) throw new Error('Invalid cache registry');
  } catch {
    tracked = [];
    validRegistry = false;
  }
  let discovered = [];
  try {
    discovered = (await bounded(window.indexedDB.databases())).map(
      db => db.name
    );
  } catch {
    if (!validRegistry) throw new Error('Cache enumeration unavailable');
  }
  const names = [
    ...new Set([...tracked, ...discovered, ...activeNames]),
  ].filter(
    name => typeof name === 'string' && name.startsWith(DATABASE_PREFIX)
  );
  // Preserve the complete retry list if a deletion errors or a tab blocks it.
  localStorage.setItem(DATABASES_KEY, JSON.stringify(names));
  await Promise.all(names.map(deleteDatabase));
  localStorage.removeItem(DATABASES_KEY);
};

export const clearBrowserData = options => {
  if (cleanupPromise) return cleanupPromise;
  if (!ending) {
    ending = true;
    try {
      localStorage.setItem(PENDING_KEY, `${Date.now()}-${Math.random()}`);
    } catch {
      // Broadcast still reaches peers when storage writes are unavailable.
    }
    try {
      channel?.postMessage('logout');
    } catch {
      // Storage events remain the fallback if this channel has closed.
    }
  }
  const activeNames = options.stopBrowserCache();
  showStatus(false);
  cleanupPromise = Promise.resolve()
    .then(async () => {
      try {
        options.clearSession();
        await deleteDatabases(activeNames);
        // Remove any draft/search write that completed while deletion was pending.
        options.clearSession();
        localStorage.removeItem(PENDING_KEY);
        options.redirect();
        return true;
      } catch {
        // Keep credentials cleared and the application covered. A failed cleanup
        // must not report success or expose cached data to the next signed-in user.
        showStatus(true, () => clearBrowserData(options));
        return false;
      }
    })
    .finally(() => {
      cleanupPromise = null;
    });
  return cleanupPromise;
};

export const onRemoteSessionEnd = callback => {
  window.addEventListener('storage', event => {
    if (event.key === PENDING_KEY && event.newValue && !ending) callback();
  });
  if (typeof window.BroadcastChannel === 'function') {
    channel = new window.BroadcastChannel('toybaco-session-end');
    channel.onmessage = event => {
      if (event.data === 'logout' && !ending) callback();
    };
  }
  // A previous tab/reload may have left deletion incomplete. Finish it before
  // the login code can install credentials for another user.
  if (readPending()) queueMicrotask(callback);
};
