import { readdirSync, readFileSync } from 'node:fs';
import test from 'node:test';
import assert from 'node:assert/strict';

// The first-run guide reads the dashboard overlay (Vue routes, locale, views). The Chatwoot gate carries the whole
// overlay; the Postiz gate runs only toybaco-pointer-guide.test.mjs with the pointer assets, so these stay here.

// First-run guide (U1): every step can be left for later, store facts are reachable without a connection,
// the connection step shows the real channel states, and a plan limit is explained instead of "retry".
const start = readFileSync(new URL('../overlay/app/app/javascript/dashboard/routes/dashboard/onboarding/ToybacoStart.vue', import.meta.url), 'utf8');
const template = start.slice(start.indexOf('<template>'), start.lastIndexOf('</template>'));
function block(opening) {
  const at = template.indexOf(opening);
  assert(at >= 0, `guide block missing: ${opening}`);
  const next = template.indexOf('<template v-else-if=', at + opening.length);
  return template.slice(at, next < 0 ? template.length : next);
}

test('each guide step offers a later option bound to that step', () => {
  const blocks = {
    facts: block('<template v-if="showFacts">'),
    connect: block(`<template v-else-if="state?.phase === 'connect'">`),
    receive: block(`<template v-else-if="state?.phase === 'receive'">`),
    reply: block(`<template v-else-if="state?.phase === 'reply'">`),
    posting: block(`<template v-else-if="state?.phase === 'posting'">`),
  };
  for (const [step, text] of Object.entries(blocks)) {
    assert.equal(template.split(`data-toybaco-guide-skip="${step}"`).length - 1, 1, `${step} later option`);
    assert(text.includes(`data-toybaco-guide-skip="${step}"`), `${step} later option sits in its own step`);
    assert(text.includes(`@click="skipStep('${step}')"`), `${step} later option records the step`);
    assert(text.includes('あとで設定する'), `${step} later label`);
  }
  assert(start.includes('updateGrowthGuide({ skipped: [...new Set([...skipped.value, step])] });'));
});

