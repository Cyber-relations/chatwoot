import { WOOT_PREFIX } from './constants';

export const isEmptyObject = obj => {
  if (!obj) return true;
  return Object.keys(obj).length === 0 && obj.constructor === Object;
};

export const sendMessage = msg => {
  // A cached parent may not answer the new handshake or send a referrer.
  // Only the public loaded config can leave before its config-set pins origin.
  if (window.toybacoHttpSession && !window.toybacoWidgetParentOrigin && msg.event !== 'loaded') return;
  window.parent.postMessage(
    `chatwoot-widget:${JSON.stringify({ ...msg })}`,
    window.toybacoWidgetParentOrigin || '*'
  );
};

export const IFrameHelper = {
  isIFrame: () => window.self !== window.top,
  sendMessage,
  isAValidEvent: e => {
    if (e.source !== window.parent || e.origin === 'null' || typeof e.data !== 'string' || !e.data.startsWith(WOOT_PREFIX)) return false;
    if (window.toybacoWidgetParentOrigin && e.origin !== window.toybacoWidgetParentOrigin) return false;
    let message;
    try { message = JSON.parse(e.data.slice(WOOT_PREFIX.length)); } catch { return false; }
    if (!message || Array.isArray(message) || typeof message.event !== 'string') return false;
    if (!window.toybacoWidgetParentOrigin) {
      if (message.event !== 'config-set') return false;
      window.toybacoWidgetParentOrigin = e.origin;
    }
    return true;
  },
  getMessage: e => JSON.parse(e.data.replace(WOOT_PREFIX, '')),
};
export const RNHelper = {
  isRNWebView: () => window.ReactNativeWebView,
  sendMessage: msg => {
    window.ReactNativeWebView.postMessage(
      `chatwoot-widget:${JSON.stringify({ ...msg })}`
    );
  },
};

export const groupBy = (array, predicate) => {
  return array.reduce((acc, value) => {
    (acc[predicate(value)] ||= []).push(value);
    return acc;
  }, {});
};
