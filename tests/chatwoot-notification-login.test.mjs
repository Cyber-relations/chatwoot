import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const overlay = path.join(root, 'overlay/app/app/javascript');
const authSource = readFileSync(path.join(overlay, 'v3/helpers/AuthHelper.js'), 'utf8');
const guardSource = readFileSync(path.join(overlay, 'dashboard/routes/index.js'), 'utf8');
const normalAuthSource = readFileSync(path.join(overlay, 'v3/api/auth.js'), 'utf8');
const loginSource = readFileSync(path.join(overlay, 'v3/views/login/Index.vue'), 'utf8');
const mfaSource = readFileSync(path.join(overlay, 'dashboard/components/auth/MfaVerification.vue'), 'utf8');
const user = {
  account_id: 5,
  accounts: [{ id: 5, role: 'administrator', status: 'active' }, { id: 4, role: 'agent', status: 'active' }],
};
const frontendURL = value => `/app/${value}`;
const moduleBody = source => source
  .replace(/^import [\s\S]*? from ['"][^'"]+['"];\n/gm, '')
  .replace(/^export default [^;]+;\n/gm, '')
  .replaceAll('export const ', 'const ');

function authModule(search = '', pathname = '/app/login') {
  const context = vm.createContext({
    URLSearchParams, window: { location: { search, pathname } },
    Cookies: { get: () => null }, DEFAULT_REDIRECT_URL: '/app/', frontendURL,
  });
  vm.runInContext(`${moduleBody(authSource)}\nthis.auth = {
    getLoginRedirectURL,
    getNotificationConversationURL: typeof getNotificationConversationURL === 'undefined' ? undefined : getNotificationConversationURL,
    getNotificationLoginURL: typeof getNotificationLoginURL === 'undefined' ? undefined : getNotificationLoginURL
  };`, context);
  return context.auth;
}

async function runGuard(to, getters = { isLoggedIn: false }) {
  const assigned = [];
  const next = [];
  const context = vm.createContext({
    window: { location: { assign: value => assigned.push(value) } },
    store: { getters }, frontendURL,
    getNotificationLoginURL: authModule().getNotificationLoginURL,
    createRouter: () => ({}), createWebHistory: () => ({}), dashboard: { routes: [] },
    validateLoggedInRoutes: () => null, isOnOnboardingView: () => false,
  });
  vm.runInContext(`${moduleBody(guardSource)}\nthis.guard = validateAuthenticateRoutePermission;`, context);
  await context.guard(to, value => next.push(value));
  return { assigned, next };
}

test('notification link survives the real unauthenticated guard and normal login response', async () => {
  const result = await runGuard({ path: '/app/accounts/4/conversations/1' });
  assert.deepEqual(result.assigned, ['/app/login?toybaco_return_account_id=4&toybaco_return_conversation_id=1']);
  assert.deepEqual(result.next, []);
  const loginURL = new URL(result.assigned[0], 'https://app.example.test');
  assert.equal(authModule(loginURL.search).getLoginRedirectURL({ user }), '/app/accounts/4/conversations/1');
  assert.equal(user.account_id, 5);
  assert.equal(user.accounts[1].role, 'agent');
});

function mfaLogin(search = notification, props = {}) {
  const assigned = [];
  const window = {};
  Object.defineProperty(window, 'location', { set: value => assigned.push(value) });
  const imports = Object.fromEntries([
    'FormInput', 'GoogleOAuthButton', 'Spinner', 'NextButton', 'SimpleDivider',
    'MfaVerification', 'SessionLimitOverlay', 'Icon',
  ].map(name => [name, {}]));
  const script = loginSource.match(/<script>([\s\S]+?)<\/script>/)[1]
    .replace(/^import [\s\S]*? from ['"][^'"]+['"];\n/gm, '')
    .replace('export default ', 'this.component = ');
  const context = vm.createContext({
    ...imports, window, mapGetters: () => ({}),
    getNotificationConversationURL: authModule(search).getNotificationConversationURL,
  });
  vm.runInContext(script, context);
  const state = { handleImpersonation: () => {}, mfaRequired: true, mfaToken: 'fixture', credentials: { password: 'fixture' }, ...props };
  return {
    assigned, state,
    verified: payload => context.component.methods.handleMfaVerified.call(state, payload),
    cancel: () => context.component.methods.handleMfaCancel.call(state),
  };
}

