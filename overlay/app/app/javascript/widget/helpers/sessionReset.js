import { API } from './axios';

// The parent never receives an API header. The existing widget performs the
// same-origin request with its current header, including after setUser/merge.
export const installSessionReset = () => {
  let pending;
  window.addEventListener('message', async event => {
    if (
      window.parent === window ||
      event.source !== window.parent ||
      event.origin === 'null' ||
      typeof event.data !== 'string' ||
      !event.data.startsWith('chatwoot-widget:')
    ) return;

    let message;
    try {
      message = JSON.parse(event.data.slice('chatwoot-widget:'.length));
    } catch {
      return;
    }
    if (
      !message || message.event !== 'revoke-session' ||
      typeof message.requestId !== 'string' ||
      !/^[a-f0-9]{32}$/.test(message.requestId)
    ) return;

    // Duplicate delivery shares the same request and cannot issue another DELETE.
    if (!pending || pending.id !== message.requestId) {
      pending = {
        id: message.requestId,
        result: API.delete('/api/v1/widget/session', {
          params: { website_token: new URL(window.location.href).searchParams.get('website_token') },
        }).then(response => response.data?.session_revoked === true).catch(() => false),
      };
    }
    const success = await pending.result;
    event.source.postMessage(`chatwoot-widget:${JSON.stringify({
      event: 'session-revoked', requestId: message.requestId, success,
    })}`, event.origin);
  });
};
