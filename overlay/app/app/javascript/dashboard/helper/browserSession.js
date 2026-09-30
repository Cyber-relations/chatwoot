// Only a CSRF token is exposed to JavaScript. Authentication stays HttpOnly.
let csrfRequest;
const UNSAFE_METHODS = new Set(['post', 'put', 'patch', 'delete']);

export const browserSessionHeaders = () => ({
  'X-Toybaco-Browser': '1',
  'X-CSRF-Token':
    document.querySelector('meta[name="csrf-token"]')?.content || '',
});

async function csrfToken() {
  const current = browserSessionHeaders()['X-CSRF-Token'];
  if (current) return current;
  if (!csrfRequest) {
    csrfRequest = fetch('/toybaco/browser-session', {
      credentials: 'same-origin',
      headers: { 'X-Toybaco-Browser': '1', Accept: 'application/json' },
      cache: 'no-store',
    })
      .then(async (response) => {
        if (!response.ok)
          throw new Error(
            '認証状態を確認できませんでした。再読み込みしてください。'
          );
        const data = await response.json();
        if (!data.csrf_token) throw new Error('CSRF token is missing');
        let meta = document.querySelector('meta[name="csrf-token"]');
        if (!meta) {
          meta = document.createElement('meta');
          meta.name = 'csrf-token';
          document.head.appendChild(meta);
        }
        meta.content = data.csrf_token;
        return data.csrf_token;
      })
      .finally(() => {
        csrfRequest = null;
      });
  }
  return csrfRequest;
}

export const configureBrowserSession = (client) => {
  client.interceptors.request.use(async (config) => {
    const target = new URL(
      config.url,
      new URL(config.baseURL || '/', window.location.origin)
    );
    if (target.origin !== window.location.origin)
      throw new Error('Cross-origin browser API request refused');
    config.headers = config.headers || {};
    config.headers['X-Toybaco-Browser'] = '1';
    if (UNSAFE_METHODS.has((config.method || 'get').toLowerCase())) {
      config.headers['X-CSRF-Token'] = await csrfToken();
    }
    return config;
  });
  return client;
};
