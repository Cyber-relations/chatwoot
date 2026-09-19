import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { randomUUID } from 'node:crypto';

const read = path => fs.readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const source = read('overlay/app/public/brand-assets/toybaco-connection-handoff.js');
const ID = '12121212-3434-4567-8abc-121212121212';
const TOKEN = 'a'.repeat(64);
const ORIGIN = 'https://app.staging.toybaco.jp';
const result = (state = 'issued', extra = {}) => ({ id: ID, provider: 'line', state,
  expires_at: '2026-09-20T00:00:00Z', store_name: 'テスト店舗', ...extra });
const response = (value, status = 200) => ({ ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(value) });
const wait = async () => { for (let i = 0; i < 12; i++) await new Promise(resolve => setImmediate(resolve)); };
function page(mode, fetcher, query = '', data = {}) {
  const html = read(`overlay/app/app/views/toybaco/connections/handoff_${mode}.html.erb`);
  const nodes = new Map();
  const events = new Map();
  const calls = [];
  const timers = new Map();
  let timerId = 0;
  let reloaded = 0;
  let focused = '';
  for (const match of html.matchAll(/<(\w+)\b([^>]*\sid="([^"]+)"[^>]*)>/g)) {
    const [, tag, attrs, id] = match;
    const listeners = new Map();
    nodes.set(id, { id, tag, value: '', textContent: '', hidden: /\bhidden\b/.test(attrs), disabled: false, readOnly: /\breadonly\b/.test(attrs),
      dataset: id === 'handoff' ? { mode, accountId: '4', requestId: ID, ...data } : {},
      addEventListener: (type, fn) => listeners.set(type, fn),
      fire: type => listeners.get(type)?.({ preventDefault() {} }),
      setAttribute() {}, removeAttribute() {}, focus() { focused = id; }, select() { focused = id; },
      querySelectorAll: tagName => [...nodes.values()].filter(node => node.tag === tagName),
    });
  }
  const location = new URL(`${ORIGIN}/toybaco/connections/${mode === 'owner' ? 'handoff' : `help/${ID}`}${query}`);
  location.reload = () => { reloaded++; };
  const navigations = [];
  location.assign = value => { navigations.push(value); };
  const context = {
    URL, URLSearchParams, Date, Intl, AbortController, crypto: { randomUUID },
    location, history: { replaceState(_, __, value) { location.href = new URL(value, location).href; } },
    document: { getElementById: id => nodes.get(id), visibilityState: 'visible' },
    navigator: { clipboard: { writeText: async value => { context.copied = value; } } },
    setTimeout: (fn, delay) => { timers.set(++timerId, { fn, delay }); return timerId; },
    clearTimeout: id => timers.delete(id),
    fetch: async (path, options) => { calls.push({ path, options, body: options.body && JSON.parse(options.body) }); return fetcher(calls.at(-1), calls); },
    addEventListener: (type, fn) => { events.set(type, [...(events.get(type) || []), fn]); },
  };
  context.window = context;
  vm.runInNewContext(source, context);
  return { nodes, calls, context, timers, html, navigations, get focused() { return focused; }, get reloaded() { return reloaded; },
    fire(id, type = 'click') { return nodes.get(id).fire(type); },
    event(type, value = {}) { events.get(type)?.forEach(fn => fn(value)); } };
}

test('owner issues only on explicit submission and keeps secrets out of address bar', async () => {
  const ui = page('owner', () => response(result('issued', { url: `${ORIGIN}/toybaco/connections/help/${ID}#${TOKEN}` })));
  assert.equal(ui.calls.length, 0);
  ui.nodes.get('recipient').value = 'helper@example.test';
  ui.fire('request-form', 'submit');
  await wait();
  assert.equal(ui.calls.length, 1);
  assert.equal(ui.calls[0].body.handoff.provider, 'line');
  assert.equal(ui.calls[0].body.handoff.recipient, 'helper@example.test');
  assert.equal(ui.calls[0].options.credentials, 'same-origin');
  assert.equal(ui.calls[0].options.redirect, 'error');
  assert.equal(ui.context.location.hash, '');
  assert.equal(ui.context.location.search, `?account_id=4&id=${ID}`);
  assert.equal(ui.nodes.get('recipient').value, '');
  assert.equal(ui.nodes.get('request-link').value.endsWith(TOKEN), true);
  ui.fire('copy-link'); await wait();
  assert.equal(ui.context.copied, ui.nodes.get('request-link').value);
});