test('store facts open from the first screen and the settings menu without a connection', () => {
  const purpose = block(`<template v-else-if="state?.phase === 'purpose'">`);
  assert(purpose.includes('data-toybaco-guide-action="facts.open"') && purpose.includes('@click="openFacts"'));
  assert(start.includes('() => route.name === "toybaco_store_facts_settings"'));
  assert(/settingsView\.value \|\|\s+factsRequested\.value \|\|\s+state\.value\.phase === "facts"/.test(start));
  const routes = readFileSync(new URL('../overlay/app/app/javascript/dashboard/routes/dashboard/settings/billing/billing.routes.js', import.meta.url), 'utf8');
  assert(routes.includes("path: frontendURL('accounts/:accountId/settings/store'),\n      name: 'toybaco_store_facts_settings',\n      component: () => import('../../onboarding/ToybacoStart.vue'),"));
  const sidebar = readFileSync(new URL('../overlay/app/app/javascript/dashboard/components-next/sidebar/Sidebar.vue', import.meta.url), 'utf8');
  assert(/currentAccount\.value\?\.toybaco_growth_onboarding === true &&\s+currentRole\.value === 'administrator'\s+\?\s+\[\s+\{\s+name: 'Settings Store Facts',\s+label: '店舗情報',/.test(sidebar));
  assert(sidebar.includes("const currentRole = useMapGetter('getCurrentRole');"));
  // Store facts are saved by administrators only; the route and the menu both say so.
  assert(routes.includes("name: 'toybaco_store_facts_settings',\n      component: () => import('../../onboarding/ToybacoStart.vue'),\n      meta: {\n        permissions: ['administrator'],\n      },"));
  assert(sidebar.includes("to: accountScopedRoute('toybaco_store_facts_settings'),"));
});

test('the completion screen can resume every step that was left for later', () => {
  const complete = block(`<template v-else-if="state?.phase === 'complete'">`);
  for (const [marker, action] of [['facts', '@click="openFacts"'], ['connect', `@click="resumeSteps('connect')"`],
    ['posting', `@click="resumeSteps('posting')"`], ['receive', `@click="resumeSteps('receive', 'reply')"`]]) {
    assert(complete.includes(`data-toybaco-guide-resume="${marker}"`), `${marker} resume`);
    assert(complete.includes(action), `${marker} resume action`);
  }
  assert(complete.includes('<li v-if="postingLeft">'));
});

// Opening the posting screen finishes the posting step; it is recorded in `opened`, never in `skipped`, so the
// completion screen offers「投稿の準備 / 続ける」only when the step was left for later and the screen was not opened.
test('opening the posting screen is recorded apart from leaving the step for later', () => {
  const script = start.slice(start.indexOf('<script setup>'), start.indexOf('</script>'));
  function fn(signature) {
    const at = script.indexOf(signature);
    assert(at >= 0, `guide function missing: ${signature}`);
    return script.slice(at, script.indexOf('\n}\n', at) + 2);
  }
  assert(script.includes('const opened = computed(() => state.value?.preference?.opened || []);'));
  assert(/const postingLeft = computed\(\s*\(\) => skipped\.value\.includes\("posting"\) && !opened\.value\.includes\("posting"\),\s*\);/.test(script));
  const open = fn('async function openPosting()');
  assert(open.includes('if (!opened.value.includes("posting"))'));
  assert(open.includes('await updateGrowthGuide({ opened: [...opened.value, "posting"] });'));
  assert(!open.includes('skipped'), 'opening the posting screen never marks the step as left for later');
  const resume = fn('function resumeSteps(');
  assert(resume.includes('skipped: skipped.value.filter((step) => !steps.includes(step)),'));
  assert(!resume.includes('opened'), 'resuming a step leaves the opened steps as they are');
  const complete = block(`<template v-else-if="state?.phase === 'complete'">`);
  assert(/\|\|\s+postingLeft\s+"\s+class="pending"/.test(complete), 'the pending list shows for a posting step left for later');
  assert(!complete.includes("skipped.includes('posting')"), 'the posting row never shows from skipped alone');
  assert.equal(template.split('data-toybaco-guide-action="posting.open"').length - 1, 1);
  assert(block(`<template v-else-if="state?.phase === 'posting'">`).includes('@click="openPosting"'));
});

test('connection step lists real channel states and explains the plan limit', () => {
  const connect = block(`<template v-else-if="state?.phase === 'connect'">`);
  for (const key of ['email_forward', 'gmail', 'microsoft', 'line', 'web_widget', 'instagram']) {
    assert(connect.includes(`data-toybaco-connection="${key}"`), `${key} row`);
  }
  assert(!start.includes('接続方式を準備しています。'), 'Instagram shows its actual state, not a fixed sentence');
  for (const label of ['ready: "設定済み"', 'connected: "接続済み"', 'available: "未接続"', 'preparing: "準備中(近日対応)"']) {
    assert(start.includes(label), label);
  }
  assert(connect.includes('このプランでは受信箱を{{ connections.limit }}件まで接続できます'));
  assert(connect.includes('接続済みの受信箱: {{ connections.count }}件'));
  // A free store can move up from「ご契約内容」→「有料プランを見る」. Paid contracts cannot change plan in the app,
  // so only the free branch points at the contract screen and every other contract is sent to support.
  const notice = connect.slice(connect.indexOf('<p v-if="atLimit"'), connect.indexOf('</p>', connect.indexOf('<p v-if="atLimit"')));
  assert(/<span v-if="connections\.free"\s*>上位プランへの変更は「ご契約内容」の「有料プランを見る」から行えます。<\/span\s*><span v-else\s*>プランの変更やご不明な点は、サポートへお問い合わせください。<\/span\s*>/.test(notice));
  assert.equal(notice.split('ご契約内容').length - 1, 1, 'only the free-plan branch points at the contract screen');
});

test('connection result explains the limit with the returned numbers and never asks to retry it', async () => {
  const source = readFileSync(new URL('../overlay/app/app/javascript/dashboard/composables/useConnectionResult.js', import.meta.url), 'utf8');
  const pure = source.slice(source.indexOf('const LIMIT_GUIDANCE'), source.indexOf('// A return notice')).replace('export function', 'function');
  const { runInNewContext } = await import('node:vm');
  const message = runInNewContext(`${pure}; connectionResultMessage`);
  assert.equal(message('limit', { toybaco_limit: '4', toybaco_count: '4' }),
    'このプランでは受信箱を4件まで接続できます(現在4件)。プランの変更やご不明な点は、サポートへお問い合わせください。');
  for (const query of [{}, { toybaco_limit: 'x', toybaco_count: '4' }, { toybaco_limit: ['4', '5'], toybaco_count: '4' }]) {
    assert.equal(message('limit', query), 'このプランで接続できる受信箱の上限に達しています。プランの変更やご不明な点は、サポートへお問い合わせください。');
  }
  // A free store (toybaco_plan=free, exactly) is pointed at「有料プランを見る」; any other value keeps the support notice.
  assert.equal(message('limit', { toybaco_limit: '2', toybaco_count: '2', toybaco_plan: 'free' }),
    'このプランでは受信箱を2件まで接続できます(現在2件)。上位プランへの変更は「ご契約内容」の「有料プランを見る」から行えます。');
  assert.equal(message('limit', { toybaco_limit: 'x', toybaco_count: '2', toybaco_plan: 'free' }),
    'このプランで接続できる受信箱の上限に達しています。上位プランへの変更は「ご契約内容」の「有料プランを見る」から行えます。');
  for (const plan of [['free'], ['free', 'free'], 'FREE', 'free ', ' free', 'paid', '', null, undefined]) {
    assert.equal(message('limit', { toybaco_limit: '2', toybaco_count: '2', toybaco_plan: plan }),
      'このプランでは受信箱を2件まで接続できます(現在2件)。プランの変更やご不明な点は、サポートへお問い合わせください。', JSON.stringify(plan));
  }
  for (const query of [{ toybaco_limit: '4', toybaco_count: '4' }, { toybaco_limit: '2', toybaco_count: '2', toybaco_plan: 'free' }]) {
    assert(!message('limit', query).includes('もう一度'));
  }
  assert.equal(message('retry'), '接続できませんでした。もう一度お試しください。');
  assert(/const NOTICE_PARAMS = \[\s*'toybaco_connection',\s*'toybaco_limit',\s*'toybaco_count',\s*'toybaco_plan',\s*\];/.test(source),
    'the plan mark is removed from the address with the other notice parameters');
});

test('app wording follows the LP terms (受信箱・スタッフ・有料プラン)', () => {
  const localeDirectory = new URL('../overlay/app/app/javascript/dashboard/i18n/locale/ja/', import.meta.url);
  const settings = JSON.parse(readFileSync(new URL('settings.json', localeDirectory), 'utf8'));
  assert.deepEqual(
    ['INBOXES', 'NEW_INBOX', 'CHANNELS', 'AGENTS', 'AGENT_ASSIGNMENT', 'REPORTS_AGENT'].map((key) => settings.SIDEBAR[key]),
    ['受信箱', '新しい受信箱', '受信箱', 'スタッフ', 'スタッフ割り当て', 'スタッフ'],
  );
  const agents = JSON.parse(readFileSync(new URL('agentMgmt.json', localeDirectory), 'utf8'));
  assert.equal(agents.AGENT_MGMT.HEADER, 'スタッフ');
  assert.equal(agents.AGENT_MGMT.HEADER_BTN_TXT, 'スタッフを追加');
  for (const name of ['settings.json', 'inboxMgmt.json', 'agentMgmt.json', 'customRole.json', 'integrations.json', 'report.json', 'sla.json']) {
    const text = readFileSync(new URL(name, localeDirectory), 'utf8');
    assert.doesNotMatch(text, /受信トレイ|ビジネスプラン|エンタープライズプラン|スタートアップ、ビジネス/, name);
  }
  assert.doesNotMatch(readFileSync(new URL('agentMgmt.json', localeDirectory), 'utf8'), /担当者|エージェント/);
});

test('first-login wording names the guide, the password setting and the inbox consistently', () => {
  const localeDirectory = new URL('../overlay/app/app/javascript/dashboard/i18n/locale/ja/', import.meta.url);
  const reset = JSON.parse(readFileSync(new URL('resetPassword.json', localeDirectory), 'utf8')).RESET_PASSWORD;
  assert.deepEqual([reset.TITLE, reset.DESCRIPTION, reset.EMAIL.ERROR, reset.API.SUCCESS_MESSAGE], [
    'パスワードを設定',
    'トイバコにログインするメールアドレスを入力してください。パスワード設定用のメールをお送りします。',
    '有効なメールアドレスを入力してください。',
    'パスワード設定用のリンクを、入力したメールアドレスへ送信しました。',
  ]);
  assert.doesNotMatch(JSON.stringify(reset), /リセット|\.",/);
  for (const name of readdirSync(localeDirectory).filter((file) => file.endsWith('.json'))) {
    assert.doesNotMatch(readFileSync(new URL(name, localeDirectory), 'utf8'), /受信トレイ|受信ボックス/, name);
  }
  const guide = readFileSync(new URL('../overlay/app/app/javascript/dashboard/components/widgets/ToybacoGrowthGuide.vue', import.meta.url), 'utf8');
  assert(guide.includes('<span>お店の準備を、画面で案内します。</span>'));
  const mail = readFileSync(new URL('../overlay/app/app/views/devise/mailer/reset_password_instructions.html.erb', import.meta.url), 'utf8');
  assert(mail.includes('問い合わせの受信や投稿・AIの利用には、ログイン後の案内に沿った窓口の接続や設定が必要です。'));
  assert(!mail.includes('お店の準備'));
  const release = readFileSync(new URL('../overlay/app/public/toybaco-growth-inbox-release.mjs', import.meta.url), 'utf8');
  assert(!release.includes('受信ボックス') && release.includes('再開する受信箱を選んでください。'));
});
