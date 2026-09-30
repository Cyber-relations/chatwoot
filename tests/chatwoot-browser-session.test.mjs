import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const root = process.argv[2] || 'overlay/app';
const source = readFileSync(`${root}/app/javascript/dashboard/helper/browserSession.js`, 'utf8').replace(/^export /gm, '');
const fixture = (initial = 'synthetic-csrf') => {
  let meta = initial ? { content: initial } : null;
  const fetched = [];
  const context = vm.createContext({
    URL,
    window: { location: { origin: 'https://app.example.test' } },
    document: {
      querySelector: () => meta,
      createElement: () => ({}),
      head: { appendChild: element => { meta = element; } },
    },
    fetch: async (url, options) => {
      fetched.push({ url, options });
      return { ok: true, json: async () => ({ csrf_token: 'bootstrap-csrf' }) };
    },
  });
  vm.runInContext(source, context);
  const { configureBrowserSession, browserSessionHeaders } = vm.runInContext('({ configureBrowserSession, browserSessionHeaders })', context);
  let prepare;
  configureBrowserSession({ interceptors: { request: { use: fn => { prepare = fn; } } } });
  return { prepare, fetched, browserSessionHeaders };
};

const f = fixture();
for (const method of ['post', 'put', 'patch', 'delete', 'POST']) {
  const config = await f.prepare({ method, url: '/api/v1/profile' });
  assert.equal(config.headers['X-CSRF-Token'], 'synthetic-csrf');
  assert.equal(config.headers['X-Toybaco-Browser'], '1');
  assert.equal(config.headers['access-token'], undefined);
}
assert.equal(f.fetched.length, 0);
for (const url of ['https://evil.example/api', '//evil.example/api']) {
  await assert.rejects(f.prepare({ method: 'post', url }), /Cross-origin/);
}
await assert.rejects(f.prepare({ method: 'post', url: 'api/x', baseURL: 'https://evil.example/' }), /Cross-origin/);
const bootstrap = fixture(null);
const prepared = await Promise.all([bootstrap.prepare({ method: 'post', url: 'auth/sign_in' }), bootstrap.prepare({ method: 'delete', url: '/auth/sign_out' })]);
assert.equal(bootstrap.fetched.length, 1);
assert.equal(bootstrap.fetched[0].options.credentials, 'same-origin');
assert.equal(bootstrap.fetched[0].options.cache, 'no-store');
assert.equal(prepared[0].headers['X-CSRF-Token'], 'bootstrap-csrf');
assert.equal(prepared[1].headers['X-CSRF-Token'], 'bootstrap-csrf');
assert.equal(bootstrap.browserSessionHeaders()['X-CSRF-Token'], 'bootstrap-csrf');
console.log('TOYBACO_BROWSER_SESSION_JS=PASS csrf unsafe-methods same-origin bootstrap-dedup no-bearer');
