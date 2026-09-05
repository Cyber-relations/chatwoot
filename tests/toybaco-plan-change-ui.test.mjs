import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const overlay = process.argv[2] ? path.resolve(process.argv[2]) : path.join(root, 'overlay/app');
const source = fs.readFileSync(path.join(overlay, 'public/brand-assets/toybaco-plan-change.js'), 'utf8');
const view = fs.readFileSync(path.join(overlay, 'app/views/toybaco/billing/show.html.erb'), 'utf8');
const selection = { plan_id: 'pro', plan_version: 'version-fixture', cycle: 'month' };
const available = { status: 'available', choices: [{ ...selection, name: 'テストプラン', amount: 44800, policy: { kind: 'upgrade' } }] };
const periodEnd = Date.UTC(2026, 9, 4, 12, 0) / 1000;
const quote = (kind = 'upgrade') => ({
  quote: { target_name: 'テストプラン', target_amount: 44800, selection, policy: { kind },
    amount_due: 13672, period_end: periodEnd, effects: { agent_limit: null, ai_reply_limit: 500, posting: true } },
  confirmation_token: 'opaque-confirm-token',
});

function fixture(initial = available, { absent = false, inline = false, both = false } = {}) {
  const elements = new Map();
  const calls = [];
  const requests = [];
  let reloads = 0;
  class Element {
    constructor(id = '') { this.id = id; this.hidden = false; this._disabled = false; this.inert = false; this.children = []; this.listeners = {}; this.attributes = {}; this.style = {}; this.textContent = ''; }
    get disabled() { return this._disabled; }
    set disabled(value) {
      this._disabled = value;
      if (value && document.activeElement === this) document.activeElement = document.body;
    }
    addEventListener(type, handler) { (this.listeners[type] ||= []).push(handler); }
    fire(type, values = {}) {
      const event = { target: this, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; }, ...values };
      for (const handler of this.listeners[type] || []) handler(event);
      return event;
    }
    click() { if (!this.disabled && !this.hidden) this.fire('click'); }
    focus() { if (!this.disabled) document.activeElement = this; }
    setAttribute(key, value) { this.attributes[key] = value; }
    removeAttribute(key) { delete this.attributes[key]; if (key === 'href') delete this.href; }
    appendChild(child) { child.parentNode = this; this.children.push(child); return child; }
    replaceChildren() { this.children = []; }
    set innerHTML(_) { throw new Error('Untrusted billing content must never be inserted as HTML'); }
  }
  const document = new Element();
  document.body = new Element('body');
  document.activeElement = document.body;
  document.getElementById = id => elements.get(id) || null;
  document.createElement = () => new Element();
  for (const match of view.matchAll(/<[^>]+\bid="([^"]+)"[^>]*>/g)) {
    const element = new Element(match[1]);
    element.hidden = /\bhidden(?:\s|>)/.test(match[0]);
    elements.set(element.id, element);
  }
  if (absent) elements.delete('plan-change-panel');
  elements.get('plan-change-state').textContent = JSON.stringify(initial);
  elements.get('cancel-open').parentNode = elements.get('cancel-box');
  const location = { pathname: '/toybaco/billing', search: '?account_id=42', reload() { reloads += 1; } };
  const fetch = (url, options) => {
    calls.push({ url, options });
    return new Promise((resolve, reject) => requests.push({ resolve, reject }));
  };
  const scripts = [...view.matchAll(/<script>([\s\S]*?)<\/script>/g)];
  const context = { document, window: { location, open() {} }, fetch, Intl, URL, Date };
  vm.runInNewContext(inline || both ? scripts.at(-1)[1] : source, context);
  if (both) vm.runInNewContext(source, context);
  return {
    elements, calls, document, el: id => elements.get(`plan-change-${id}`), reloads: () => reloads,
    async respond(data, ok = true) {
      assert.ok(requests.length, 'a real UI request must be pending');
      requests.shift().resolve({ ok, json: async () => data });
      await new Promise(resolve => setImmediate(resolve));
    },
    async reject() {
      requests.shift().reject(new Error('technical transport failure'));
      await new Promise(resolve => setImmediate(resolve));
    },
  };
}

async function openPreview(f, data = quote()) {
  f.el('preview').focus();
  f.el('form').fire('submit');
  await f.respond(data);
}

