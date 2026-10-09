// パスワード設定(招待・再設定リンク)と自分のパスワード変更の画面契約。
// 要件の規則は shared/helpers/toybacoPasswordRules.js が唯一の定義(gem の devise-secure_password と同じ)。
// その規則、チェックリスト(shared/components/ToybacoPasswordRequirements.vue)、生成済み v3/api/auth.js の 422 写像
// (toybacoPasswordError)、生成済み Edit.vue / ChangePassword.vue の検証と文言(実 helper を注入して評価)、
// signup.json(ja)と secure_password.ja.yml の文言、gate への配線を確かめる。gate は control snapshot のこのファイルを
// 実行するので、root は TOYBACO_CONTROL_ROOT(無ければこのファイルの親)とし、snapshot にあるファイルだけを読む。
//
//   node --test tests/chatwoot-password-policy-ui.test.mjs

import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const controlRoot = process.env.TOYBACO_CONTROL_ROOT;
assert.notEqual(controlRoot, '', 'TOYBACO_CONTROL_ROOT must not be empty');
const root = resolve(controlRoot ?? join(dirname(fileURLToPath(import.meta.url)), '..'));
const read = path => readFileSync(join(root, path), 'utf8');
const javascript = 'overlay/app/app/javascript';

const rulesSource = read(`${javascript}/shared/helpers/toybacoPasswordRules.js`);
const requirementsSource = read(`${javascript}/shared/components/ToybacoPasswordRequirements.vue`);
const authSource = read(`${javascript}/v3/api/auth.js`);
const editSource = read(`${javascript}/v3/views/auth/password/Edit.vue`);
const changeSource = read(`${javascript}/dashboard/routes/dashboard/settings/profile/ChangePassword.vue`);
const signupSource = read(`${javascript}/v3/views/auth/signup/components/Signup/Form.vue`);
const signup = JSON.parse(read(`${javascript}/dashboard/i18n/locale/ja/signup.json`));
const securePasswordJa = read('overlay/app/config/locales/secure_password.ja.yml');

const rules = await import(`data:text/javascript;base64,${Buffer.from(rulesSource).toString('base64')}`);
// 生成物の vm 評価には、モックではなく実 helper をそのまま渡す。
const helpers = {
  isToybacoPasswordValid: rules.isToybacoPasswordValid,
  toybacoPasswordRequirements: rules.toybacoPasswordRequirements,
  isToybacoJapaneseMessage: rules.isToybacoJapaneseMessage,
  toybacoPasswordServerMessage: rules.toybacoPasswordServerMessage,
};

// tests/chatwoot-notification-login.test.mjs と同じ方式で、import を外して vm で評価する。
const moduleBody = source => source
  .replace(/^import [\s\S]*? from ['"][^'"]+['"];\n/gm, '')
  .replace(/^export default [^;]+;\n/gm, '')
  .replaceAll('export const ', 'const ');
