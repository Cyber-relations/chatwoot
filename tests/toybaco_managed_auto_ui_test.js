'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../overlay/app/public/brand-assets/toybaco-managed-auto.js'), 'utf8');
const tick = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };
function setup(respond) {
  const nodes = Object.fromEntries(['status', 'register', 'enable', 'stop', 'inbox', 'refresh', 'error'].map(id => [id, {
    value: '22', textContent: '', disabled: false, handlers: {}, addEventListener(name, fn) { this.handlers[name] = fn; }
  }]));
  const requests = [];
  let nonce = 0;
  const context = {
    document: { querySelector() { return { dataset: { accountId: '12' } }; }, getElementById(id) { return nodes[id]; } },
    crypto: { randomUUID() { return `00000000-0000-4000-8000-${String(++nonce).padStart(12, '0')}`; } },
    AbortController, setTimeout, clearTimeout,
    async fetch(url, options) {
      const request = { url, ...options, body: options.body && JSON.parse(options.body) };
      requests.push(request);
      const data = await respond(request, requests.length);
      return { ok: true, async json() { return data; } };
    }
  };
  vm.runInNewContext(source, context, { filename: 'toybaco-managed-auto.js' });
  return { nodes, requests, async click(id) { if (!nodes[id].disabled) nodes[id].handlers.click(); await tick(); } };
}

test('registration is initially draft and retries a lost response with the same request id', async () => {
  let post = 0;
  const app = setup(async request => {
    if (request.method === 'GET') return { state: 'unconnected', enabled: true };
    if (++post === 1) throw new Error('connection lost');
    return { state: 'draft', generation: '1', epoch: '00000000-0000-4000-8000-000000000099', pending: false };
  });
  await tick();
  assert.equal(app.nodes.enable.disabled, true);
  await app.click('register');
  assert.match(app.nodes.error.textContent, /connection lost/);
  await app.click('register');
  assert.equal(app.requests[1].body.request_id, app.requests[2].body.request_id);
  assert.equal(app.requests[1].body.inbox_id, 22);
  assert.equal(app.nodes.enable.disabled, false);
  assert.equal(app.nodes.register.disabled, true);
  assert.match(app.nodes.status.textContent, /下書き/);
  assert.equal(app.requests[0].credentials, 'same-origin');
  assert.equal(app.requests[0].cache, 'no-store');
});

test('stop remains pending until the server confirms completion and cannot auto restart', async () => {
  const epoch = '00000000-0000-4000-8000-000000000099';
  let reads = 0;
  const app = setup(async request => {
    if (request.method === 'GET') return ++reads === 1 ? { state: 'auto', enabled: true, generation: '4', epoch, pending: true } :
      { state: 'stopped', enabled: true, generation: '5', epoch, pending: false };
    assert.equal(request.body.mode, 'stopped');
    assert.equal(request.body.generation, '4');
    assert.equal(request.body.epoch, epoch);
    return { state: 'stopping', generation: '5', epoch, pending: true };
  });
  await tick();
  await app.click('stop');
  assert.match(app.nodes.status.textContent, /停止処理中/);
  assert.doesNotMatch(app.nodes.status.textContent, /停止済み/);
  assert.equal(app.nodes.enable.disabled, true);
  await app.click('refresh');
  assert.match(app.nodes.status.textContent, /停止済み/);
  assert.equal(app.nodes.enable.disabled, false);
});

test('disabled rollout never offers new automatic execution but still permits stopping', async () => {
  const app = setup(async () => ({ state: 'auto', enabled: false, generation: '4', epoch: 'x', pending: false }));
  await tick();
  assert.match(app.nodes.status.textContent, /受付停止中/);
  assert.equal(app.nodes.register.disabled, true);
  assert.equal(app.nodes.enable.disabled, true);
  assert.equal(app.nodes.stop.disabled, false);
});
