import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import vm from 'node:vm';

const root = resolve(process.env.TOYBACO_CONTROL_ROOT ?? dirname(fileURLToPath(import.meta.url)), process.env.TOYBACO_CONTROL_ROOT ? '.' : '..');
const profile = 'overlay/app/app/javascript/dashboard/routes/dashboard/settings/profile';
const read = path => readFileSync(resolve(root, path), 'utf8');

// Run the component methods with the same Options API boundary as the existing
// password-policy UI tests. This does not claim to mount or render Vue.
function component(path) {
  const source = read(path).match(/<script>\s*([\s\S]*?)<\/script>/)[1];
  const script = source.replace(/^import [\s\S]*? from ['"][^'"]+['"];\n/gm, '')
    .replace('export default {', 'this.component = {');
  const globals = new Proxy({
    mapGetters: () => ({}), useAlert: () => {},
    clearCookiesOnLogout: () => {}, minLength: () => () => true,
  }, { has: () => true, get: (object, key) => object[key] ?? {} });
  const context = vm.createContext(globals);
  vm.runInContext(script, context);
  return context.component;
}

test('email changes emit a current password and clear it from the form', async () => {
  const basic = component(`${profile}/UserBasicDetails.vue`);
  let emitted;
  const state = {
    userName: 'Fixture', userDisplayName: '', userEmail: 'new@example.invalid', email: 'old@example.invalid',
    currentPassword: 'fixture-password', v$: { $touch() {}, $invalid: false },
    $emit: (_event, payload) => { emitted = payload; },
  };
  state.emailChanged = basic.computed.emailChanged.call(state);
  await basic.methods.updateUser.call(state);
  assert.equal(emitted.currentPassword, 'fixture-password');
  assert.equal(state.currentPassword, '');
});

test('email changes without a password do not submit, while ordinary edits do', async () => {
  const basic = component(`${profile}/UserBasicDetails.vue`);
  const submissions = [];
  const state = {
    userName: 'Fixture', userEmail: 'new@example.invalid', currentPassword: '', emailChanged: true,
    v$: { $touch() {}, $invalid: false }, $emit: (_event, payload) => submissions.push(payload),
  };
  await basic.methods.updateUser.call(state);
  assert.equal(submissions.length, 0);
  state.emailChanged = false;
  await basic.methods.updateUser.call(state);
  assert.equal(submissions.length, 1);
  assert.equal(submissions[0].currentPassword, undefined);
});

test('the parent sends current_password and preserves the original email after a rejected save', async () => {
  const index = component(`${profile}/Index.vue`);
  let sent;
  const state = {
    currentUser: { email: 'old@example.invalid' }, email: 'old@example.invalid', name: 'Fixture', displayName: '', avatarFile: '',
    $t: key => key, dispatchUpdate: async payload => { sent = payload; return false; },
  };
  await index.methods.updateProfile.call(state, { email: 'new@example.invalid', currentPassword: 'fixture-password' });
  assert.equal(sent.current_password, 'fixture-password');
  assert.equal(sent.email, 'new@example.invalid');
  assert.equal(state.email, 'old@example.invalid');
});

test('the API sends current_password in the actual multipart profile request', () => {
  const source = read('overlay/app/app/javascript/dashboard/api/auth.js');
  const method = source.match(/  profileUpdate\(\{ displayName, avatar, \.\.\.profileAttributes \}\) \{([\s\S]*?)\n  \},/)[1];
  const sent = [];
  const context = vm.createContext({
    FormData, axios: { put: (url, data) => sent.push({ url, data }) }, endPoints: () => ({ url: '/api/v1/profile' }),
    attributes: { email: 'new@example.invalid', current_password: 'fixture-password' },
  });
  vm.runInContext(`function update({ displayName, avatar, ...profileAttributes }) {${method}}; update(attributes);`, context);
  assert.equal(sent[0].data.get('profile[current_password]'), 'fixture-password');
  assert.equal(sent[0].data.get('profile[email]'), 'new@example.invalid');
});