test('available choices use safe text, exact selection and same-origin JSON without changing billing yet', async () => {
  const input = structuredClone(available);
  input.choices[0].name = '<img src=x onerror=alert(1)>';
  const f = fixture(input);
  assert.equal(f.el('form').hidden, false);
  assert.match(f.el('select').children[0].textContent, /<img src=x/);
  assert.equal(f.calls.length, 0);
  f.el('form').fire('submit');
  f.el('form').fire('submit');
  assert.equal(f.calls.length, 1, 'double preview is prevented while a request is pending');
  assert.equal(f.calls[0].url, '/toybaco/billing/change_preview?account_id=42');
  assert.equal(f.calls[0].options.credentials, 'same-origin');
  assert.equal(f.calls[0].options.headers['Content-Type'], 'application/json');
  assert.deepEqual(JSON.parse(f.calls[0].options.body), selection);
  await f.respond(quote());
  assert.equal(f.calls.length, 1, 'preview never submits a change automatically');
});

test('upgrade confirmation shows exact invoice quote and target rights, including zero payable amount', async () => {
  const f = fixture();
  const data = quote();
  data.quote.amount_due = 0;
  await openPreview(f, data);
  assert.equal(f.el('dialog').hidden, false);
  assert.match(f.el('detail').textContent, /通常料金 ¥44,800（税別）/);
  assert.match(f.el('detail').textContent, /今回のお支払い額 ¥0/);
  assert.match(f.el('detail').textContent, /人数上限 上限なし/);
  assert.match(f.el('detail').textContent, /AI の月間上限 500回/);
  assert.match(f.el('detail').textContent, /SNS 予約投稿 利用できます/);
  assert.match(f.el('detail').textContent, /お支払い完了後に切り替わります/);
  assert.match(f.el('detail').textContent, /AI の当月利用回数は引き継ぎます/);
});

test('confirmation keyboard focus is trapped, Escape restores the opener and page accessibility', async () => {
  const f = fixture();
  f.el('preview').focus();
  f.el('form').fire('submit');
  assert.equal(f.document.activeElement, f.document.body, 'disabling the focused button blurs it in the browser');
  await f.respond(quote());
  assert.equal(f.document.activeElement, f.el('back'));
  assert.equal(f.elements.get('billing-content').inert, true);
  assert.equal(f.document.fire('keydown', { key: 'Tab', shiftKey: true }).defaultPrevented, true);
  assert.equal(f.document.activeElement, f.el('confirm'));
  f.document.fire('keydown', { key: 'Tab' });
  assert.equal(f.document.activeElement, f.el('back'));
  f.document.fire('keydown', { key: 'Escape' });
  assert.equal(f.el('dialog').hidden, true);
  assert.equal(f.elements.get('billing-content').inert, false);
  assert.equal(f.document.activeElement, f.el('preview'));
  f.el('confirm').fire('click');
  assert.equal(f.calls.length, 1, 'closed confirmation cannot be replayed');
});

test('confirmed upgrade sends only the opaque token once and leaves payment pending rights unchanged', async () => {
  const f = fixture();
  await openPreview(f);
  f.el('confirm').click();
  f.el('confirm').fire('click');
  assert.equal(f.calls.length, 2);
  assert.equal(f.calls[1].url, '/toybaco/billing/change_confirm?account_id=42');
  assert.deepEqual(JSON.parse(f.calls[1].options.body), { confirmation_token: 'opaque-confirm-token' });
  f.document.fire('keydown', { key: 'Escape' });
  assert.equal(f.el('dialog').hidden, false, 'in-flight confirmation cannot be dismissed and resubmitted');
  await f.respond({ status: 'payment_pending', payment_url: 'https://invoice.stripe.com/i/fixture' });
  assert.equal(f.el('form').hidden, true);
  assert.match(f.el('status').textContent, /現在のプランを継続/);
  assert.equal(f.el('payment').href, 'https://invoice.stripe.com/i/fixture');
  assert.equal(f.el('refresh').hidden, false);
});

test('downgrade and cycle changes disclose the exact period end, retained data and no immediate payment', async () => {
  for (const kind of ['downgrade', 'cycle_change']) {
    const f = fixture();
    const data = quote(kind);
    data.quote.selection = { ...selection, cycle: 'year' };
    data.quote.effects = { agent_limit: 3, ai_reply_limit: 0, posting: false };
    delete data.quote.amount_due;
    await openPreview(f, data);
    assert.match(f.el('detail').textContent, /年払い/);
    assert.match(f.el('detail').textContent, /2026年10月4日.*21:00（日本時間）/);
    assert.match(f.el('detail').textContent, /今すぐの請求や日割り精算はありません/);
    assert.match(f.el('detail').textContent, /人数上限 3名/);
    assert.match(f.el('detail').textContent, /AI の月間上限 0回/);
    assert.match(f.el('detail').textContent, /SNS 予約投稿 利用できません/);
    assert.match(f.el('detail').textContent, /既存メンバーやデータは削除しません/);
    assert.equal(f.el('confirm').textContent, '変更を予約する');
  }
});