const scriptOf = sfc => {
  const match = sfc.match(/<script(?: setup)?>\n([\s\S]*?)\n<\/script>/);
  assert.ok(match, 'SFC must have one <script> block');
  return match[1];
};
// export default を先に外す(moduleBody の export default 除去は最初の ; まで食うため)。
const componentBody = sfc => moduleBody(scriptOf(sfc).replace(/^export default \{/m, 'this.component = {'));
const component = (sfc, globals) => {
  const context = vm.createContext({ ...globals });
  vm.runInContext(componentBody(sfc), context);
  return context.component;
};
// Options API の methods / computed を this に束ねた最小の instance。
const instance = (definition, state) => {
  const self = { ...(definition.data ? definition.data() : {}), $t: key => `t:${key}`, ...state };
  for (const [name, method] of Object.entries(definition.methods || {})) self[name] = method.bind(self);
  for (const [name, getter] of Object.entries(definition.computed || {})) {
    Object.defineProperty(self, name, { get: getter.bind(self), configurable: true });
  }
  return self;
};
const flush = () => new Promise(done => setImmediate(done));
const ENGLISH_WORD = /[A-Za-z]{3,}/;
const LINK_EXPIRED =
  'このリンクは無効か、すでに使用済みです。ログイン画面の「パスワードを忘れた場合」から新しいメールを受け取ってください。';
const GENERIC = '操作を完了できませんでした。もう一度お試しください。';
const ONLY_HALF_WIDTH = '半角の英数字と記号だけを使ってください';
const TOO_LONG = '128 文字以内にしてください';
// gem(Support::String::CharacterCounter)の記号集合。先頭の空白も記号。
const GEM_SPECIAL = ' !@#$%^&*()_+-=[]{}|"/\\.,`<>:;?~\'';
const SERVER_JA = `パスワード には記号を1文字以上含めてください  (${GEM_SPECIAL})`;
const SERVER_JA_DUPLICATED = `${SERVER_JA}, パスワード（確認） には記号を1文字以上含めてください  (${GEM_SPECIAL})`;
// 本番 2026-10-08 の形(属性名だけ日本語の英語混在文)。
const SERVER_MIXED = `パスワード must contain at least 1 special character  (${GEM_SPECIAL})`;
// gem の dict_for_type(keys.first..keys.last)つきの全文。英字 3 連続が無いことを実文字列で固定する。
const SERVER_JA_UPPERCASE = 'パスワード には英大文字を1文字以上含めてください  (A..Z)';
const SERVER_JA_LOWERCASE = 'パスワード には英小文字を1文字以上含めてください  (a..z)';
const SERVER_JA_NUMBER = 'パスワード には数字を1文字以上含めてください  (0..9)';
const MAX_PASSWORD = `Ab1!${'a'.repeat(124)}`;
const OVER_MAX_PASSWORD = `Ab1!${'a'.repeat(125)}`;
const unmetIds = password => rules.toybacoPasswordRequirements(password).filter(item => !item.met).map(item => item.id);

test('要件ルール: gem と同じ規則(6〜128 文字、英大小・数字・空白を含む記号、半角の英数字と記号のみ)', () => {
  const ids = ['length', 'uppercase', 'lowercase', 'number', 'special', 'allowed'];
  const empty = rules.toybacoPasswordRequirements('');
  assert.deepEqual(empty.map(item => item.id), ids);
  // 空入力では allowed も未達(1 行だけ緑に見えない)。
  assert.deepEqual(empty.map(item => item.met), [false, false, false, false, false, false]);
  for (const value of [undefined, null, 12345678]) {
    assert.deepEqual(rules.toybacoPasswordRequirements(value).map(item => item.met), [false, false, false, false, false, false]);
    assert.equal(rules.isToybacoPasswordValid(value), false);
  }
  assert.deepEqual(empty.map(item => item.key), [
    'REGISTER.PASSWORD.REQUIREMENTS_LENGTH', 'REGISTER.PASSWORD.REQUIREMENTS_UPPERCASE',
    'REGISTER.PASSWORD.REQUIREMENTS_LOWERCASE', 'REGISTER.PASSWORD.REQUIREMENTS_NUMBER',
    'REGISTER.PASSWORD.REQUIREMENTS_SPECIAL', undefined,
  ]);
  assert.equal(empty.at(-1).label, '半角の英数字と記号のみ');
  assert.equal(rules.isToybacoPasswordValid(''), false);
  assert.equal(rules.isToybacoPasswordValid('Abcdef1!'), true);
  assert.deepEqual(unmetIds('Abcdef12'), ['special']);
  assert.equal(rules.isToybacoPasswordValid('Abcd 123'), true, 'a space is a special character for the gem');
  assert.deepEqual(unmetIds('Ab1!'), ['length']);
  assert.equal(MAX_PASSWORD.length, 128);
  assert.equal(rules.isToybacoPasswordValid(MAX_PASSWORD), true);
  assert.equal(OVER_MAX_PASSWORD.length, 129);
  assert.deepEqual(unmetIds(OVER_MAX_PASSWORD), ['length']);
  for (const extra of ['あ', 'Ａ', '😀', '\t', '§']) {
    assert.deepEqual(unmetIds(`Abcdef1!${extra}`), ['allowed'], `not allowed: ${JSON.stringify(extra)}`);
    assert.equal(rules.TOYBACO_PASSWORD_ALLOWED_PATTERN.test(extra), false);
  }
  assert.equal(rules.TOYBACO_PASSWORD_MIN_LENGTH, 6);
  assert.equal(rules.TOYBACO_PASSWORD_MAX_LENGTH, 128);
  assert.equal(rules.TOYBACO_PASSWORD_SPECIAL_PATTERN.source, "[ !@#$%^&*()_+\\-=[\\]{}|'\"/\\\\.,`<>:;?~]");
  for (const character of GEM_SPECIAL) {
    assert.equal(rules.TOYBACO_PASSWORD_SPECIAL_PATTERN.test(character), true, `special: ${JSON.stringify(character)}`);
  }
  for (const character of ['あ', '§', 'A', 'a', '0', '\t', 'Ａ']) {
    assert.equal(rules.TOYBACO_PASSWORD_SPECIAL_PATTERN.test(character), false, `not special: ${JSON.stringify(character)}`);
  }
  const allAllowed = `ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789${GEM_SPECIAL}`;
  assert.equal(rules.TOYBACO_PASSWORD_ALLOWED_PATTERN.test(allAllowed), true);
  assert.doesNotMatch(rulesSource, /^import /m, 'the rules helper stays dependency-free');
});

test('日本語判定と重複文の除去: 英語混在文を通さず、確認用の重複文を落とす', () => {
  for (const text of [
    SERVER_JA, SERVER_JA_DUPLICATED, SERVER_JA_UPPERCASE, SERVER_JA_LOWERCASE, SERVER_JA_NUMBER,
    'パスワード に使用できない文字が1文字含まれています (あ)', 'パスワード は6文字以上にしてください',
    'パスワード（確認） がパスワードと一致しません',
  ]) assert.equal(rules.isToybacoJapaneseMessage(text), true, text);
  for (const text of [SERVER_MIXED, 'Invalid token', 'Password is too short', '', null, 42, ['パスワード']]) {
    assert.equal(rules.isToybacoJapaneseMessage(text), false, String(text));
  }
  assert.equal(rules.toybacoPasswordServerMessage(SERVER_JA_DUPLICATED), SERVER_JA);
  assert.equal(rules.toybacoPasswordServerMessage(SERVER_JA), SERVER_JA);
  assert.equal(rules.toybacoPasswordServerMessage('パスワード（確認） がパスワードと一致しません'),
    'パスワード（確認） がパスワードと一致しません');
});

function authModule(put) {
  const credentials = [];
  const context = vm.createContext({
    ...helpers,
    wootAPI: { put },
    setAuthCredentials: response => credentials.push(response),
  });
  vm.runInContext(`${moduleBody(authSource)}\nthis.setNewPassword = setNewPassword;`, context);
  return { setNewPassword: context.setNewPassword, credentials };
}
const rejectWith = error => async () => { throw error; };
const response = (status, data) => ({ response: { status, data } });

test('auth.js: module の top-level は定義だけで、判定は toybacoPasswordRules.js を使う', () => {
  const context = vm.createContext({});
  vm.runInContext(`${moduleBody(authSource)}\nthis.setNewPassword = setNewPassword;`, context);
  assert.equal(typeof context.setNewPassword, 'function');
  assert.match(authSource,
    /^import \{ isToybacoJapaneseMessage, toybacoPasswordServerMessage \} from 'shared\/helpers\/toybacoPasswordRules';$/m);
  assert.equal(authSource.split('const toybacoPasswordError = error => {').length - 1, 1);
  assert.equal(authSource.split('throw toybacoPasswordError(error);').length - 1, 1);
  assert.equal(authSource.split('isToybacoJapaneseMessage(message)').length - 1, 1);
  assert.equal(authSource.split('toybacoPasswordServerMessage(message)').length - 1, 1);
});

test('auth.js: setNewPassword は 422 の理由を日本語だけで返す', async () => {
  const cases = [
    [response(422, { message: SERVER_JA_DUPLICATED, attributes: ['password', 'password_confirmation'] }), SERVER_JA, 'invalid_password'],
    [response(422, { message: SERVER_JA }), SERVER_JA, 'invalid_password'],
    [response(422, { message: 'Invalid token', redirect_url: '/' }), LINK_EXPIRED, 'invalid_token'],
    [response(422, { message: SERVER_MIXED, attributes: ['password'] }), GENERIC, undefined],
    [response(422, { message: 'Password must contain at least 1 special character' }), GENERIC, undefined],
    [response(422, { message: ['配列は文字列ではない'] }), GENERIC, undefined],
    [response(500, '<!DOCTYPE html>'), GENERIC, undefined],
    [response(400, { message: 'パスワード には記号を1文字以上含めてください' }), GENERIC, undefined],
    [new Error('Network Error'), GENERIC, undefined],
  ];
  for (const [failure, message, errorCode] of cases) {
    const { setNewPassword, credentials } = authModule(rejectWith(failure));
    await assert.rejects(setNewPassword({ resetPasswordToken: 'raw', password: 'Abcdef1!', confirmPassword: 'Abcdef1!' }), error => {
      assert.equal(error.message, message);
      assert.equal(error.errorCode, errorCode);
      assert.doesNotMatch(error.message, ENGLISH_WORD, 'thrown text must not carry English words');
      return true;
    });
    assert.equal(credentials.length, 0);
  }
  const calls = [];
  const ok = { status: 200, data: { data: { id: 1 } } };
  const { setNewPassword, credentials } = authModule(async (...args) => { calls.push(args); return ok; });
  await setNewPassword({ resetPasswordToken: 'raw', password: 'Abcdef1!', confirmPassword: 'Abcdef1!' });
  assert.deepEqual(JSON.parse(JSON.stringify(calls)), [['auth/password', {
    reset_password_token: 'raw', password_confirmation: 'Abcdef1!', password: 'Abcdef1!',
  }]]);
  assert.deepEqual(credentials, [ok]);
  for (const text of [LINK_EXPIRED, GENERIC]) assert.doesNotMatch(text, ENGLISH_WORD);
  assert.doesNotMatch(authSource, /有効期限/, 'auth/password の update は期限を見ないので、期限切れとは書かない');
});

const ToybacoPasswordRequirements = { name: 'ToybacoPasswordRequirements' };
const vueGlobals = alerts => ({
  ...helpers,
  useVuelidate: () => ({}), required: { name: 'required' }, minLength: length => ({ name: 'minLength', length }),
  useAlert: message => alerts.push(message), ToybacoPasswordRequirements,
  FormInput: {}, NextButton: {}, DEFAULT_REDIRECT_URL: '/app/', window: { location: '' },
});
// vuelidate の password ルールの状態(required / minLength は値から求める)。
const passwordRuleState = (value, error = true) => {
  const requiredInvalid = value === '';
  const minLengthInvalid = value !== '' && value.length < 6;
  const complexityInvalid = !rules.isToybacoPasswordValid(value);
  return {
    $error: error, $invalid: requiredInvalid || minLengthInvalid || complexityInvalid,
    required: { $invalid: requiredInvalid }, minLength: { $invalid: minLengthInvalid },
    isToybacoPasswordValid: { $invalid: complexityInvalid },
  };
};

test('Edit.vue: gem と同じ規則の検証・要件リスト・リンク無効の案内', async () => {
  assert.match(editSource,
    /^import \{ isToybacoPasswordValid, toybacoPasswordRequirements \} from 'shared\/helpers\/toybacoPasswordRules';$/m);
  assert.match(editSource, /^import ToybacoPasswordRequirements from 'shared\/components\/ToybacoPasswordRequirements\.vue';$/m);
  assert.doesNotMatch(editSource, /shared\/helpers\/Validators|isValidPassword/, 'one rule set: toybacoPasswordRules.js');
  assert.equal(editSource.split('<ToybacoPasswordRequirements :password="credentials.password" />').length - 1, 1);
  assert.equal(editSource.split('href="/app/auth/reset/password"').length - 1, 1);
  assert.match(editSource, /<p v-if="linkExpired" role="status"/);
  assert.doesNotMatch(editSource, /role="alert"/, 'the toast already announces the failure');
  assert.match(editSource, /このリンクは無効か、すでに使用済みです。<a href="\/app\/auth\/reset\/password"/);
  assert.doesNotMatch(editSource, /有効期限/, 'auth/password の update は期限を見ないので、期限切れとは書かない');
  assert.equal(editSource.split('aria-describedby="toybaco-password-requirements"').length - 1, 1);
  // 親の space-y-5 は wrapper に当て、要件リストを password 入力に寄せる。
  assert.match(editSource,
    /\n {8}<div>\n {10}<FormInput\n {12}v-model="credentials\.password"[^<]*?aria-describedby="toybaco-password-requirements"[^<]*?\/>\n {10}<ToybacoPasswordRequirements :password="credentials\.password" \/>\n {8}<\/div>\n/);
  assert.match(editSource, /:error-message="passwordErrorMessage"/);
  const alerts = [];
  const definition = component(editSource, vueGlobals(alerts));
  assert.equal(definition.components.ToybacoPasswordRequirements, ToybacoPasswordRequirements);
  const passwordRules = definition.validations.credentials.password;
  assert.deepEqual(Object.keys(passwordRules), ['required', 'minLength', 'isToybacoPasswordValid']);
  assert.equal(passwordRules.isToybacoPasswordValid, rules.isToybacoPasswordValid);
  assert.equal(passwordRules.minLength.length, 6);

  const message = (value, error = true) => instance(definition, {
    credentials: { password: value, confirmPassword: '' },
    v$: { credentials: { password: passwordRuleState(value, error) } },
  }).passwordErrorMessage;
  assert.equal(message('Abcdef12', false), '');
  assert.equal(message(''), 't:SET_NEW_PASSWORD.PASSWORD.ERROR');
  assert.equal(message('Ab1!'), 't:SET_NEW_PASSWORD.PASSWORD.ERROR');
  assert.equal(message('Abcdef12'), 't:REGISTER.PASSWORD.IS_INVALID_PASSWORD');
  assert.equal(message('Abcdef1!あ'), ONLY_HALF_WIDTH);
  assert.equal(message('Ab1!あ'), ONLY_HALF_WIDTH, 'a full-width character is reported before the length');
  assert.equal(message(OVER_MAX_PASSWORD), TOO_LONG);

  // ボタンの disabled だけに頼らず、送信時にも検証する。
  let touched = 0;
  let sent = 0;
  const invalid = instance(component(editSource, { ...vueGlobals([]), setNewPassword: async () => { sent++; } }), {
    resetPasswordToken: 'raw', v$: { $touch: () => { touched++; }, $invalid: true },
  });
  invalid.submitForm();
  await flush();
  assert.equal(touched, 1);
  assert.equal(sent, 0);
  assert.equal(invalid.newPasswordAPI.showLoading, false);

  // 生成済み auth.js の setNewPassword をそのまま渡して、画面までの写像を通す。
  const submissions = [
    [response(422, { message: 'Invalid token', redirect_url: '/' }), LINK_EXPIRED, true],
    [response(422, { message: SERVER_JA_DUPLICATED }), SERVER_JA, false],
    [response(422, { message: SERVER_MIXED }), GENERIC, false],
    [new Error('Network Error'), GENERIC, false],
  ];
  for (const [failure, expected, linkExpired] of submissions) {
    const { setNewPassword } = authModule(rejectWith(failure));
    const submitAlerts = [];
    const view = instance(component(editSource, { ...vueGlobals(submitAlerts), setNewPassword }), {
      resetPasswordToken: 'raw', v$: { $touch() {}, $invalid: false },
    });
    assert.equal(view.linkExpired, false);
    view.credentials.password = 'Abcdef1!';
    view.credentials.confirmPassword = 'Abcdef1!';
    view.submitForm();
    await flush();
    assert.deepEqual(submitAlerts, [expected]);
    assert.equal(view.linkExpired, linkExpired);
    assert.equal(view.newPasswordAPI.showLoading, false);
  }
  const blankAlerts = [];
  const blank = instance(component(editSource, { ...vueGlobals(blankAlerts), setNewPassword: rejectWith(new Error('')) }), {
    v$: { $touch() {}, $invalid: false },
  });
  blank.submitForm();
  await flush();
  assert.deepEqual(blankAlerts, ['t:SET_NEW_PASSWORD.API.ERROR_MESSAGE']);
});

test('ChangePassword.vue: gem と同じ規則の検証・要件リスト・422 の日本語化', async () => {
  assert.doesNotMatch(changeSource, /parseAPIErrorResponse/);
  assert.doesNotMatch(changeSource, /shared\/helpers\/Validators|isValidPassword/, 'one rule set: toybacoPasswordRules.js');
  assert.match(changeSource,
    /^import \{\n {2}isToybacoJapaneseMessage,\n {2}isToybacoPasswordValid,\n {2}toybacoPasswordRequirements,\n {2}toybacoPasswordServerMessage,\n\} from 'shared\/helpers\/toybacoPasswordRules';$/m);
  assert.equal(changeSource.split('<ToybacoPasswordRequirements :password="password" />').length - 1, 1);
  assert.match(changeSource, /:error="passwordErrorMessage"/);
  assert.match(changeSource, /現在のパスワードが正しくありません/);
  assert.doesNotMatch(changeSource, /isEqPassword\n/, 'vuelidate v2 rule objects are always truthy; use $invalid');
  // 親の gap-4 は wrapper に当て、要件リストを新しいパスワードの入力に寄せる。
  assert.match(changeSource,
    /\n {6}<div>\n {8}<woot-input\n {10}v-model="password"[^<]*?\/>\n {8}<ToybacoPasswordRequirements :password="password" \/>\n {6}<\/div>\n/);
  const alerts = [];
  const definition = component(changeSource, vueGlobals(alerts));
  assert.equal(definition.components.ToybacoPasswordRequirements, ToybacoPasswordRequirements);
  assert.deepEqual(Object.keys(definition.validations.password), ['required', 'minLength', 'isToybacoPasswordValid']);
  assert.equal(definition.validations.password.isToybacoPasswordValid, rules.isToybacoPasswordValid);

  const view = (value, { error = true, confirmationInvalid = false } = {}) => instance(definition, {
    currentPassword: 'Password1!', password: value, passwordConfirmation: 'Abcdef1!',
    v$: { password: passwordRuleState(value, error), passwordConfirmation: { $invalid: confirmationInvalid } },
  });
  assert.equal(view('Abcdef12', { error: false }).passwordErrorMessage, '');
  assert.equal(view('Ab1!').passwordErrorMessage, 't:PROFILE_SETTINGS.FORM.PASSWORD.ERROR');
  assert.equal(view('Abcdef12').passwordErrorMessage, 't:REGISTER.PASSWORD.IS_INVALID_PASSWORD');
  assert.equal(view('Abcdef1!あ').passwordErrorMessage, ONLY_HALF_WIDTH);
  assert.equal(view('Ab1!あ').passwordErrorMessage, ONLY_HALF_WIDTH, 'a full-width character is reported before the length');
  assert.equal(view('').passwordErrorMessage, 't:PROFILE_SETTINGS.FORM.PASSWORD.ERROR');
  assert.equal(view(OVER_MAX_PASSWORD).passwordErrorMessage, TOO_LONG);
  assert.equal(view('Abcdef12').isButtonDisabled, true);
  assert.equal(view('Abcdef1!', { confirmationInvalid: true }).isButtonDisabled, true, 'a mismatched confirmation keeps the button off');
  assert.equal(view('Abcdef1!').isButtonDisabled, false);
  assert.equal(view('Abcd 123').isButtonDisabled, false, 'a space counts as a special character');

  const failures = [
    [response(422, { error: 'Invalid current password' }), '現在のパスワードが正しくありません。'],
    [response(422, { message: SERVER_JA_DUPLICATED, attributes: ['password', 'password_confirmation'] }), SERVER_JA],
    [response(422, { message: SERVER_MIXED }), 't:RESET_PASSWORD.API.ERROR_MESSAGE'],
    [response(422, { message: 'Password must contain at least 1 special character' }), 't:RESET_PASSWORD.API.ERROR_MESSAGE'],
    [response(401, { error: 'Invalid current password' }), 't:RESET_PASSWORD.API.ERROR_MESSAGE'],
    [new Error('Network Error'), 't:RESET_PASSWORD.API.ERROR_MESSAGE'],
  ];
  for (const [failure, expected] of failures) {
    alerts.length = 0;
    const form = instance(definition, {
      password: 'Abcdef1!', passwordConfirmation: 'Abcdef1!', currentPassword: 'Password1!',
      v$: { $touch() {}, $invalid: false }, $store: { dispatch: rejectWith(failure) },
    });
    await form.changePassword();
    assert.deepEqual(alerts, [expected]);
  }
  alerts.length = 0;
  const dispatched = [];
  const success = instance(definition, {
    password: 'Abcdef1!', passwordConfirmation: 'Abcdef1!', currentPassword: 'Password1!',
    v$: { $touch() {}, $invalid: false }, $store: { dispatch: async (...args) => { dispatched.push(args); } },
  });
  await success.changePassword();
  assert.deepEqual(alerts, ['t:PROFILE_SETTINGS.PASSWORD_UPDATE_SUCCESS']);
  assert.deepEqual(JSON.parse(JSON.stringify(dispatched)), [['updatePassword', {
    password: 'Abcdef1!', passwordConfirmation: 'Abcdef1!', currentPassword: 'Password1!',
  }]]);
});

test('Signup/Form.vue: 新規登録も同じ規則と inline の要件リスト(129 文字を「達成」と出さない)', () => {
  assert.match(signupSource, /^import ToybacoPasswordRequirements from 'shared\/components\/ToybacoPasswordRequirements\.vue';$/m);
  assert.match(signupSource, /^import \{ isToybacoPasswordValid \} from 'shared\/helpers\/toybacoPasswordRules';$/m);
  assert.doesNotMatch(signupSource, /from '\.\/PasswordRequirements\.vue'/, 'the upstream popover checks only the minimum length');
  assert.doesNotMatch(signupSource, /shared\/helpers\/Validators|isValidPassword/, 'one rule set: toybacoPasswordRules.js');
  assert.match(signupSource,
    /\n {4}password: \{\n {6}required,\n {6}isToybacoPasswordValid,\n {6}minLength: minLength\(MIN_PASSWORD_LENGTH\),\n {4}\},\n/);
  assert.equal(signupSource.split('<ToybacoPasswordRequirements :password="credentials.password" />').length - 1, 1);
  assert.doesNotMatch(signupSource, /<Transition|v-if="isPasswordFocused"/, 'the list is inline and always visible');
  assert.equal(signupSource.split('aria-describedby="toybaco-password-requirements"').length - 1, 1);
  assert.match(signupSource,
    /\n {8}<FormInput\n {10}v-model="credentials\.password"[^<]*?aria-describedby="toybaco-password-requirements"[^<]*?\/>\n {8}<ToybacoPasswordRequirements :password="credentials\.password" \/>\n {6}<\/div>\n/);
  assert.doesNotThrow(() => new vm.Script(moduleBody(scriptOf(signupSource))));
});

test('ToybacoPasswordRequirements.vue: 入力欄の下の静的リストで、状態を支援技術にも伝える', () => {
  assert.match(requirementsSource, /role="list"/);
  assert.match(requirementsSource, /:id="id"/);
  assert.match(requirementsSource, /id: \{ type: String, default: 'toybaco-password-requirements' \}/);
  assert.match(requirementsSource, /data-testid="toybaco-password-requirements"/);
  assert.match(requirementsSource, /aria-label="パスワードの条件"/);
  assert.match(requirementsSource, /:data-requirement="item\.id"/);
  assert.match(requirementsSource, /:data-met="item\.met"/);
  assert.match(requirementsSource, /class="flex gap-1\.5 items-start"/, 'one requirement per line');
  assert.match(requirementsSource, /aria-hidden="true"/);
  assert.match(requirementsSource,
    /<span class="sr-only">\{\{ item\.met \? '（満たしています）' : '（未達）' \}\}<\/span>/);
  assert.match(requirementsSource, /label: item\.key \? t\(item\.key\) : item\.label,/);
  assert.match(requirementsSource, /^import \{ toybacoPasswordRequirements \} from 'shared\/helpers\/toybacoPasswordRules';$/m);
  const template = requirementsSource.slice(requirementsSource.indexOf('<template>'));
  assert.doesNotMatch(template, /aria-live/, 'reading every keystroke aloud is noisy');
  assert.doesNotMatch(template, /\babsolute\b/, 'the upstream popover would overflow the form on narrow screens');
  for (const token of ['text-n-teal-10', 'text-n-slate-11', 'text-n-slate-10']) assert.ok(requirementsSource.includes(token), token);
  for (const sfc of [requirementsSource, editSource, changeSource]) {
    assert.doesNotThrow(() => new vm.Script(componentBody(sfc)));
  }
});

test('文言: signup.json(ja)の要件文言と secure_password.ja.yml', () => {
  const password = signup.REGISTER.PASSWORD;
  assert.deepEqual({
    IS_INVALID_PASSWORD: password.IS_INVALID_PASSWORD,
    REQUIREMENTS_LENGTH: password.REQUIREMENTS_LENGTH,
    REQUIREMENTS_UPPERCASE: password.REQUIREMENTS_UPPERCASE,
    REQUIREMENTS_LOWERCASE: password.REQUIREMENTS_LOWERCASE,
    REQUIREMENTS_NUMBER: password.REQUIREMENTS_NUMBER,
    REQUIREMENTS_SPECIAL: password.REQUIREMENTS_SPECIAL,
  }, {
    IS_INVALID_PASSWORD: 'パスワードには英大文字・英小文字・数字・記号をそれぞれ 1 文字以上含めてください',
    REQUIREMENTS_LENGTH: '6〜128 文字',
    REQUIREMENTS_UPPERCASE: '英大文字（A〜Z）を 1 文字以上',
    REQUIREMENTS_LOWERCASE: '英小文字（a〜z）を 1 文字以上',
    REQUIREMENTS_NUMBER: '数字（0〜9）を 1 文字以上',
    // vue-i18n では @ が linked message の記号で、production build の t() が SyntaxError を投げるので例に入れない。
    REQUIREMENTS_SPECIAL: '記号（! # $ % など）を 1 文字以上',
  });
  for (const [key, value] of Object.entries(password).filter(([name]) => /REQUIREMENTS_|IS_INVALID/.test(name))) {
    assert.doesNotMatch(value, /[@{}|]/, `vue-i18n special character in ${key}`);
  }
  assert.match(securePasswordJa, /^\s+minimum_characters: ".*[ぁ-んァ-ヶ一-龠].*"$/m);
  assert.match(securePasswordJa, /^\s+minimum_length: ".*[ぁ-んァ-ヶ一-龠].*"$/m);
  // gem は `> max` のときにエラーなので「以内」(未満ではない)。
  assert.match(securePasswordJa, /^\s+maximum_characters: "の%\{type\}は%\{count\}%\{subject\}以内にしてください"$/m);
  assert.match(securePasswordJa, /^\s+maximum_length: "は%\{count\}%\{subject\}以内にしてください"$/m);
  assert.doesNotMatch(securePasswordJa, /未満/);
});

const CONTROL_LINE = "    'tests/chatwoot-password-policy-ui.test.mjs' \\";
const QUALITY_RUN =
  '  TOYBACO_CONTROL_ROOT="$CONTROL_ROOT" node --test "$CONTROL_ROOT/tests/chatwoot-password-policy-ui.test.mjs"';
const POSTIZ_LINE = '  tests/chatwoot-password-policy-ui.test.mjs';

function exactCount(lines, expected) {
  return lines.filter(line => line === expected).length;
}

// bash 関数 name() { ... } の本体(列 0 の閉じ括弧まで)。
function functionBody(source, name) {
  const lines = source.split('\n');
  assert.equal(exactCount(lines, `${name}() {`), 1, `gate function ${name} must exist once`);
  const start = lines.indexOf(`${name}() {`);
  const end = lines.findIndex((line, index) => index > start && line === '}');
  assert.ok(end > start, `gate function ${name} must close`);
  return lines.slice(start + 1, end);
}

function validateChatwootGate(gate) {
  assert.equal(exactCount(functionBody(gate, 'control_file_list'), CONTROL_LINE), 1, 'gate control_file_list must carry the test');
  assert.equal(exactCount(functionBody(gate, 'verify_base_and_frame_contract'), QUALITY_RUN), 1,
    'gate quality stage must run the test');
  assert.equal(exactCount(gate.split('\n'), QUALITY_RUN), 1, 'the gate runs the test once');
}

function validatePostizGate(gate) {
  const lines = gate.split('\n');
  const start = lines.indexOf('CONTROL_STATIC_FILES=(');
  assert.ok(start >= 0, 'Postiz gate CONTROL_STATIC_FILES must exist');
  const end = lines.findIndex((line, index) => index > start && line === ')');
  assert.ok(end > start, 'Postiz gate CONTROL_STATIC_FILES must close');
  assert.equal(exactCount(lines.slice(start + 1, end), POSTIZ_LINE), 1, 'Postiz gate CONTROL_STATIC_FILES must carry the test');
}

const chatwootGate = read('bin/toybaco-chatwoot-gate');
// Chatwoot gate の control snapshot に Postiz gate は入っていない(control_file_list に無い)。repo root では必須。
const postizGatePath = join(root, 'bin/toybaco-postiz-gate');
const postizGate = existsSync(postizGatePath) ? readFileSync(postizGatePath, 'utf8') : null;

test('配線契約: Chatwoot gate の control_file_list と quality stage、Postiz gate の CONTROL_STATIC_FILES', () => {
  assert.ok(postizGate !== null || controlRoot, 'bin/toybaco-postiz-gate is required outside the Chatwoot gate control snapshot');
  validateChatwootGate(chatwootGate);
  if (postizGate !== null) validatePostizGate(postizGate);
});

test('配線契約の負例: 各配線行を外すか移すと契約が落ちる', () => {
  let negatives = 0;
  const chatwootNegatives = [
    chatwootGate.replace(`${CONTROL_LINE}\n`, ''),
    chatwootGate.replace(`${QUALITY_RUN}\n`, ''),
    chatwootGate.replace(`${QUALITY_RUN}\n`, `${QUALITY_RUN}\n${QUALITY_RUN}\n`),
    // quality stage の実行行を、quality stage ではない別の関数へ移す
    chatwootGate.replace(`${QUALITY_RUN}\n`, '').replace('control_manifest() {\n', `control_manifest() {\n${QUALITY_RUN}\n`),
  ];
  for (const [index, source] of chatwootNegatives.entries()) {
    assert.notEqual(source, chatwootGate, `Chatwoot gate negative control must change its input: ${index + 1}`);
    assert.throws(() => validateChatwootGate(source), `Chatwoot gate negative control was accepted: ${index + 1}`);
    negatives++;
  }
  if (postizGate !== null) {
    const omitted = postizGate.replace(`${POSTIZ_LINE}\n`, '');
    assert.notEqual(omitted, postizGate);
    assert.throws(() => validatePostizGate(omitted), 'Postiz gate negative control was accepted');
    negatives++;
  }
  assert.ok(negatives >= 3);
  console.log(`password policy wiring: PASS (${negatives} negative controls${postizGate === null ? ', Postiz gate not in snapshot' : ''})`);
});
