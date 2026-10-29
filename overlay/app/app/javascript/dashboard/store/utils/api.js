import Cookies from 'js-cookie';
import { LOCAL_STORAGE_KEYS } from 'dashboard/constants/localStorage';
import { SESSION_STORAGE_KEYS } from 'dashboard/constants/sessionStorage';
import { LocalStorage } from 'shared/helpers/localStorage';
import SessionStorage from 'shared/helpers/sessionStorage';
import { emitter } from 'shared/helpers/mitt';
import { stopBrowserCache } from 'dashboard/helper/CacheHelper/DataManager';
import {
  clearBrowserData,
  isSessionEnding,
  onRemoteSessionEnd,
} from 'dashboard/helper/sessionCleanup';
import {
  ANALYTICS_IDENTITY,
  ANALYTICS_RESET,
  CHATWOOT_RESET,
  CHATWOOT_SET_USER,
} from '../../constants/appEvents';

// Authentication cookies are issued and expired only by the server.

export const getLoadingStatus = (state) => state.fetchAPIloadingStatus;
export const setLoadingStatus = (state, status) => {
  state.fetchAPIloadingStatus = status;
};

export const setUser = (user) => {
  emitter.emit(CHATWOOT_SET_USER, { user });
  emitter.emit(ANALYTICS_IDENTITY, { user });
};

export const getHeaderExpiry = () => undefined;

export const setAuthCredentials = (response) => {
  if (isSessionEnding())
    throw new Error('ログアウト処理が完了するまでお待ちください。');
  setUser(response.data.data);
};

export const clearBrowserSessionCookies = () => {
  // The API clears the HttpOnly credential; this marker has no authority.
  Cookies.remove('cw_d_authenticated', { path: '/' });
  Cookies.remove('cw_d_session_info', { path: '/' });
  Cookies.remove('auth_data');
  Cookies.remove('user');
};

export const clearLocalStorageOnLogout = () => {
  [
    LOCAL_STORAGE_KEYS.DRAFT_MESSAGES,
    LOCAL_STORAGE_KEYS.MESSAGE_REPLY_TO,
    LOCAL_STORAGE_KEYS.RECENT_SEARCHES,
  ].forEach((key) => LocalStorage.remove(key));
  Object.keys(localStorage)
    .filter((key) => key.startsWith(LOCAL_STORAGE_KEYS.WIDGET_BUILDER))
    .forEach((key) => localStorage.removeItem(key));
};

// Toybaco session keys (e.g. the AI reply panel state per conversation) belong
// to the signed-in staff member.
const TOYBACO_SESSION_PREFIX = 'toybaco:';

export const clearSessionStorageOnLogout = () => {
  SessionStorage.remove(SESSION_STORAGE_KEYS.IMPERSONATION_USER);
  try {
    const storage = window.sessionStorage;
    Object.keys(storage)
      .filter((key) => key.startsWith(TOYBACO_SESSION_PREFIX))
      .forEach((key) => storage.removeItem(key));
  } catch {
    // Storage can be unavailable; logout must still finish.
  }
};

// Web Push had been on in this browser before logout removed it. The next
// login subscribes again for whoever signs in, as upstream re-binds a kept
// subscription. The marker holds no user data, only the fixed value "1".
const PUSH_RESTORE_KEY = 'toybaco:push-restore';
const rememberPushRestore = (unsubscribed) => {
  try {
    if (unsubscribed === true) localStorage.setItem(PUSH_RESTORE_KEY, '1');
  } catch {
    // Without the marker the user turns push on again in the preferences.
  }
  return unsubscribed;
};

// The browser keeps its Web Push subscription after logout, and the server keeps
// sending message previews to it until the push service rejects the endpoint.
// Unsubscribe once per logout, best-effort: a failure or a hang never blocks it.
let pushUnsubscribe;
export const unsubscribeBrowserPush = () => {
  if (!pushUnsubscribe) {
    pushUnsubscribe = Promise.resolve()
      .then(() => window.navigator?.serviceWorker?.getRegistration())
      .then((registration) => registration?.pushManager?.getSubscription())
      .then((subscription) => subscription?.unsubscribe())
      .then(rememberPushRestore)
      .catch(() => false);
  }
  return pushUnsubscribe;
};

// On authenticated startup: true while logout's removal waits to be restored
// and the browser still grants notifications. Without the permission the
// marker is cleared (nothing to restore).
export const pendingBrowserPushRestore = () => {
  try {
    if (localStorage.getItem(PUSH_RESTORE_KEY) !== '1') return false;
    if (window.Notification?.permission === 'granted') return true;
    localStorage.removeItem(PUSH_RESTORE_KEY);
    return false;
  } catch {
    return false;
  }
};

const clearBrowserPushRestore = () => {
  try {
    localStorage.removeItem(PUSH_RESTORE_KEY);
  } catch {
    // A kept marker only retries the restore at the next startup.
  }
};

// App startup: register an existing subscription for the signed-in user (as
// upstream does), or subscribe again when logout removed it. The marker stays
// until the registration succeeds (subscribed and posted to the server), so a
// failed attempt is retried at the next startup.
export const restoreBrowserPushOnLogin = (registration, register) =>
  registration.pushManager.getSubscription().then((subscription) => {
    if (subscription || pendingBrowserPushRestore())
      register(clearBrowserPushRestore);
  });

// Navigation would drop a pending unsubscribe, so logout waits for it, but
// never longer than this bound.
export const PUSH_UNSUBSCRIBE_BOUND_MS = 1500;
export const waitForPushUnsubscribe = () =>
  new Promise((resolve) => {
    const timer = setTimeout(resolve, PUSH_UNSUBSCRIBE_BOUND_MS);
    unsubscribeBrowserPush().finally(() => {
      clearTimeout(timer);
      resolve();
    });
  });

export const clearCookiesOnLogout = () =>
  clearBrowserData({
    stopBrowserCache,
    clearSession: () => {
      emitter.emit(CHATWOOT_RESET);
      emitter.emit(ANALYTICS_RESET);
      unsubscribeBrowserPush();
      clearBrowserSessionCookies();
      clearLocalStorageOnLogout();
      clearSessionStorageOnLogout();
    },
    beforeRedirect: waitForPushUnsubscribe,
    redirect: () => {
      const globalConfig = window.globalConfig || {};
      window.location = globalConfig.LOGOUT_REDIRECT_LINK || '/';
    },
  });

onRemoteSessionEnd(clearCookiesOnLogout);

export const parseAPIErrorResponse = (error) => {
  if (error?.response?.data?.message) {
    return error?.response?.data?.message;
  }
  if (error?.response?.data?.error) {
    return error?.response?.data?.error;
  }
  if (error?.response?.data?.errors) {
    return error?.response?.data?.errors[0];
  }
  return error;
};

export const throwErrorMessage = (error) => {
  const errorMessage = parseAPIErrorResponse(error);
  throw new Error(errorMessage);
};

export const parseLinearAPIErrorResponse = (error, defaultMessage) => {
  const errorData = error.response.data;
  const errorMessage = errorData?.error?.errors?.[0]?.message || defaultMessage;
  return errorMessage;
};
