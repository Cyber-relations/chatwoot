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

export const clearSessionStorageOnLogout = () => {
  SessionStorage.remove(SESSION_STORAGE_KEYS.IMPERSONATION_USER);
};

export const clearCookiesOnLogout = () =>
  clearBrowserData({
    stopBrowserCache,
    clearSession: () => {
      emitter.emit(CHATWOOT_RESET);
      emitter.emit(ANALYTICS_RESET);
      clearBrowserSessionCookies();
      clearLocalStorageOnLogout();
      clearSessionStorageOnLogout();
    },
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
