import Cookies from 'js-cookie';
import {
  addClasses,
  loadCSS,
  removeClasses,
  onLocationChangeListener,
} from './DOMHelpers';
import {
  body,
  widgetHolder,
  createBubbleHolder,
  createBubbleIcon,
  bubbleSVG,
  chatBubble,
  closeBubble,
  bubbleHolder,
  onClickChatBubble,
  onBubbleClick,
  setBubbleText,
  addUnreadClass,
  removeUnreadClass,
} from './bubbleHelpers';
import { isWidgetColorLighter } from 'shared/helpers/colorHelper';
import { dispatchWindowEvent } from 'shared/helpers/CustomEventHelper';
import {
  CHATWOOT_ERROR,
  CHATWOOT_POSTBACK,
  CHATWOOT_READY,
} from '../widget/constants/sdkEvents';
import { SET_USER_ERROR } from '../widget/constants/errorTypes';
import { getUserCookieName, setCookieWithDomain } from './cookieHelpers';
import {
  getAlertAudio,
  initOnEvents,
} from 'shared/helpers/AudioNotificationHelper';
import { isFlatWidgetStyle } from './settingsHelper';
import { popoutChatWindow } from '../widget/helpers/popoutHelper';
import { openHttpPopout } from '../widget/helpers/httpPopout';

const updateAuthCookie = (cookieContent, baseDomain = '') =>
  setCookieWithDomain('cw_conversation', cookieContent, {
    baseDomain,
  });

const updateCampaignReadStatus = baseDomain => {
  const expireBy = new Date(Date.now() + 60 * 60 * 1000);
  setCookieWithDomain('cw_snooze_campaigns_till', Number(expireBy), {
    expires: expireBy,
    baseDomain,
  });
};

