/* Offline behavioral tests; these do not prove GTM publication or GA4 reception. */
const assert = require('node:assert/strict');
const { test } = require('node:test');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync(require('node:path').join(__dirname, '../overlay/app/public/brand-assets/toybaco-free-registration-measurement.js'), 'utf8');

function boot(options = {}) {
  const scripts = [], timers = [], cookies = [], elements = [], handlers = new Map();
  let reloads = 0, submissions = 0;
  const marker = { dataset: { error: options.error || '', requestAccepted: options.accepted ? 'true' : 'false' } };
  const form = { addEventListener(type, handler) { handlers.set(type, handler); } };
  const createElement = type => {
    const el = { type, style: {}, children: [], listeners: {}, setAttribute() {}, appendChild(x) { this.children.push(x); },
      addEventListener(type, handler) { this.listeners[type] = handler; } };
    elements.push(el); return el;
  };
  const document = { referrer: options.referrer || 'https://staging.toybaco.jp/signup/?email=PRIVATE#SECRET',
    getElementById(id) { return id === 'free-registration-measurement' ? marker : options.noForm ? null : form; },
    createElement, head: { appendChild(x) { scripts.push(x); } }, body: { appendChild() {} } };
  Object.defineProperty(document, 'cookie', { get() { return 'tb_free_staging_ga=test; session=PRIVATE; tb_site_ga=test'; }, set(value) { cookies.push(value); } });
  const location = { origin: options.origin || 'https://app.staging.toybaco.jp', pathname: options.path || '/toybaco/free/signup',
    search: '?email=PRIVATE&confirmation_token=SECRET', hash: '#SECRET', reload() { reloads++; } };
  const storage = new Map([['toybaco_free_registration_analytics_staging_v1', options.choice || 'unset']]);
  const sessionStorage = { getItem(key) { if (options.storageBlocked) throw Error('blocked'); return storage.get(key); },
    setItem(key, value) { if (options.storageBlocked || options.writeBlocked) throw Error('blocked'); storage.set(key, value); } };
  const window = {};
  const sandbox = { window, document, location, sessionStorage, URL, HTMLFormElement: { prototype: { submit() { submissions++; } } },
    setTimeout(fn) { timers.push(fn); } };
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return { window, scripts, cookies, handlers, timers, elements, storage, events: () => Array.from(window.dataLayer || []).filter(x => x.event && x.event !== 'gtm.js'),
    runAgain() { vm.runInContext(source, sandbox); }, get reloads() { return reloads; }, get submissions() { return submissions; } };
}
function fieldEvent(name, isTrusted = true) {
  const target = { name };
  Object.defineProperty(target, 'value', { get() { throw Error('input values must never be read'); } });
  return { target, isTrusted };
}