test('incomplete financial or rights quotes cannot open a confirmable dialog', async () => {
  for (const mutate of [q => delete q.amount_due, q => q.amount_due = '100', q => delete q.effects, q => q.effects.agent_limit = -1]) {
    const f = fixture();
    const data = quote();
    mutate(data.quote);
    await openPreview(f, data);
    assert.equal(f.el('dialog').hidden, true);
    assert.equal(f.el('error').hidden, false);
    assert.equal(f.calls.length, 1);
  }
});

test('reservation cancellation requires a separate confirmation and uses its own opaque token', async () => {
  const f = fixture({ status: 'reserved', target_name: 'ライト', cycle: 'month', effective_at: periodEnd, cancellation_token: 'cancel-token' });
  assert.equal(f.el('form').hidden, true);
  f.el('cancel-reservation').focus();
  f.el('cancel-reservation').click();
  assert.equal(f.calls.length, 0);
  assert.match(f.el('detail').textContent, /ご契約自体は解約されません/);
  f.el('back').click();
  assert.equal(f.calls.length, 0);
  f.el('cancel-reservation').click();
  f.el('confirm').click();
  assert.equal(f.calls[0].url, '/toybaco/billing/change_cancel?account_id=42');
  assert.deepEqual(JSON.parse(f.calls[0].options.body), { confirmation_token: 'cancel-token' });
  await f.respond({ status: 'released' });
  assert.match(f.el('status').textContent, /変更予約を取り消しました/);
  f.el('reload').click();
  assert.equal(f.reloads(), 1);
});

test('uncertain confirmation switches to recovery and displays server conflict text without HTML insertion', async () => {
  const f = fixture();
  await openPreview(f);
  f.el('confirm').click();
  await f.respond({ message: '別の変更予約があります。<script>untrusted</script>' }, false);
  assert.equal(f.el('form').hidden, true);
  assert.equal(f.el('dialog').hidden, true);
  assert.equal(f.el('refresh').hidden, false);
  assert.match(f.el('error').textContent, /別の変更予約があります。<script>/);
  f.el('refresh').click();
  assert.equal(f.calls[2].url, '/toybaco/billing/change_refresh?account_id=42');
  assert.deepEqual(JSON.parse(f.calls[2].options.body), {});
  await f.respond({ status: 'applied' });
  f.el('reload').click();
  assert.equal(f.reloads(), 1);
});

test('network failures use Japanese recovery copy instead of technical errors', async () => {
  const f = fixture();
  f.el('form').fire('submit');
  await f.reject();
  assert.match(f.el('error').textContent, /契約情報を確認できません/);
  assert.doesNotMatch(f.el('error').textContent, /technical|fetch/);
  assert.equal(f.el('preview').disabled, false);
});

test('pending and uncertain states refresh only on request; unsafe payment URLs remain hidden', async () => {
  for (const status of ['requested', 'creating', 'created', 'configuring', 'releasing', 'effective', 'review']) {
    const f = fixture({ status });
    assert.equal(f.calls.length, 0, 'no automatic polling or replay');
    assert.equal(f.el('refresh').hidden, false);
    assert.equal(f.el('form').hidden, true);
    f.el('refresh').click();
    f.el('refresh').fire('click');
    assert.equal(f.calls.length, 1);
    await f.respond({ status: 'expired' });
    assert.equal(f.el('reload').hidden, false);
  }
  for (const payment_url of ['javascript:alert(1)', 'https://invoice.stripe.com.evil.example/i', 'https://user@invoice.stripe.com/i', 'http://invoice.stripe.com/i']) {
    const f = fixture({ status: 'payment_pending', payment_url });
    assert.equal(f.el('payment').hidden, true);
    assert.equal(f.el('payment').href, undefined);
  }
});