test('lost creation receipt freezes request key and payload instead of creating a second invitation', async () => {
  const ui = page('owner', (_call, calls) => {
    if (calls.length === 1) throw new TypeError('network');
    return response(result('issued', { url: `${ORIGIN}/toybaco/connections/help/${ID}#${TOKEN}` }));
  });
  ui.nodes.get('recipient').value = 'helper@example.test';
  ui.fire('request-form', 'submit'); await wait();
  assert.equal(ui.nodes.get('recipient').disabled, true);
  ui.nodes.get('recipient').value = 'forged@example.test';
  ui.fire('request-form', 'submit'); await wait();
  assert.deepEqual(ui.calls[0].body, ui.calls[1].body);
  assert.equal(ui.calls[1].body.handoff.recipient, 'helper@example.test');
});

test('owner refuses external or cross-request invitation URLs and refreshes existing requests', async () => {
  for (const url of [`https://evil.example/help/${ID}#${TOKEN}`, `${ORIGIN}/wrong#${TOKEN}`]) {
    const ui = page('owner', () => response(result('issued', { url })), `?account_id=4&id=${ID}`);
    await wait();
    assert.equal(ui.nodes.get('link-box').hidden, true);
    assert.equal(ui.nodes.get('request-link').value, '');
    assert.equal(ui.calls.length, 1);
    assert.equal(ui.calls[0].options.method, 'GET');
  }
});

test('portal uses fragment proof and does not request email automatically', async () => {
  const ui = page('portal', call => call.path.endsWith('/session') ? response({}, 403) : response(result()), `#${TOKEN}`);
  await wait();
  assert.equal(ui.calls.length, 2);
  assert.equal(ui.calls[1].path, `/toybaco/connections/help/${ID}/open`);
  assert.equal(ui.calls[1].body.link_secret, TOKEN);
  assert.equal(ui.calls.some(call => call.path.includes(TOKEN)), false);
  assert.equal(ui.nodes.get('identity').hidden, false);
  assert.equal(ui.nodes.get('line-form').hidden, true);
  assert.equal(ui.nodes.get('store').textContent, 'テスト店舗 · LINE公式');
});

test('missing invitation proof reveals no store name', async () => {
  const ui = page('portal', () => response({}, 403));
  await wait();
  assert.equal(ui.calls.length, 1);
  assert.equal(ui.nodes.get('identity').hidden, true);
  assert.equal(ui.nodes.get('store').textContent, '');
  assert.match(ui.nodes.get('error').textContent, /依頼リンク/);
});

test('email challenge is explicit, has a cooldown and keeps wrong-code attempts usable', async () => {
  const ui = page('portal', call => {
    if (call.path.endsWith('/session')) return response({}, 403);
    if (call.path.endsWith('/verify')) return response({ error: '確認コードが一致しません。', verification_remaining: 4 }, 422);
    return response(result());
  }, `#${TOKEN}`);
  await wait();
  ui.fire('send-code'); await wait();
  assert.equal(ui.nodes.get('verify-form').hidden, false);
  assert.equal(ui.focused, 'verification-code');
  ui.fire('send-code'); await wait();
  assert.equal(ui.calls.filter(call => call.path.endsWith('/code')).length, 1);
  ui.nodes.get('verification-code').value = '123456';
  ui.fire('verify-form', 'submit'); await wait();
  assert.match(ui.nodes.get('status').textContent, /あと4回/);
  assert.equal(ui.context.location.hash, `#${TOKEN}`);
});

test('verified claim consumes fragment and exposes only the line setup form', async () => {
  const ui = page('portal', call => {
    if (call.path.endsWith('/session')) return response({}, 403);
    if (call.path.endsWith('/login')) return response(result('claimed'));
    if (call.path.endsWith('/line')) return response(result('claimed', { line_available: true }));
    return response(result());
  }, `#${TOKEN}`);
  await wait(); ui.fire('login'); await wait();
  assert.equal(ui.context.location.hash, '');
  assert.equal(ui.nodes.get('identity').hidden, true);
  assert.equal(ui.nodes.get('line-form').hidden, false);
  assert.equal(ui.calls.filter(call => call.path.endsWith('/line'))[0].options.method, 'GET');
  assert.equal(ui.nodes.get('line-channel-secret').value, '');
});