async function verifyMfa(parent, { freshUser = user, fail = false, method = 'otp', digits = '123456' } = {}) {
  const posts = [];
  const credentials = [];
  const events = [];
  const context = vm.createContext({
    ref: value => ({ value }), computed: fn => ({ get value() { return fn(); } }),
    nextTick: () => Promise.resolve(),
    defineProps: () => ({ mfaToken: 'fixture-token' }),
    defineEmits: () => (name, payload) => { events.push(name); if (name === 'verified') parent.verified(payload); },
    useI18n: () => ({ t: value => value }), useAccount: () => ({ isOnChatwootCloud: { value: false } }),
    axios: { post: async (url, payload) => {
      posts.push({ url, payload });
      if (fail) throw new Error('fixture rejection');
      return { data: { data: freshUser } };
    } },
    setAuthCredentials: response => credentials.push(response),
  });
  const script = mfaSource.match(/<script setup>([\s\S]+?)<\/script>/)[1];
  vm.runInContext(`${moduleBody(script)}\nthis.state = {
    verificationMethod, otpDigits, backupCode, isVerifying, errorMessage, handleVerification
  };`, context);
  context.state.verificationMethod.value = method;
  context.state.otpDigits.value = digits.split('');
  context.state.backupCode.value = 'abcdefgh';
  await context.state.handleVerification();
  return { posts, credentials, events, state: context.state };
}

for (const method of ['otp', 'backup']) {
  test(`MFA ${method} success passes fresh response membership to the same safe return helper`, async () => {
    const parent = mfaLogin();
    const result = await verifyMfa(parent, { method });
    assert.equal(result.posts.length, 1);
    assert.equal(result.posts[0].url, '/auth/sign_in');
    assert.equal(result.posts[0].payload.mfa_token, 'fixture-token');
    assert.equal(result.posts[0].payload[method === 'otp' ? 'otp_code' : 'backup_code'], method === 'otp' ? '123456' : 'abcdefgh');
    assert.equal(result.credentials.length, 1);
    assert.deepEqual(result.events, ['verified']);
    assert.deepEqual(parent.assigned, ['/app/accounts/4/conversations/1']);
  });
}

test('MFA cannot attach the notification conversation to a different fresh membership', async () => {
  const parent = mfaLogin();
  await verifyMfa(parent, { freshUser: { account_id: 5, accounts: [{ id: 5 }] } });
  assert.deepEqual(parent.assigned, ['/app']);
});

test('MFA success without a user payload retains the previous app fallback', () => {
  const parent = mfaLogin();
  parent.verified({});
  assert.deepEqual(parent.assigned, ['/app']);
});

test('MFA failure and incomplete OTP never emit verified or navigate', async () => {
  const parent = mfaLogin();
  const failed = await verifyMfa(parent, { fail: true });
  assert.equal(failed.posts.length, 1);
  assert.equal(failed.credentials.length, 0);
  assert.deepEqual(failed.events, []);
  assert.equal(failed.state.errorMessage.value, 'MFA_VERIFICATION.VERIFICATION_FAILED');
  assert.equal(failed.state.isVerifying.value, false);
  assert.equal(failed.state.otpDigits.value.join(''), '');
  const incomplete = await verifyMfa(parent, { digits: '12345' });
  assert.equal(incomplete.posts.length, 0);
  assert.deepEqual(parent.assigned, []);
});

test('MFA cancellation preserves its existing reset and does not navigate', () => {
  const parent = mfaLogin();
  parent.cancel();
  assert.equal(parent.state.mfaRequired, false);
  assert.equal(parent.state.mfaToken, null);
  assert.equal(parent.state.credentials.password, '');
  assert.deepEqual(parent.assigned, []);
});

test('MFA without a notification and with existing SSO properties preserves the previous app fallback', () => {
  const normal = mfaLogin('');
  normal.verified({ data: user });
  assert.deepEqual(normal.assigned, ['/app']);
  for (const props of [{ ssoAuthToken: 'fixture' }, { ssoAccountId: '5' }, { ssoConversationId: '12' }]) {
    const sso = mfaLogin(notification, props);
    sso.verified({ data: user });
    assert.deepEqual(sso.assigned, ['/app']);
  }
});

for (const invalid of [
  'https://evil.example/app/accounts/4/conversations/1',
  '//evil.example/app/accounts/4/conversations/1',
  '/app/accounts/4/conversations/1/extra',
  '/app/accounts/04/conversations/1',
  '/app/accounts/0/conversations/1',
  '/app/accounts/4/conversations/-1',
  '/app/accounts/4/conversations/%31',
  '/app/accounts/4/conversations/1%2f2',
  '/app/accounts/4/conversations/1\n',
  '/app/accounts/9007199254740993/conversations/1',
  '/app/accounts/4/conversations/9007199254740993',
  '/app/accounts/4/dashboard',
  undefined,
]) {
  test(`guard drops noncanonical or unrelated destination: ${String(invalid)}`, async () => {
    assert.deepEqual((await runGuard({ path: invalid })).assigned, ['/app/login']);
  });
}

