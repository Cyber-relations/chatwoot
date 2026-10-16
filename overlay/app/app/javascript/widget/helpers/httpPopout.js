import { sessionRequest } from './httpSession';

const PREFIX = 'chatwoot-widget:';

export const openHttpPopout = (origin, websiteToken, locale, requestGrant) => {
  const url = new URL('/widget', origin);
  url.searchParams.set('website_token', websiteToken);
  url.searchParams.set('toybaco_popout', '2');
  if (locale) url.searchParams.set('locale', locale);
  const popup = window.open(url.toString(), `webwidget_session_${websiteToken}`, 'resizable=off,width=400,height=600');
  if (!popup) return null;
  let requestId;
  let grant;
  const receive = async event => {
    if (event.source !== popup || event.origin !== url.origin || typeof event.data !== 'string' || !event.data.startsWith(PREFIX)) return;
    let data;
    try { data = JSON.parse(event.data.slice(PREFIX.length)); } catch { return; }
    if (!data || typeof data !== 'object' || Array.isArray(data)) return;
    if (data.event !== 'http-session-inert' || data.popout !== true || !/^[a-f0-9]{64}$/.test(data.requestId || '')) return;
    if (requestId && requestId !== data.requestId) return;
    requestId = data.requestId;
    // All repeated challenges share one operation. A late response cannot be
    // sent to another popup or a newly navigated, different origin.
    grant ||= requestGrant ? requestGrant(requestId) : sessionRequest('/handoff', { proof: window.authToken });
    try {
      const result = await grant;
      if (!/^[a-f0-9]{64}$/.test(result.code || '') || popup.closed) return;
      popup.postMessage(`${PREFIX}${JSON.stringify({ event: 'http-session-input', requestId, token: null,
        handoffCode: result.code })}`, url.origin);
    } catch { /* The child remains inert and reports an explicit timeout. */ }
  };
  window.addEventListener('message', receive);
  setTimeout(() => window.removeEventListener('message', receive), 60000);
  popup.focus();
  return popup;
};