test('server JSON is escaped and unauthorized or unsupported pages cannot submit changes', () => {
  assert.match(view, /raw\(json_escape\(@plan_changes\.to_json\)\)/);
  assert.match(view, /if @admin && @plan_changes/);
  assert.equal(fixture(available, { absent: true }).calls.length, 0);
  const f = fixture({ status: 'unavailable', message: '個別の契約条件を確認します。' });
  assert.equal(f.el('form').hidden, true);
  assert.equal(f.el('support').hidden, false);
  assert.equal(f.el('status').textContent, '個別の契約条件を確認します。');
});

test('the existing two-click subscription cancellation shows a server conflict and stays separate', async () => {
  const f = fixture(available, { inline: true });
  f.elements.get('cancel-open').click();
  assert.equal(f.calls.length, 0);
  f.elements.get('cancel-confirm').click();
  assert.equal(f.calls[0].url, '/toybaco/billing/cancel?account_id=42');
  assert.equal(f.calls[0].options.body, undefined, 'ordinary cancellation has no reservation token');
  assert.equal(f.elements.get('cancel-reservation-note').hidden, true);
  await f.respond({ message: '変更予約を取り消してから解約してください。' }, false);
  assert.equal(f.elements.get('cancel-err').textContent, '変更予約を取り消してから解約してください。');
  assert.equal(f.elements.get('cancel-err').style.display, 'block');
  assert.equal(f.elements.get('cancel-dialog').hidden, true);
  assert.equal(f.elements.get('cancel-open').hidden, false);
});

test('owned reservation and period-end cancellation share the original two clicks and bind the displayed token', async () => {
  const f = fixture({ status: 'reserved', cancellation_token: 'reservation-token' }, { inline: true });
  assert.match(view, /id="cancel-reservation-note" hidden>変更予約を取り消し、現在の契約期間末で解約します。/);
  f.elements.get('cancel-open').click();
  assert.equal(f.calls.length, 0, 'the first click only presents the combined cancellation');
  assert.equal(f.elements.get('cancel-reservation-note').hidden, false);
  f.el('state').textContent = JSON.stringify({ status: 'reserved', cancellation_token: 'changed-token' });
  f.elements.get('cancel-confirm').click();
  f.elements.get('cancel-confirm').fire('click');
  assert.equal(f.calls.length, 1, 'the second click performs one combined server operation');
  assert.equal(f.calls[0].options.credentials, 'same-origin');
  assert.equal(f.calls[0].options.headers['Content-Type'], 'application/json');
  assert.deepEqual(JSON.parse(f.calls[0].options.body), { reservation_token: 'reservation-token' });
  await f.respond({ cancelled: true });
  assert.equal(f.elements.get('cancel-open').hidden, true);
  assert.equal(f.elements.get('plan-change-panel').hidden, true, 'stale reservation actions are removed after cancellation');
  assert.match(f.elements.get('cancel-box').children[0].textContent, /次回分の請求は発生しません/);
});

test('a reservation made on the current page is available to two-click cancellation without a reload', async () => {
  const f = fixture(available, { both: true });
  await openPreview(f, quote('cycle_change'));
  f.el('confirm').click();
  await f.respond({ status: 'reserved', cancellation_token: 'new-reservation-token' });
  f.elements.get('cancel-open').click();
  assert.equal(f.elements.get('cancel-reservation-note').hidden, false);
  assert.equal(f.calls.length, 2);
  f.elements.get('cancel-confirm').click();
  assert.deepEqual(JSON.parse(f.calls[2].options.body), { reservation_token: 'new-reservation-token' });
  await f.respond({ cancelled: true });
});

test('back cancels consent and external or pending changes do not get an invented reservation token', async () => {
  for (const initial of [{ status: 'payment_pending' }, { status: 'unavailable' }, { status: 'reserved', cancellation_token: '' }]) {
    const f = fixture(initial, { inline: true });
    f.elements.get('cancel-open').click();
    assert.equal(f.elements.get('cancel-reservation-note').hidden, true);
    f.elements.get('cancel-back').click();
    f.elements.get('cancel-confirm').fire('click');
    assert.equal(f.calls.length, 0, 'dismissed confirmation cannot be replayed');
    f.elements.get('cancel-open').click();
    f.elements.get('cancel-confirm').click();
    assert.equal(f.calls[0].options.body, undefined);
    await f.respond({ message: 'お支払いの確認を先に行ってください。' }, false);
    assert.equal(f.elements.get('cancel-err').textContent, 'お支払いの確認を先に行ってください。');
  }
});