for (const search of [
  '?toybaco_return_account_id=4',
  '?toybaco_return_conversation_id=1',
  '?toybaco_return_account_id=4&toybaco_return_account_id=4&toybaco_return_conversation_id=1',
  '?toybaco_return_account_id=4&toybaco_return_conversation_id=1&toybaco_return_conversation_id=2',
  '?toybaco_return_account_id=https%3A%2F%2Fevil.example&toybaco_return_conversation_id=1',
  '?toybaco_return_account_id=4&toybaco_return_conversation_id=1%2F2',
  '?toybaco_return_account_id=04&toybaco_return_conversation_id=1',
  '?toybaco_return_account_id=0&toybaco_return_conversation_id=1',
  '?toybaco_return_account_id=4&toybaco_return_conversation_id=-1',
  '?toybaco_return_account_id=9007199254740993&toybaco_return_conversation_id=1',
  '?toybaco_return_account_id=4&toybaco_return_conversation_id=9007199254740993',
  '?toybaco_return_account_id=&toybaco_return_conversation_id=1',
  '?toybaco_return_account_id=4%0A&toybaco_return_conversation_id=1',
  '?toybaco_return_account_id=4&toybaco_return_conversation_id=1%0A',
  '?return_to=https%3A%2F%2Fevil.example',
]) {
  test(`login rejects incomplete, duplicate or noncanonical notification IDs: ${search}`, () => {
    assert.equal(authModule(search).getLoginRedirectURL({ user }), '/app/accounts/5/dashboard');
  });
}

const notification = '?toybaco_return_account_id=4&toybaco_return_conversation_id=1';
test('fresh membership removal drops the conversation instead of attaching it to another account', () => {
  assert.equal(authModule(notification).getLoginRedirectURL({
    user: { account_id: 5, accounts: [{ id: 5 }] },
  }), '/app/accounts/5/dashboard');
  assert.equal(authModule(notification).getLoginRedirectURL({ user: {} }), '/app/');
});

test('fresh membership changes and conversation IDs are independent of previous active account', () => {
  assert.equal(authModule(notification).getLoginRedirectURL({
    user: { account_id: 9, accounts: [{ id: 9 }, { id: 4 }] },
  }), '/app/accounts/4/conversations/1');
  assert.equal(authModule(notification.replace('conversation_id=1', 'conversation_id=12'))
    .getLoginRedirectURL({ user }), '/app/accounts/4/conversations/12');
});

test('only the normal login path consumes the notification query', () => {
  assert.equal(authModule(notification, '/app/auth/password/edit').getLoginRedirectURL({ user }), '/app/accounts/5/dashboard');
});

test('ordinary login and existing SSO targets keep their prior behavior', () => {
  assert.equal(authModule().getLoginRedirectURL({ user }), '/app/accounts/5/dashboard');
  assert.equal(authModule(notification).getLoginRedirectURL({ user, ssoAccountId: '5' }), '/app/accounts/5/dashboard');
  assert.equal(authModule(notification).getLoginRedirectURL({ user, ssoAccountId: '5', ssoConversationId: '12' }), '/app/accounts/5/conversations/12');
  assert.equal(authModule(`${notification}&sso_auth_token=fixture`).getLoginRedirectURL({ user }), '/app/accounts/5/dashboard');
  assert.equal(authModule(`${notification}&sso_account_id=5`).getLoginRedirectURL({ user }), '/app/accounts/5/dashboard');
  assert.equal(authModule(`${notification}&sso_conversation_id=12`).getLoginRedirectURL({ user }), '/app/accounts/5/dashboard');
});

test('authenticated route still reaches the existing membership and permission validation', async () => {
  const result = await runGuard({ path: '/app/accounts/4/conversations/1', name: 'inbox_conversation', params: { accountId: 4 } }, {
    isLoggedIn: true, getCurrentUser: user,
  });
  assert.deepEqual(result.assigned, []);
  assert.deepEqual(result.next, [undefined]);
});

test('normal login uses the successful response membership, without using stored profile data', async () => {
  const assigned = [];
  const location = { pathname: '/app/login', search: notification };
  const auth = authModule(notification);
  const window = {};
  Object.defineProperty(window, 'location', { get: () => location, set: value => assigned.push(value) });
  const posted = [];
  const context = vm.createContext({
    window,
    wootAPI: { post: async (...args) => { posted.push(args); return { status: 200, data: { data: { account_id: 5, accounts: [{ id: 5 }] } } }; } },
    getLoginRedirectURL: auth.getLoginRedirectURL, getCredentialsFromEmail: () => ({}),
    setAuthCredentials: () => {}, clearLocalStorageOnLogout: () => {}, parseAPIErrorResponse: error => error,
  });
  vm.runInContext(`${moduleBody(normalAuthSource)}\nthis.login = login;`, context);
  await context.login({ email: 'fixture@example.invalid', password: 'local-fixture' });
  assert.equal(posted.length, 1);
  assert.equal(posted[0][0], 'auth/sign_in');
  assert.deepEqual(assigned, ['/app/accounts/5/dashboard']);
});