test('exact staging origin and two public routes only; no production, auth, dashboard or checkout tags', () => {
  for (const options of [{ origin: 'https://app.toybaco.jp' }, { origin: 'http://app.staging.toybaco.jp' },
    { origin: 'https://app.staging.toybaco.jp.evil.example' }, { path: '/app' }, { path: '/auth/confirmation' }, { path: '/toybaco/checkout' }]) {
    const b = boot({ choice: 'accepted', ...options });
    assert.equal(b.scripts.length, 0); assert.equal(b.window.dataLayer, undefined);
  }
});
test('no explicit analytics permission means no Google script or measurement events, even after input/error', () => {
  for (const options of [{}, { choice: 'denied' }, { choice: 'accepted', storageBlocked: true }]) {
    const b = boot(options);
    b.handlers.get('input')(fieldEvent('email'));
    b.handlers.get('invalid')(fieldEvent('password'));
    assert.equal(b.scripts.length, 0); assert.equal(b.events().length, 0);
    assert.equal(b.window.dataLayer[0][2].analytics_storage, 'denied');
  }
});
test('one GTM instance, sanitized locations, default consent before load, ads denied and QA context', () => {
  const b = boot({ choice: 'accepted' }); b.runAgain();
  assert.equal(b.scripts.length, 1);
  assert.equal(b.scripts[0].src, 'https://www.googletagmanager.com/gtm.js?id=GTM-T2ZGF6ZP');
  const d = b.window.dataLayer;
  assert.equal(d[0][0], 'consent'); assert.equal(d[0][1], 'default');
  for (const k of ['ad_storage', 'ad_user_data', 'ad_personalization']) assert.equal(d[0][2][k], 'denied');
  assert.equal(d[1].page_location, 'https://app.staging.toybaco.jp/toybaco/free/signup');
  assert.equal(d[1].page_referrer, 'https://staging.toybaco.jp/');
  assert.equal(d[1].measurement_test_mode, 'staging');
  assert(!JSON.stringify(d).includes('PRIVATE')); assert(!JSON.stringify(d).includes('SECRET'));
});
test('input start and field errors use fixed codes, deduplicate and never read any value', () => {
  const b = boot({ choice: 'accepted' });
  b.handlers.get('input')(fieldEvent('email', false));
  b.handlers.get('input')(fieldEvent('authenticity_token'));
  assert.equal(b.events().length, 0);
  b.handlers.get('input')(fieldEvent('email')); b.handlers.get('change')(fieldEvent('password'));
  b.handlers.get('invalid')(fieldEvent('password')); b.handlers.get('invalid')(fieldEvent('password'));
  b.handlers.get('invalid')(fieldEvent('email'));
  assert.deepEqual(b.events().map(x => x.event), ['free_signup_start', 'form_error', 'form_error']);
  assert.deepEqual(b.events().filter(x => x.event === 'form_error').map(x => x.error_field), ['password', 'email']);
  b.handlers.get('input')(fieldEvent('password')); b.handlers.get('invalid')(fieldEvent('password'));
  assert.equal(b.events().length, 4);
});
test('submit is attempt only, callback and deadline cannot submit twice; refusal leaves submit untouched', () => {
  const b = boot({ choice: 'accepted' }); let prevented = false;
  b.handlers.get('submit')({ isTrusted: true, defaultPrevented: false, preventDefault() { prevented = true; } });
  assert(prevented); assert.deepEqual(b.events().map(x => x.event), ['free_signup_submit']);
  b.events()[0].eventCallback(); b.timers[0](); assert.equal(b.submissions, 1);
  const blocked = boot(); blocked.handlers.get('submit')({ isTrusted: true, preventDefault() { assert.fail('must not block'); } });
  assert.equal(blocked.timers.length, 0);
});
test('server success receipt only on verify page; direct visit, unknown receipt/error and signup never convert', () => {
  const b = boot({ choice: 'accepted', path: '/toybaco/free/verify-email', accepted: true, noForm: true });
  b.runAgain(); assert.deepEqual(b.events().map(x => x.event), ['free_signup_request_accepted']);
  for (const options of [{ path: '/toybaco/free/verify-email' }, { accepted: true }, { choice: 'denied', accepted: true, path: '/toybaco/free/verify-email' }])
    assert.equal(boot({ choice: 'accepted', ...options }).events().length, 0);
  assert.equal(boot({ choice: 'accepted', error: 'PRIVATE_SERVER_MESSAGE' }).events().length, 0);
  assert.deepEqual(boot({ choice: 'accepted', error: 'captcha' }).events().map(x => [x.event, x.error_type, x.error_field]), [['form_error', 'captcha', 'form']]);
});
test('revoke immediately stops event sending, removes only app analytics cookie and does not require storage', () => {
  const b = boot({ choice: 'accepted', writeBlocked: true });
  assert.equal(b.window.toybacoFreeRegistrationMeasurement.setChoice('denied'), false);
  assert.equal(b.window.toybacoFreeRegistrationMeasurement.active, false);
  b.handlers.get('input')(fieldEvent('email')); assert.equal(b.events().length, 0);
  assert.equal(b.window['ga-disable-G-N18VE3LMRS'], true);
  assert.equal(b.cookies.length, 1); assert(b.cookies[0].startsWith('tb_free_staging_ga='));
  assert.equal(b.reloads, 0);
});
