import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import vm from 'node:vm';

const root = process.argv[2];
assert(root, 'usage: node chatwoot-widget-cookie.test.mjs ROOT');
const source = readFileSync(join(root, 'overlay/app/app/javascript/sdk/cookieHelpers.js'), 'utf8');
assert.equal((source.match(/^import Cookies from 'js-cookie';$/gm) || []).length, 1);
const moduleBody = source.replace(/^import Cookies from 'js-cookie';$/m, '').replace(/^export const /gm, 'const ');
let observations = 0;
for (const protocol of ['https:', 'http:']) {
  const calls = [];
  const context = {
    Cookies: { set: (...args) => calls.push(args) },
    window: { location: { protocol }, $chatwoot: { websiteToken: 'synthetic-public-id' } },
    TextEncoder,
  };
  vm.runInNewContext(`${moduleBody}\nsetCookieWithDomain('cw_conversation', 'synthetic-jwt');\nsetCookieWithDomain('cw_user_synthetic', { marker: 'synthetic' }, { expires: 7, baseDomain: 'example.invalid' });`, context);
  assert.equal(calls.length, 2);
  for (const call of calls) {
    assert.equal(call[2].secure, protocol === 'https:');
    assert.equal(call[2].sameSite, 'Lax');
    observations += 2;
  }
  assert.equal(calls[0][2].expires, 365);
  assert.equal(calls[1][2].expires, 7);
  assert.equal(calls[1][2].domain, 'example.invalid');
  assert.equal(calls[1][1], JSON.stringify({ marker: 'synthetic' }));
  observations += 4;
}
console.log(JSON.stringify({ sdk_cookie_options: 'PASS', observations, actual_browser_cookie_acceptance: false }));