test('lost verification response recovers a claimed cookie without sending the code twice', async () => {
  let claimed = false;
  const ui = page('portal', call => {
    if (call.path.endsWith('/session')) return response({}, 403);
    if (call.path.endsWith('/verify')) { claimed = true; throw new TypeError('network'); }
    if (call.path.endsWith('/line')) return response(result('claimed', { line_available: true }));
    return response(result());
  }, `#${TOKEN}`);
  await wait();
  ui.nodes.get('verification-code').value = '123456';
  ui.fire('verify-form', 'submit'); await wait();
  assert.equal(claimed, true);
  assert.equal(ui.context.location.hash, '');
  assert.equal(ui.nodes.get('line-form').hidden, false);
  assert.equal(ui.calls.filter(call => call.path.endsWith('/verify')).length, 1);
});

const saved = () => result('completed', { line_available: true, settings_saved: true, receipt_verified: false,
  line_channel_id: '1234567890', webhook_url: `${ORIGIN}/webhooks/line/1234567890` });
function fillLine(ui) {
  ui.nodes.get('line-channel-id').value = '1234567890';
  ui.nodes.get('line-channel-secret').value = 'b'.repeat(32);
  ui.nodes.get('line-channel-token').value = 'fixtureToken'.repeat(5);
}

test('unknown save is checked read-only before another attempt and completion is not called receipt', async () => {
  let savedAtProvider = false;
  const ui = page('portal', call => {
    if (call.options.method === 'POST') { savedAtProvider = true; throw new TypeError('network'); }
    if (call.path.endsWith('/session')) return response(result('claimed'));
    return response(savedAtProvider ? saved() : result('claimed', { line_available: true }));
  });
  await wait(); fillLine(ui);
  ui.fire('line-form', 'submit'); await wait();
  assert.equal(ui.nodes.get('line-form').hidden, true);
  assert.equal(ui.nodes.get('check-save').hidden, false);
  ui.fire('line-form', 'submit'); await wait();
  assert.equal(ui.calls.filter(call => call.options.method === 'POST').length, 1);
  ui.fire('check-save'); await wait();
  assert.equal(ui.calls.at(-1).options.method, 'GET');
  assert.equal(ui.nodes.get('saved').hidden, false);
  assert.equal(ui.nodes.get('heading').textContent, '設定を保存しました');
  assert.equal(ui.nodes.get('line-channel-token').value, '');
  assert.equal(ui.nodes.get('line-channel-secret').value, '');
});

test('double submission cannot start concurrent credential verification', async () => {
  let resolve;
  const ui = page('portal', call => {
    if (call.options.method === 'POST') return new Promise(done => { resolve = done; });
    return response(result('claimed', { line_available: true }));
  });
  await wait(); fillLine(ui);
  ui.fire('line-form', 'submit'); ui.fire('line-form', 'submit'); await wait();
  assert.equal(ui.calls.filter(call => call.options.method === 'POST').length, 1);
  resolve(response(saved())); await wait();
  assert.equal(ui.nodes.get('saved').hidden, false);
});

test('page exit clears credentials, aborts requests, and requires fresh authorization after history restore', async () => {
  const ui = page('portal', call => {
    if (call.options.method === 'POST') return new Promise(() => {});
    return response(result('claimed', { line_available: true }));
  });
  await wait(); fillLine(ui); ui.fire('line-form', 'submit'); await wait();
  ui.event('pagehide');
  assert.equal(ui.calls.at(-1).options.signal.aborted, true);
  assert.equal(ui.nodes.get('line-channel-secret').value, '');
  assert.equal(ui.nodes.get('line-channel-token').value, '');
  ui.event('pageshow', { persisted: true });
  assert.equal(ui.reloaded, 1);
});


const mailResult = (provider, state = 'claimed', extra = {}) => result(state, { provider, mail_available: true, ...extra });
const authorizeUrl = (provider, changes = {}) => {
  const base = provider === 'gmail' ? 'https://accounts.google.com/o/oauth2/v2/auth' : 'https://login.microsoftonline.com/common/oauth2/v2.0/authorize';
  return `${base}?${new URLSearchParams({ client_id: 'fixture-client', response_type: 'code', state: TOKEN,
    code_challenge_method: 'S256', code_challenge: 'b'.repeat(43), redirect_uri: `${ORIGIN}/toybaco/connections/help/oauth/${provider}/callback`, ...changes })}`;
};