export const IFrameHelper = {
  getUrl({ baseUrl, websiteToken }) {
    const frameBaseUrl = IFrameHelper.getFrameBaseUrl(baseUrl);
    return `${frameBaseUrl}/widget?website_token=${websiteToken}&toybaco_sdk=2`;
  },
  // トイバコ: http→https のリダイレクト後も iframe.src は書き換わらず、src 由来の origin と
  // event.origin が食い違って loaded が捨てられる。開発ホスト以外の http は https にしてから
  // iframe に渡す(createFrame と sdk.js の reset がこの getUrl を使う)。
  // 文字列は置換せず、parse した URL を書き換えて serialize する。http の既定の :80 は
  // parse の時点で落ち、:8080 などの明示の port は残る。末尾の / は getUrl の組み立てのため外す。
  getFrameBaseUrl: baseUrl => {
    let url;
    try {
      url = new URL(baseUrl);
    } catch {
      return baseUrl;
    }
    // DNS ルートの末尾の点(localhost. など)を落としてから判定する。
    const host = url.hostname.replace(/\.$/, '');
    const isDevelopmentHost =
      host === 'localhost' ||
      host === '[::1]' ||
      /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host) ||
      host.endsWith('.localhost') ||
      host.endsWith('.test');
    if (url.protocol !== 'http:' || isDevelopmentHost) return baseUrl;
    url.protocol = 'https:';
    return url.href.replace(/\/$/, '');
  },
  createFrame: ({ baseUrl, websiteToken }) => {
    if (IFrameHelper.getAppFrame()) {
      return;
    }

    loadCSS();
    const iframe = document.createElement('iframe');
    const widgetUrl = IFrameHelper.getUrl({ baseUrl, websiteToken });
    iframe.src = widgetUrl;
    iframe.allow =
      'camera;microphone;fullscreen;display-capture;picture-in-picture;clipboard-write;';
    iframe.id = 'chatwoot_live_chat_widget';
    iframe.style.visibility = 'hidden';

    let holderClassName = `woot-widget-holder woot--hide woot-elements--${window.$chatwoot.position}`;
    if (window.$chatwoot.hideMessageBubble) {
      holderClassName += ` woot-widget--without-bubble`;
    }
    if (isFlatWidgetStyle(window.$chatwoot.widgetStyle)) {
      holderClassName += ` woot-widget-holder--flat`;
    }

    addClasses(widgetHolder, holderClassName);
    widgetHolder.id = 'cw-widget-holder';
    widgetHolder.dataset.turboPermanent = true;
    widgetHolder.appendChild(iframe);
    body.appendChild(widgetHolder);
    IFrameHelper.initPostMessageCommunication();
    IFrameHelper.initWindowSizeListener();
    IFrameHelper.preventDefaultScroll();
  },
  getAppFrame: () => document.getElementById('chatwoot_live_chat_widget'),
  getBubbleHolder: () => document.getElementsByClassName('woot--bubble-holder'),
  getFrameOrigin: frame => {
    if (!frame) return null;

    try {
      const origin = new URL(frame.src, window.location.href).origin;
      return origin === 'null' ? null : origin;
    } catch {
      return null;
    }
  },
  sendMessage: (key, value) => {
    if (IFrameHelper.backendIncompatible && key !== 'http-session-input') return;
    if ((IFrameHelper.pendingReset || IFrameHelper.resetFailed) && !['revoke-session', 'http-session-input'].includes(key)) return;
    const element = IFrameHelper.getAppFrame();
    const origin = IFrameHelper.getFrameOrigin(element);
    if (!origin || !element.contentWindow) return;

    element.contentWindow.postMessage(
      `chatwoot-widget:${JSON.stringify({ event: key, ...value })}`,
      origin
    );
  },
  resetSession: () => {
    if (IFrameHelper.pendingReset) return IFrameHelper.pendingReset.promise;
    const frame = IFrameHelper.getAppFrame();
    if (!frame) return Promise.reject(new Error('Widget is not available'));
    if (window.$chatwoot.isOpen) IFrameHelper.events.toggleBubble('close');
    const bytes = window.crypto.getRandomValues(new Uint8Array(16));
    const requestId = Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
    let resolve;
    let reject;
    const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
    // Legacy callers may ignore the returned Promise; the error event still
    // reports a failed reset and this handler prevents an unhandled rejection.
    promise.catch(() => {});
    const state = { requestId, promise, resolve, reject, frame };
    IFrameHelper.resetFailed = false;
    IFrameHelper.pendingReset = state;
    state.timer = setTimeout(() => IFrameHelper.finishSessionReset(false), 15000);
    frame.style.visibility = 'hidden';
    delete window.$chatwoot.user;
    delete window.$chatwoot.identifier;
    window.$chatwoot.resetTriggered = true;
    if (window.$chatwoot.hasLoaded) IFrameHelper.sendMessage('revoke-session', { requestId });
    return promise;
  },
  finishSessionReset: success => {
    const state = IFrameHelper.pendingReset;
    if (!state) return;
    clearTimeout(state.timer);
    IFrameHelper.pendingReset = null;
    if (!success) {
      IFrameHelper.resetFailed = true;
      dispatchWindowEvent({ eventName: CHATWOOT_ERROR, data: { errorType: 'session_reset_failed' } });
      state.reject(new Error('Widget session could not be revoked. Retry reset before continuing.'));
      return;
    }
    const domain = window.$chatwoot.baseDomain;
    for (const name of ['cw_conversation', getUserCookieName()]) {
      Cookies.remove(name, { path: '/', domain });
      // Older SDKs sometimes wrote a host cookie even when baseDomain was set.
      if (domain) Cookies.remove(name, { path: '/' });
    }
    window.$chatwoot.hasLoaded = false;
    // A new browsing context rejects delayed loaded/auth-cookie messages from
    // the revoked frame even though its origin is the same.
    const replacement = state.frame.cloneNode(false);
    replacement.src = IFrameHelper.getUrl({ baseUrl: window.$chatwoot.baseUrl, websiteToken: window.$chatwoot.websiteToken });
    state.frame.replaceWith(replacement);
    state.resolve();
  },
  initPostMessageCommunication: () => {
    // トイバコ: listener は window に 1 つだけ持つ。sdk.js を読み直した別の IFrameHelper が
    // init しても、前の listener を外してから登録する。
    const previousListener = window.__toybacoChatwootSdkMessageListener;
    if (previousListener) {
      window.removeEventListener('message', previousListener);
    }
    if (IFrameHelper.messageListener) {
      window.removeEventListener('message', IFrameHelper.messageListener);
    }
    IFrameHelper.messageListener = e => {
      const frame = IFrameHelper.getAppFrame();
      const origin = IFrameHelper.getFrameOrigin(frame);
      if (
        !origin ||
        e.origin !== origin ||
        e.source !== frame.contentWindow ||
        typeof e.data !== 'string' ||
        e.data.indexOf('chatwoot-widget:') !== 0
      ) {
        return;
      }
      let message;
      try {
        message = JSON.parse(e.data.slice('chatwoot-widget:'.length));
      } catch {
        return;
      }
      if (
        !message ||
        Array.isArray(message) ||
        typeof message.event !== 'string' ||
        !Object.prototype.hasOwnProperty.call(IFrameHelper.events, message.event)
      ) {
        return;
      }
      if (
        (IFrameHelper.pendingReset || IFrameHelper.resetFailed) &&
        !['loaded', 'session-revoked', 'http-session-inert'].includes(message.event)
      ) return;
      if (typeof IFrameHelper.events[message.event] === 'function') {
        IFrameHelper.events[message.event](message);
      }
    };
    window.__toybacoChatwootSdkMessageListener = IFrameHelper.messageListener;
    window.addEventListener('message', IFrameHelper.messageListener);
  },
  initWindowSizeListener: () => {
    window.addEventListener('resize', () => IFrameHelper.toggleCloseButton());
  },
  preventDefaultScroll: () => {
    widgetHolder.addEventListener('wheel', event => {
      const deltaY = event.deltaY;
      const contentHeight = widgetHolder.scrollHeight;
      const visibleHeight = widgetHolder.offsetHeight;
      const scrollTop = widgetHolder.scrollTop;

      if (
        (scrollTop === 0 && deltaY < 0) ||
        (visibleHeight + scrollTop === contentHeight && deltaY > 0)
      ) {
        event.preventDefault();
      }
    });
  },

  setFrameHeightToFitContent: (extraHeight, isFixedHeight) => {
    const iframe = IFrameHelper.getAppFrame();
    const updatedIframeHeight = isFixedHeight ? `${extraHeight}px` : '100%';

    if (iframe)
      iframe.setAttribute('style', `height: ${updatedIframeHeight} !important`);
  },

  setupAudioListeners: () => {
    const { baseUrl = '' } = window.$chatwoot;
    getAlertAudio(baseUrl, { type: 'widget', alertTone: 'ding' }).then(() =>
      initOnEvents.forEach(event => {
        document.removeEventListener(
          event,
          IFrameHelper.setupAudioListeners,
          false
        );
      })
    );
  },

  events: {
    'http-session-inert': message => {
      if (!/^[a-f0-9]{64}$/.test(message.requestId || '') || message.popout === true) return;
      IFrameHelper.httpSessionSupported = true;
      IFrameHelper.backendIncompatible = false;
      IFrameHelper.sendMessage('http-session-input', {
        requestId: message.requestId, token: Cookies.get('cw_conversation') || null,
      });
    },
    'http-session-ready': message => {
      // Keep the pre-existing bridge while cached legacy SDKs can still run.
      // New proofs are never written here. Retire it only on an explicit reset
      // or after a proved identity change makes this old bridge stale.
      if (message.persisted !== true) {
        dispatchWindowEvent({ eventName: CHATWOOT_ERROR, data: { errorType: 'session_not_persisted' } });
      }
    },
    'http-session-identity-changed': () => {
      const domain = window.$chatwoot.baseDomain;
      Cookies.remove('cw_conversation', { path: '/', domain });
      if (domain) Cookies.remove('cw_conversation', { path: '/' });
    },
    'http-session-conflict': message => {
      IFrameHelper.showSessionProblem(message);
      dispatchWindowEvent({ eventName: CHATWOOT_ERROR, data: { errorType: 'session_conflict' } });
    },
    'http-session-problem': message => {
      IFrameHelper.showSessionProblem(message);
      dispatchWindowEvent({ eventName: CHATWOOT_ERROR, data: { errorType: 'session_unavailable' } });
    },
    'http-popout-grant-ready': message => {
      const pending = IFrameHelper.pendingPopout;
      if (pending?.id === message.requestId && /^[a-f0-9]{64}$/.test(message.code || '')) {
        IFrameHelper.pendingPopout = null;
        clearTimeout(pending.timer);
        pending.resolve({ code: message.code });
      }
    },
    'http-popout-grant-failed': message => {
      if (IFrameHelper.pendingPopout?.id === message.requestId) {
        const pending = IFrameHelper.pendingPopout;
        IFrameHelper.pendingPopout = null;
        clearTimeout(pending.timer);
        pending.reject(new Error('Widget handoff failed'));
      }
    },
    'session-revoked': message => {
      if (message.requestId === IFrameHelper.pendingReset?.requestId) {
        IFrameHelper.finishSessionReset(message.success === true);
      }
    },
    loaded: message => {
      if (IFrameHelper.resetFailed) return;
      if (IFrameHelper.pendingReset) {
        IFrameHelper.sendMessage('revoke-session', { requestId: IFrameHelper.pendingReset.requestId });
        return;
      }
      if (!message.config.httpSession) {
        // One rollback-only fallback preserves the old visitor when a new SDK
        // meets an older server. No third attempt or silent anonymous history.
        const legacy = Cookies.get('cw_conversation');
        if (legacy && !IFrameHelper.httpSessionSupported && !IFrameHelper.legacyFallbackUsed) {
          IFrameHelper.legacyFallbackUsed = true;
          const frame = IFrameHelper.getAppFrame();
          const url = new URL(frame.src);
          url.searchParams.delete('toybaco_sdk');
          url.searchParams.set('cw_conversation', legacy);
          frame.src = url.toString();
          return;
        }
        if (!legacy || IFrameHelper.httpSessionSupported) {
          // An older server cannot see the new HttpOnly identity. Do not show
          // its anonymous replacement as a returning visitor's empty history.
          const frame = IFrameHelper.getAppFrame();
          frame.style.visibility = 'hidden';
          IFrameHelper.backendIncompatible = true;
          window.$chatwoot.hasLoaded = false;
          dispatchWindowEvent({ eventName: CHATWOOT_ERROR, data: { errorType: 'session_backend_incompatible' } });
          return;
        }
        updateAuthCookie(message.config.authToken, window.$chatwoot.baseDomain);
      } else {
        IFrameHelper.httpSessionSupported = true;
        IFrameHelper.backendIncompatible = false;
      }
      window.$chatwoot.hasLoaded = true;
      const campaignsSnoozedTill = Cookies.get('cw_snooze_campaigns_till');
      IFrameHelper.sendMessage('config-set', {
        locale: window.$chatwoot.locale,
        position: window.$chatwoot.position,
        hideMessageBubble: window.$chatwoot.hideMessageBubble,
        showPopoutButton: window.$chatwoot.showPopoutButton,
        widgetStyle: window.$chatwoot.widgetStyle,
        darkMode: window.$chatwoot.darkMode,
        showUnreadMessagesDialog: window.$chatwoot.showUnreadMessagesDialog,
        campaignsSnoozedTill,
        welcomeTitle: window.$chatwoot.welcomeTitle,
        welcomeDescription: window.$chatwoot.welcomeDescription,
        availableMessage: window.$chatwoot.availableMessage,
        unavailableMessage: window.$chatwoot.unavailableMessage,
        enableFileUpload: window.$chatwoot.enableFileUpload,
        enableEmojiPicker: window.$chatwoot.enableEmojiPicker,
        enableEndConversation: window.$chatwoot.enableEndConversation,
      });
      IFrameHelper.onLoad({
        widgetColor: message.config.channelConfig.widgetColor,
      });
      IFrameHelper.toggleCloseButton();

      if (window.$chatwoot.user) {
        IFrameHelper.sendMessage('set-user', {
          identifier: window.$chatwoot.identifier,
          user: window.$chatwoot.user,
        });
      }

      window.playAudioAlert = () => {};

      initOnEvents.forEach(e => {
        document.addEventListener(e, IFrameHelper.setupAudioListeners, false);
      });

      if (!window.$chatwoot.resetTriggered) {
        dispatchWindowEvent({ eventName: CHATWOOT_READY });
      }
    },
    error: ({ errorType, data }) => {
      dispatchWindowEvent({ eventName: CHATWOOT_ERROR, data: data });

      if (errorType === SET_USER_ERROR) {
        Cookies.remove(getUserCookieName());
      }
    },
    onEvent({ eventIdentifier: eventName, data }) {
      dispatchWindowEvent({ eventName, data });
    },
    setBubbleLabel(message) {
      setBubbleText(window.$chatwoot.launcherTitle || message.label);
    },

    setAuthCookie({ data: { widgetAuthToken } }) {
      if (IFrameHelper.pendingReset || IFrameHelper.resetFailed) return;
      if (IFrameHelper.httpSessionSupported || /^tbw[pr]1\./.test(widgetAuthToken || '')) return;
      updateAuthCookie(widgetAuthToken, window.$chatwoot.baseDomain);
    },

    setCampaignReadOn() {
      updateCampaignReadStatus(window.$chatwoot.baseDomain);
    },

    postback(data) {
      dispatchWindowEvent({
        eventName: CHATWOOT_POSTBACK,
        data,
      });
    },

    toggleBubble: state => {
      let bubbleState = {};
      if (state === 'open') {
        bubbleState.toggleValue = true;
      } else if (state === 'close') {
        bubbleState.toggleValue = false;
      }

      onBubbleClick(bubbleState);
    },

    popoutChatWindow: ({ baseUrl, websiteToken, locale }) => {
      if (IFrameHelper.pendingReset || IFrameHelper.resetFailed) return;
      if (IFrameHelper.httpSessionSupported) {
        return openHttpPopout(IFrameHelper.getFrameBaseUrl(baseUrl), websiteToken, locale, requestId => {
          if (IFrameHelper.pendingPopout) return Promise.reject(new Error('Widget popout is already pending'));
          return new Promise((resolve, reject) => {
            const state = { id: requestId, resolve, reject };
            IFrameHelper.pendingPopout = state;
            state.timer = setTimeout(() => {
              if (IFrameHelper.pendingPopout === state) IFrameHelper.pendingPopout = null;
              reject(new Error('Widget popout timed out'));
            }, 60000);
            IFrameHelper.sendMessage('http-popout-grant', { requestId });
          });
        });
      }
      const cwCookie = Cookies.get('cw_conversation');
      window.$chatwoot.toggle('close');
      popoutChatWindow(baseUrl, websiteToken, locale, cwCookie);
    },

    closeWindow: () => {
      onBubbleClick({ toggleValue: false });
      removeUnreadClass();
    },

    onBubbleToggle: isOpen => {
      IFrameHelper.sendMessage('toggle-open', { isOpen });
      if (isOpen) {
        IFrameHelper.pushEvent('webwidget.triggered');
      }
    },
    onLocationChange: ({ referrerURL, referrerHost }) => {
      IFrameHelper.sendMessage('change-url', {
        referrerURL,
        referrerHost,
      });
    },
    updateIframeHeight: message => {
      const { extraHeight = 0, isFixedHeight } = message;

      IFrameHelper.setFrameHeightToFitContent(extraHeight, isFixedHeight);
    },

    setUnreadMode: () => {
      addUnreadClass();
      onBubbleClick({ toggleValue: true });
    },

    resetUnreadMode: () => removeUnreadClass(),
    handleNotificationDot: event => {
      if (window.$chatwoot.hideMessageBubble) {
        return;
      }

      const bubbleElement = document.querySelector('.woot-widget-bubble');
      if (
        event.unreadMessageCount > 0 &&
        !bubbleElement.classList.contains('unread-notification')
      ) {
        addClasses(bubbleElement, 'unread-notification');
      } else if (event.unreadMessageCount === 0) {
        removeClasses(bubbleElement, 'unread-notification');
      }
    },

    closeChat: () => {
      onBubbleClick({ toggleValue: false });
    },

    playAudio: () => {
      window.playAudioAlert();
    },
  },
  pushEvent: eventName => {
    IFrameHelper.sendMessage('push-event', { eventName });
  },

  showSessionProblem: ({ widgetColor } = {}) => {
    // The inert error/explicit-switch UI must be reachable while hasLoaded
    // remains false. Only public appearance is used; no auth-ready is forged.
    IFrameHelper.onLoad({ widgetColor: /^#[a-f0-9]{6}$/i.test(widgetColor || '') ? widgetColor : '#1f93ff' });
    IFrameHelper.events.toggleBubble('open');
  },
  onLoad: ({ widgetColor }) => {
    const iframe = IFrameHelper.getAppFrame();
    iframe.style.visibility = '';
    iframe.setAttribute('id', `chatwoot_live_chat_widget`);

    if (IFrameHelper.getBubbleHolder().length) {
      return;
    }
    createBubbleHolder(window.$chatwoot.hideMessageBubble);
    onLocationChangeListener();

    let className = 'woot-widget-bubble';
    let closeBtnClassName = `woot-elements--${window.$chatwoot.position} woot-widget-bubble woot--close woot--hide`;

    if (isFlatWidgetStyle(window.$chatwoot.widgetStyle)) {
      className += ' woot-widget-bubble--flat';
      closeBtnClassName += ' woot-widget-bubble--flat';
    }

    if (isWidgetColorLighter(widgetColor)) {
      className += ' woot-widget-bubble-color--lighter';
      closeBtnClassName += ' woot-widget-bubble-color--lighter';
    }

    const chatIcon = createBubbleIcon({
      className,
      path: bubbleSVG,
      target: chatBubble,
    });

    addClasses(closeBubble, closeBtnClassName);

    chatIcon.style.background = widgetColor;
    closeBubble.style.background = widgetColor;

    bubbleHolder.appendChild(chatIcon);
    bubbleHolder.appendChild(closeBubble);
    onClickChatBubble();
  },
  toggleCloseButton: () => {
    let isMobile = false;
    if (window.matchMedia('(max-width: 668px)').matches) {
      isMobile = true;
    }
    IFrameHelper.sendMessage('toggle-close-button', { isMobile });
  },
};
