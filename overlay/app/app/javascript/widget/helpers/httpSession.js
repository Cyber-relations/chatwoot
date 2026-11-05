// This module has no store/router imports. The Widget is mounted only after
// its original identity has been selected and the storage outcome is known.
const PREFIX = 'chatwoot-widget:';
export const WIDGET_RELOAD_MESSAGE = 'チャットを開くには、元のページを再読み込みしてください。';
const randomIntent = () => Array.from(crypto.getRandomValues(new Uint8Array(32)),
  value => value.toString(16).padStart(2, '0')).join('');

const sessionURL = suffix => {
  const url = new URL(`/api/v1/widget/http_session${suffix}`, window.location.origin);
  url.searchParams.set('website_token', window.chatwootWebChannel.websiteToken);
  return url;
};

export const sessionRequest = async (suffix = '', { method = 'POST', body, proof } = {}) => {
  const response = await fetch(sessionURL(suffix), {
    method, credentials: 'same-origin', cache: 'no-store',
    headers: { 'Content-Type': 'application/json', 'X-Toybaco-Widget': '1',
      ...(proof ? { 'X-Auth-Token': proof } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'Widget session unavailable');
  return data;
};

const post = (target, origin, message) => target.postMessage(`${PREFIX}${JSON.stringify(message)}`, origin);

export const notifyHttpSessionProblem = () => {
  const target = window.parent !== window ? window.parent : window.opener;
  if (!target) return;
  // The parent may still be silent. This notification contains only public
  // appearance, so the current SDK can reveal the inert timeout notice.
  post(target, window.toybacoWidgetParentOrigin || '*', { event: 'http-session-problem',
    widgetColor: window.chatwootWebChannel.widgetColor });
};

export const notifyLegacyReload = () => {
  if (window.parent === window) return;
  const params = new URL(window.location.href).searchParams;
  if (params.get('toybaco_sdk') === '2' || params.get('toybaco_popout') === '2') return;
  let origin;
  try { origin = new URL(document.referrer).origin; } catch { origin = '*'; }
  // The cached SDK hides its iframe until loaded. Reveal only the reload
  // document; its ready/setUser callbacks have no mounted chat to receive them.
  post(window.parent, origin === 'null' ? '*' : origin, { event: 'loaded', config: {
    authToken: '', httpSession: false, channelConfig: { widgetColor: window.chatwootWebChannel.widgetColor },
  } });
};

const sessionInputFromParent = () => new Promise((resolve, reject) => {
  const requestId = randomIntent();
  const target = window.opener || (window.parent !== window ? window.parent : null);
  const params = new URL(window.location.href).searchParams;
  const popout = params.get('toybaco_popout') === '2';
  if ((window.opener || window.parent === window || popout) && (!popout || !target)) {
    reject(new Error(WIDGET_RELOAD_MESSAGE));
    return;
  }
  if (!popout && params.get('toybaco_sdk') !== '2') {
    reject(new Error(WIDGET_RELOAD_MESSAGE));
    return;
  }
  let origin;
  const listener = event => {
    if (event.source !== target || event.origin === 'null' || typeof event.data !== 'string' || !event.data.startsWith(PREFIX)) return;
    let data;
    try { data = JSON.parse(event.data.slice(PREFIX.length)); } catch { return; }
    if (!data || typeof data !== 'object' || Array.isArray(data)) return;
    if (data.event !== 'http-session-input' || data.requestId !== requestId) return;
    if (origin && origin !== event.origin) return;
    if (data.token !== null && typeof data.token !== 'string') return;
    if (data.handoffCode !== undefined && !/^[a-f0-9]{64}$/.test(data.handoffCode)) return;
    if (popout && !data.handoffCode) return;
    origin = event.origin;
    clearTimeout(timeout);
    clearInterval(timer);
    window.removeEventListener('message', listener);
    resolve({ token: null, handoffCode: data.handoffCode, target, origin });
  };
  window.addEventListener('message', listener);
  // Only a public challenge is sent without a known parent origin. No proof,
  // token, contact information or conversation is included.
  const announce = () => post(target, '*', { event: 'http-session-inert', requestId,
    popout });
  const timer = setInterval(announce, 1500);
  const timeout = setTimeout(() => {
    clearInterval(timer);
    window.removeEventListener('message', listener);
    reject(new Error('Widget identity handshake timed out'));
  }, 15000);
  announce();
});

const showConflict = async retry => new Promise((resolve, reject) => {
  const root = document.getElementById('app');
  root.textContent = '別の訪問者の認証が保存されています。履歴を混ぜずに切り替えるには、現在のブラウザ認証を解除してください。';
  const button = document.createElement('button');
  button.type = 'button';
  button.textContent = 'このブラウザの認証を解除して切り替える';
  root.appendChild(button);
  button.addEventListener('click', async () => {
    button.disabled = true;
    try {
      const result = await sessionRequest('', { method: 'DELETE' });
      if (result.cookie_session_revoked !== true) throw new Error('Widget reset failed');
      root.textContent = '';
      resolve(await retry());
    } catch (error) { button.disabled = false; reject(error); }
  }, { once: true });
});

export const bootstrapHttpSession = async () => {
  if (!window.toybacoHttpSessionRequested) return;
  const input = await sessionInputFromParent();
  window.toybacoWidgetParentOrigin = input.target ? input.origin : window.location.origin;
  const consumeIntent = randomIntent();
  const outcome = await bootstrapPersistent(input, consumeIntent);
  window.toybacoHttpSession = true;
  window.toybacoHttpSessionPersisted = outcome.persisted === true;
  window.authToken = outcome.proof;
  window.chatwootPubsubToken = 'http-session';
  if (input.target && input.origin) post(input.target, input.origin, {
    event: 'http-session-ready', persisted: outcome.persisted === true,
  });
};

const bootstrapPersistent = async (input, consumeIntent) => {
  const issueOnce = () => input.handoffCode
    ? sessionRequest('/consume', { body: { handoff_code: input.handoffCode, consume_intent: consumeIntent } })
    : sessionRequest('', { body: { legacy_token: input.token, consume_intent: consumeIntent } });
  const issue = async () => {
    try { return await issueOnce(); }
    catch (error) {
      if (error.message !== 'widget_session_retry') throw error;
      return issueOnce();
    }
  };
  let issued;
  try { issued = await issue(); }
  catch (error) {
    if (error.message !== 'widget_session_conflict') throw error;
    if (input.target && input.origin) post(input.target, input.origin, { event: 'http-session-conflict',
      widgetColor: window.chatwootWebChannel.widgetColor });
    issued = await showConflict(issue);
  }
  if (issued.issued !== true || typeof issued.proof !== 'string') throw new Error('Widget session was not issued');
  let outcome;
  try {
    outcome = await sessionRequest('', { method: 'GET', proof: issued.proof });
    if (outcome.persisted !== true || typeof outcome.proof !== 'string') throw new Error('Widget cookie readback failed');
  } catch {
    // Cookie denial has an explicit, bounded, revocable in-memory fallback.
    // Persistence is never claimed when the cookie cannot be read back.
    outcome = await sessionRequest('/recover', { body: {
      handoff_code: issued.recovery_code, consume_intent: consumeIntent,
    } });
    if (outcome.persisted !== false || !outcome.proof?.startsWith('tbwr1.')) throw new Error('Widget recovery failed');
  }
  return outcome;
};

// The original Widget owns its authenticated handoff request. The SDK parent
// forwards only the one-use code to the exact newly opened Window reference.
export const installHttpHandoffReceiver = () => {
  const pending = new Map();
  window.addEventListener('message', async event => {
    if (!window.toybacoHttpSession || event.source !== window.parent || window.parent === window ||
      event.origin !== window.toybacoWidgetParentOrigin || typeof event.data !== 'string' || !event.data.startsWith(PREFIX)) return;
    let data;
    try { data = JSON.parse(event.data.slice(PREFIX.length)); } catch { return; }
    if (!data || typeof data !== 'object' || Array.isArray(data)) return;
    if (data.event !== 'http-popout-grant' || !/^[a-f0-9]{64}$/.test(data.requestId || '')) return;
    if (!pending.has(data.requestId)) {
      pending.set(data.requestId, sessionRequest('/handoff', { proof: window.authToken }));
      setTimeout(() => pending.delete(data.requestId), 60000);
    }
    try {
      const result = await pending.get(data.requestId);
      if (!/^[a-f0-9]{64}$/.test(result.code || '')) return;
      post(event.source, event.origin, { event: 'http-popout-grant-ready', requestId: data.requestId, code: result.code });
    } catch {
      post(event.source, event.origin, { event: 'http-popout-grant-failed', requestId: data.requestId });
    }
  });
};

export const installHttpProofRenewal = updateProof => {
  const renew = async () => {
    const before = window.authToken;
    const generation = window.toybacoWidgetIdentityGeneration || 0;
    if (!window.toybacoHttpSession || !before?.startsWith('tbwp1.')) return;
    try {
      const result = await sessionRequest('/proof', { proof: before });
      // A response belonging to the previous identity cannot roll back a
      // newer setUser/reset result. Revoked sessions are never bootstrapped.
      if (window.authToken === before && generation === (window.toybacoWidgetIdentityGeneration || 0) &&
        result.proof?.startsWith('tbwp1.')) updateProof(result.proof);
    } catch { /* Keep the existing identity and history on failure. */ }
  };
  setInterval(renew, 12 * 60 * 60 * 1000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) renew(); });
  window.addEventListener('online', renew);
};
