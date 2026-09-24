import test from 'node:test';
import assert from 'node:assert/strict';
import { mountRetention, selectionError } from '../overlay/app/public/toybaco-growth-retention.mjs';

function fixture(fetcher) {
  const events = new Map();
  const inputs = [{ name: 'inboxes', value: '1', checked: true }, { name: 'inboxes', value: '2', checked: false },
    { name: 'posting_accounts', value: 'a', checked: true }];
  const button = { focus() { this.focused = true; } };
  const form = {
    addEventListener(name, fn) { events.set(name, fn); },
    querySelectorAll(selector) {
      if (selector === 'input,button') return [...inputs, button];
      const kind = selector.match(/name="([a-z_]+)"/)[1];
      return inputs.filter(input => input.name === kind && input.checked);
    },
  };
  const state = { account_id: 4, target: 'free', revision: 'before', inventory: { inboxes: [{ id: '1' }, { id: '2' }], posting_accounts: [{ id: 'a' }] },
    plan: { inboxes: { limit: 1, hold: ['2'] }, posting_accounts: { limit: 1, hold: [] }, posts: { hold: ['late'] } } };
  const elements = { '#retention-form': form, '#retention-state': { textContent: JSON.stringify(state) },
    '#retention-error': {}, '#retention-status': {}, '#retention-summary': {}, '#retention-save': button };
  mountRetention({ querySelector: selector => elements[selector] }, fetcher);
  return { elements, inputs, button, state, change: () => events.get('change')(), submit: () => events.get('submit')({ preventDefault() {} }) };
}

test('per-kind limit has a concise error', () => {
  assert.equal(selectionError({ inboxes: ['1'], posting_accounts: [] }, { inboxes: 2, posting_accounts: 1 }), '');
  assert.match(selectionError({ inboxes: ['1', '2'], posting_accounts: [] }, { inboxes: 1, posting_accounts: 1 }), /上限/);
});

test('over-limit choices do not send a request', async () => {
  const ui = fixture(() => { throw new Error('must not send'); });
  ui.inputs[1].checked = true;
  ui.change();
  await ui.submit();
  assert.match(ui.elements['#retention-error'].textContent, /上限/);
});

test('one request while saving; inputs locked and successful revision retained', async () => {
  const calls = [];
  let complete;
  const ui = fixture((url, options) => {
    calls.push({ url, options });
    return new Promise(resolve => { complete = resolve; });
  });
  const pending = ui.submit();
  await ui.submit();
  assert.equal(calls.length, 1);
  assert.ok(ui.inputs.every(input => input.disabled));
  assert.equal(ui.button.disabled, true);
  complete({ ok: true, json: async () => ({ ...ui.state, revision: 'after' }) });
  await pending;
  assert.equal(ui.button.disabled, false);
  assert.match(ui.elements['#retention-status'].textContent, /保存しました/);
  assert.match(ui.elements['#retention-summary'].textContent, /1件の予約/);
  const again = ui.submit();
  assert.equal(JSON.parse(calls[1].options.body).revision, 'after');
  assert.equal(calls[0].options.credentials, 'same-origin');
  complete({ ok: true, json: async () => ({ ...ui.state, revision: 'last' }) });
  await again;
});

test('stale or failed response keeps selected inputs and does not automatically resend', async () => {
  let calls = 0;
  const ui = fixture(async () => { calls++; return { ok: false, json: async () => ({ error: '画面を更新してください。' }) }; });
  ui.inputs[0].checked = false;
  ui.inputs[1].checked = true;
  await ui.submit();
  assert.equal(calls, 1);
  assert.equal(ui.inputs[0].checked, false);
  assert.equal(ui.inputs[1].checked, true);
  assert.equal(ui.button.disabled, false);
  assert.equal(ui.elements['#retention-error'].textContent, '画面を更新してください。');
});

import { mountInboxRelease, releaseError, releaseRequestId } from '../overlay/app/public/toybaco-growth-inbox-release.mjs';

function releaseFixture(fetcher) {
  const events = new Map();
  const state = { account_id: 4, revision: 'a'.repeat(64), limit: 2,
    inboxes: [{ id: '1', held: false }, { id: '2', held: true }, { id: '3', held: true }] };
  const inputs = state.inboxes.map(row => ({ value: row.id, checked: !row.held }));
  const focusable = () => ({ focus() { this.focused = true; } });
  const button = focusable(), status = focusable();
  const form = { querySelectorAll: () => inputs, addEventListener(name, fn) { events.set(name, fn); } };
  const elements = { '#inbox-release-form': form, '#inbox-release-state': { textContent: JSON.stringify(state) },
    '#inbox-release-submit': button, '#inbox-release-status': status, '#inbox-release-error': {}, '#inbox-release-refresh': {} };
  for (const row of state.inboxes) elements[`[data-inbox-state="${row.id}"]`] = {};
  let nonce = 0;
  mountInboxRelease({ querySelector: selector => elements[selector] }, fetcher, () => (++nonce).toString(16).padStart(64, '0'));
  return { state, inputs, elements, button, status, change: () => events.get('change')(),
    submit: () => events.get('submit')({ preventDefault() {} }) };
}