test('mail delegation stays fixed to the selected provider and existing inbox across retries', async () => {
  const ui = page('owner', () => response(mailResult('gmail', 'issued', { url: `${ORIGIN}/toybaco/connections/help/${ID}#${TOKEN}` })), '',
    { provider: 'gmail', inboxId: '12' });
  ui.nodes.get('recipient').value = 'helper@example.test';
  ui.fire('request-form', 'submit'); await wait();
  assert.equal(ui.calls[0].body.handoff.provider, 'gmail');
  assert.equal(ui.calls[0].body.handoff.inbox_id, '12');
  assert.equal(new URL(ui.context.location.href).searchParams.get('provider'), 'gmail');
  assert.equal(new URL(ui.context.location.href).searchParams.get('inbox_id'), '12');
});

test('withdrawn availability keeps cancellation status usable without creating another request', async () => {
  const ui = page('owner', () => response(mailResult('microsoft', 'revoked')), `?account_id=4&id=${ID}`, { provider: 'microsoft', createAvailable: 'false' });
  await wait();
  assert.equal(ui.nodes.get('request-form').hidden, true);
  ui.fire('request-form', 'submit'); await wait();
  assert.equal(ui.calls.length, 1);
});

test('Google and Microsoft setup asks for explicit authorization and never shows LINE inputs', async () => {
  for (const provider of ['gmail', 'microsoft']) {
    const ui = page('portal', call => response(call.options.method === 'POST' ? { url: authorizeUrl(provider) } : mailResult(provider)));
    await wait();
    assert.equal(ui.calls.length, 2);
    assert.equal(ui.calls[1].path, `/toybaco/connections/help/${ID}/mail`);
    assert.equal(ui.nodes.get('mail-connect').hidden, false);
    assert.equal(ui.nodes.get('line-form').hidden, true);
    assert.equal(ui.navigations.length, 0);
    ui.fire('connect-mail'); await wait();
    assert.deepEqual(ui.navigations, [authorizeUrl(provider)]);
    ui.fire('connect-mail'); await wait();
    assert.equal(ui.calls.filter(call => call.options.method === 'POST').length, 1);
  }
});

test('email-code claim recovers the selected mail provider and clears the invitation proof', async () => {
  const ui = page('portal', call => {
    if (call.path.endsWith('/session')) return response({}, 403);
    if (call.path.endsWith('/verify') || call.path.endsWith('/mail')) return response(mailResult('gmail'));
    return response(mailResult('gmail', 'issued'));
  }, `#${TOKEN}`);
  await wait();
  ui.nodes.get('verification-code').value = '123456';
  ui.fire('verify-form', 'submit'); await wait();
  assert.equal(ui.context.location.hash, '');
  assert.equal(ui.nodes.get('verification-code').value, '');
  assert.equal(ui.nodes.get('mail-connect').hidden, false);
  assert.equal(ui.calls.some(call => call.path.endsWith('/line')), false);
});

test('completed mail setup uses its current server receipt after callback or reload', async () => {
  const ui = page('portal', () => response(mailResult('microsoft', 'completed')), '?mail=retry');
  await wait();
  assert.equal(ui.nodes.get('mail-saved').hidden, false);
  assert.equal(ui.nodes.get('mail-connect').hidden, true);
  assert.equal(ui.context.location.search, '');
  ui.fire('connect-mail'); await wait();
  assert.equal(ui.calls.every(call => call.options.method === 'GET'), true);
});

test('unregistered mail callback stays closed and a forged query cannot claim completion', async () => {
  const ui = page('portal', () => response(mailResult('gmail', 'claimed', { mail_available: false })), '?mail=connected');
  await wait();
  assert.equal(ui.nodes.get('mail-connect').hidden, true);
  assert.equal(ui.nodes.get('mail-saved').hidden, true);
  assert.equal(ui.nodes.get('check-save').hidden, false);
  assert.equal(ui.navigations.length, 0);
});

test('authorization navigation rejects foreign origin, provider mismatch, redirects, weak PKCE and duplicate parameters', async () => {
  for (const url of ['https://evil.example/auth', authorizeUrl('microsoft'), authorizeUrl('gmail', { redirect_uri: 'https://evil.example' }),
    authorizeUrl('gmail', { code_challenge: 'short' }), authorizeUrl('gmail') + '&redirect_uri=https%3A%2F%2Fevil.example']) {
    const ui = page('portal', call => response(call.options.method === 'POST' ? { url } : mailResult('gmail')));
    await wait(); ui.fire('connect-mail'); await wait();
    assert.equal(ui.navigations.length, 0);
    assert.equal(ui.nodes.get('error').hidden, false);
  }
});