test('release limits count retained inboxes and id uses 32 random bytes', () => {
  assert.match(releaseRequestId({ getRandomValues: array => { assert.equal(array.length, 32); return array.fill(15); } }), /^(0f){32}$/);
  assert.match(releaseError([], { limit: 2, inboxes: [] }), /選んで/);
  assert.match(releaseError(['2', '3'], { limit: 2, inboxes: [{ held: false }] }), /合計2件/);
});

test('release UI preserves active inboxes, enforces limit, and sends no automatic request', async () => {
  let calls = 0;
  const ui = releaseFixture(() => { calls++; throw new Error('must not send'); });
  assert.equal(ui.inputs[0].disabled, true);
  assert.equal(ui.button.disabled, true);
  ui.inputs[1].checked = ui.inputs[2].checked = true;
  ui.change();
  await ui.submit();
  assert.equal(calls, 0);
  assert.match(ui.elements['#inbox-release-error'].textContent, /合計2件/);
});

test('only one explicit release while pending, safe fields only, then current state and accessible focus', async () => {
  let resolve;
  const calls = [];
  const ui = releaseFixture((url, options) => { calls.push({ url, options }); return new Promise(done => { resolve = done; }); });
  ui.inputs[1].checked = true;
  const pending = ui.submit();
  await ui.submit();
  assert.equal(calls.length, 1);
  assert(ui.inputs.every(input => input.disabled));
  const request = JSON.parse(calls[0].options.body);
  assert.deepEqual(Object.keys(request).sort(), ['inbox_ids', 'request_id', 'revision']);
  assert.deepEqual(request.inbox_ids, ['2']);
  assert.equal(calls[0].url, '/toybaco/growth/inbox-release?account_id=4');
  assert.equal(calls[0].options.credentials, 'same-origin');
  resolve({ ok: true, json: async () => ({ ...ui.state, revision: 'b'.repeat(64),
    inboxes: ui.state.inboxes.map(row => ({ ...row, held: row.id === '3' })) }) });
  await pending;
  assert.equal(ui.inputs[1].disabled, true);
  assert.equal(ui.inputs[1].checked, true);
  assert.equal(ui.inputs[2].disabled, false);
  assert.equal(ui.inputs[2].checked, false);
  assert.match(ui.status.textContent, /再開しました/);
  assert.equal(ui.status.focused, true);
  assert.equal(calls.length, 1);
});

test('lost response retries identical operation; changed choice has a fresh id and no background resend', async () => {
  const requests = [];
  const ui = releaseFixture(async (_, options) => { requests.push(JSON.parse(options.body)); throw new Error('通信を確認してください。'); });
  ui.inputs[1].checked = true;
  await ui.submit();
  assert.equal(ui.inputs[1].checked, true);
  assert.equal(ui.elements['#inbox-release-refresh'].hidden, false);
  await ui.submit();
  assert.deepEqual(requests[0], requests[1]);
  ui.inputs[1].checked = false;
  ui.inputs[2].checked = true;
  ui.change();
  await ui.submit();
  assert.notEqual(requests[2].request_id, requests[1].request_id);
  assert.deepEqual(requests[2].inbox_ids, ['3']);
  assert.equal(requests.length, 3);
});

test('foreign, malformed, or historical replies never claim a currently-held inbox was resumed', async () => {
  for (const kind of ['foreign', 'malformed', 'historical', 'conflict']) {
    let ui;
    ui = releaseFixture(async () => ({ ok: kind !== 'conflict', json: async () => kind === 'malformed' ? {} :
      kind === 'conflict' ? { error: '画面を更新してください。' } : { ...ui.state, account_id: kind === 'foreign' ? 5 : 4 } }));
    ui.inputs[1].checked = true;
    await ui.submit();
    assert.equal(ui.status.textContent, '');
    assert.equal(ui.elements['#inbox-release-error'].hidden, false);
    assert.equal(ui.elements['#inbox-release-refresh'].hidden, false);
    assert.equal(ui.inputs[1].disabled, false);
  }
});


test('transport and malformed JSON details never leak into the release screen', async () => {
  for (const fetcher of [
    async () => { throw new Error('fixture-private-network-detail'); },
    async () => ({ ok: true, json: async () => { throw new SyntaxError('fixture-private-html-response'); } }),
    async () => ({ ok: false, json: async () => ({ error: 'fixture-private-provider-detail' }) }),
  ]) {
    const ui = releaseFixture(fetcher);
    ui.inputs[1].checked = true;
    await ui.submit();
    assert.doesNotMatch(ui.elements['#inbox-release-error'].textContent, /fixture-private/);
    assert.match(ui.elements['#inbox-release-error'].textContent, /再開/);
    assert.equal(ui.inputs[1].checked, true);
    assert.equal(ui.status.textContent, '');
  }
});
