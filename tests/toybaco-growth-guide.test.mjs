import { readdirSync, readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import test from 'node:test';
import assert from 'node:assert/strict';
import { slotPlacement } from '../overlay/app/public/brand-assets/toybaco-pointer-guide.mjs';

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

// A10: on the guide screen the pointer prompt sits in a place kept right under the heading (the pointer guide keeps
// its height), so it never covers the heading or the choices. Every step the guide points at here has that place.
test('every guide screen step keeps a place for the prompt right under its heading', () => {
  const guide = readFileSync(new URL('../overlay/app/app/javascript/dashboard/components/widgets/ToybacoGrowthGuide.vue', import.meta.url), 'utf8');
  const steps = guide.slice(guide.indexOf('const setupSteps = {'), guide.indexOf('if (inSetup.value) return setupSteps'));
  const actions = [...new Set([...steps.matchAll(/'([a-z]+\.[a-z_]+)'/g)].map(([, id]) => id))];
  for (const id of ['purpose.inbox', 'connection.google', 'connection.microsoft', 'connection.line', 'facts.confirm', 'reply.open', 'posting.open'])
    assert(actions.includes(id), `guide screen step ${id}`);
  const blocks = {
    facts: block('<template v-if="showFacts">'),
    ...Object.fromEntries(['purpose', 'connect', 'reply', 'posting'].map((phase) =>
      [phase, block(`<template v-else-if="state?.phase === '${phase}'">`)])),
  };
  const place = /<\/h1>\n\s*(?:<!--[^\n]*-->\n\s*)?<div\n\s*(?:v-if="!settingsView"\n\s*)?data-toybaco-guide-slot\n\s*:class="\{ reserved: keepsGuidePlace\('([a-z]+)'\) \}"\n\s*><\/div>\n/;
  for (const id of actions) {
    const [phase, text] = Object.entries(blocks).find(([, candidate]) => candidate.includes(`data-toybaco-guide-action="${id}"`)) || [];
    assert(text, `${id} is on the guide screen`);
    assert.equal(text.match(place)?.[1], phase, `${id}: place right under the heading, kept for the ${phase} step`);
    assert.equal(text.split('data-toybaco-guide-slot').length - 1, 1, `${id}: one place in its step`);
  }
  // The store facts page in the settings menu has the place too: a support prompt there sits under「店舗情報」.
  assert(!/v-if="!settingsView"\n\s*data-toybaco-guide-slot/.test(blocks.facts));
  // The receive and completion screens have no pointer step (setupSteps), so they keep no place.
  const setup = guide.slice(guide.indexOf('const setupSteps = {'), guide.indexOf('};', guide.indexOf('const setupSteps = {')));
  assert.deepEqual([...setup.matchAll(/^  (\w+): \[/gm)].map(([, phase]) => phase), ['purpose', 'connect', 'facts', 'reply', 'posting']);
  for (const phase of ['receive', 'complete'])
    assert(!block(`<template v-else-if="state?.phase === '${phase}'">`).includes('data-toybaco-guide-slot'), `${phase}: no place`);
});

// A10-2: the page keeps the place under the heading before the prompt appears, so the choices never jump down.
// It keeps it only where the guide will point (ToybacoGrowthGuide wantedStep), never for a closed guide.
test('the place under the heading is kept before the prompt appears, never for a closed guide', () => {
  // One line of the prompt is 82.4px at 1280, 768 and 390 wide (headless Chrome); the pointer guide adds its gap.
  const style = start.slice(start.indexOf('<style scoped>'));
  const kept = style.match(/\n\[data-toybaco-guide-slot\]\.reserved \{\n  min-height: (\d+)px;\n\}/);
  assert(kept, 'the kept place has a min-height');
  assert.equal(Number(kept[1]), slotPlacement({ left: 0, top: 0, width: 574 }, { height: 82.4 }).reserve);
  const guide = (phase, extra = {}) => ({
    phase, administrator: true, inboxes: [], connections: { count: 0, limit: 4, channels: [] },
    preference: { purpose: 'inbox', dismissed: false, skipped: [], opened: [] }, ...extra,
  });
  const closed = { preference: { purpose: 'inbox', dismissed: true, skipped: [], opened: [] } };
  const keeps = (current, phase = current.phase) => startScript(current, (value) => value).page.keepsGuidePlace(phase);
  for (const phase of ['purpose', 'connect', 'facts', 'reply', 'posting']) {
    assert.equal(keeps(guide(phase)), true, `${phase}: kept while the guide is open`);
    assert.equal(keeps(guide(phase, closed)), false, `${phase}: no blank place once the guide is closed`);
  }
  // The guide points at nothing for staff on the connect and facts steps or at the plan limit: nothing is kept.
  assert.equal(keeps(guide('connect', { administrator: false })), false);
  assert.equal(keeps(guide('connect', { connections: { count: 4, limit: 4, channels: [] } })), false);
  assert.equal(keeps(guide('facts', { administrator: false })), false);
  // Store facts opened from the first screen are not the facts step; the guide stays on the purpose step there.
  assert.equal(keeps(guide('purpose'), 'facts'), false);
  // The settings menu's store facts page never runs the first-run guide, so nothing is kept there in advance.
  assert.equal(startScript(guide('facts'), (value) => value, 'toybaco_store_facts_settings').page.keepsGuidePlace('facts'), false);
});

// A10: on the completion screen「ホームへ」and the purpose switch never share a line with mismatched baselines.
test('the purpose switch is a line of its own after「ホームへ」', () => {
  const style = start.slice(start.indexOf('<style scoped>'));
  assert(/\n\.change-purpose \{\n  display: block;\n  margin-top: 28px;\n\}/.test(style));
  const complete = block(`<template v-else-if="state?.phase === 'complete'">`);
  assert(complete.includes('class="home-link"'));
  assert(template.indexOf('class="text-button change-purpose"') > template.indexOf('class="home-link"'));
});

// A10: the saved notice belongs to the step it was saved on (or the one screen right after the save). It leaves when
// the step or the purpose changes and does not come back. The script runs with a minimal Vue reactivity stand-in.
function startScript(initial, respond, routeName = 'toybaco_growth_start') {
  const script = start.slice(start.indexOf('<script setup>') + '<script setup>'.length, start.indexOf('</script>'));
  const body = script.replace(/import\s+(\{[^}]*\}|\w+)\s+from\s+"([^"]+)";/g, (_, names, from) =>
    names.startsWith('{')
      ? `const ${names.replace(/\s+as\s+/g, ': ')} = modules[${JSON.stringify(from)}];`
      : `const ${names} = modules[${JSON.stringify(from)}].default;`);
  assert(!/^import /m.test(body), 'every import is replaced');
  const watchers = [];
  // Like Vue: a list of sources runs the callback when any one of them changed.
  const same = (a, b) => (Array.isArray(a) ? a.every((value, index) => Object.is(value, b[index])) : Object.is(a, b));
  const flush = () => watchers.forEach((watcher) => {
    const value = watcher.read();
    if (same(value, watcher.last)) return;
    const previous = watcher.last;
    watcher.last = value;
    watcher.callback(value, previous);
  });
  const state = { value: initial };
  const server = { flushFirst: true };
  const answer = async (body) => {
    state.value = respond(state.value, body);
    // Vue runs the watchers when the new state arrives; the other order is covered by flushFirst = false.
    if (server.flushFirst) flush();
    return state.value;
  };
  const modules = {
    vue: {
      ref: (value) => ({ value }),
      reactive: (value) => value,
      computed: (read) => ({ get value() { return read(); } }),
      watch: (source, callback, options = {}) => {
        const one = (item) => (typeof item === 'function' ? item() : item.value);
        const read = Array.isArray(source) ? () => source.map(one) : () => one(source);
        const watcher = { read, callback, last: read() };
        watchers.push(watcher);
        if (options.immediate) callback(watcher.last);
      },
      onBeforeUnmount() {},
    },
    'vue-router': { useRoute: () => ({ name: routeName }), useRouter: () => ({ push() {} }) },
    'dashboard/composables/useAccount': { useAccount: () => ({ accountId: { value: 1 } }) },
    'dashboard/api/channel/googleClient': { default: {} },
    'dashboard/api/channel/microsoftClient': { default: {} },
    'dashboard/composables/toybacoGrowthGuide': {
      growthGuideState: state,
      growthGuideError: { value: '' },
      growthGuideBusy: { value: false },
      refreshGrowthGuide() {},
      updateGrowthGuide: (preference) => answer({ preference }),
      saveGrowthFacts: (fields) => answer({ fields }),
    },
  };
  const page = runInNewContext(`(function (modules) {${body}
    return { factsSaved, showFacts, factsRequested, openFacts, saveFacts, updateGrowthGuide, keepsGuidePlace };
  })`, {})(modules);
  // The template shows「店舗情報を保存しました。」with exactly this condition.
  const notice = () => page.factsSaved.value && !page.showFacts.value;
  return { page, state, server, flush, notice };
}

test('the saved notice stays on the step it was saved on and leaves when the step or purpose changes', async () => {
  assert(template.includes('<p v-if="factsSaved && !showFacts" role="status" class="saved">'));
  const guideState = (phase, purpose) => ({ phase, preference: { purpose, skipped: [], opened: [] }, inboxes: [] });
  for (const flushFirst of [true, false]) {
    // Staging: facts saved from the first screen, then the purpose switched to posting (3/5 発信).
    const first = startScript(guideState('purpose', null), (current, body) =>
      body.fields ? current : guideState(body.preference.purpose === 'posting' ? 'posting' : 'connect', body.preference.purpose));
    first.server.flushFirst = flushFirst;
    first.page.openFacts();
    assert.equal(first.page.showFacts.value, true);
    await first.page.saveFacts();
    first.flush();
    assert.equal(first.notice(), true, 'shown on the screen right after the save');
    await first.page.updateGrowthGuide({ purpose: 'posting', dismissed: false });
    first.flush();
    assert.equal(first.state.value.phase, 'posting');
    assert.equal(first.notice(), false, 'gone once the purpose moved the guide to the posting step');
    await first.page.updateGrowthGuide({ purpose: 'inbox', dismissed: false });
    await first.page.updateGrowthGuide({ purpose: 'posting', dismissed: false });
    first.flush();
    assert.equal(first.notice(), false, 'never comes back on a later visit to the same step');

    // The facts step itself: the save moves the guide on, the next screen shows the notice once, then it leaves.
    const facts = startScript(guideState('facts', 'inbox'), (current, body) =>
      body.fields ? guideState('receive', 'inbox') : current);
    facts.server.flushFirst = flushFirst;
    await facts.page.saveFacts();
    facts.flush();
    assert.equal(facts.state.value.phase, 'receive');
    assert.equal(facts.notice(), true, 'shown on the screen right after the facts step');
    facts.state.value = guideState('reply', 'inbox');
    facts.flush();
    assert.equal(facts.notice(), false, 'gone when the next step arrives');

    // The completion screen stays complete when the purpose switches after the posting screen was opened
    // (Onboarding#posting_progress); the purpose alone still takes the notice away.
    const done = startScript(guideState('complete', 'inbox'), (current, body) =>
      body.fields ? current : guideState('complete', body.preference.purpose));
    done.server.flushFirst = flushFirst;
    done.page.openFacts();
    await done.page.saveFacts();
    done.flush();
    assert.equal(done.notice(), true, 'shown on the completion screen after the save');
    await done.page.updateGrowthGuide({ purpose: 'posting', dismissed: false });
    done.flush();
    assert.equal(done.state.value.phase, 'complete');
    assert.equal(done.notice(), false, 'gone when only the purpose changed');

    // A purpose read for the first time (not set → set) on the same step is not a change of step.
    const read = startScript({ ...guideState('complete', undefined), preference: { skipped: [], opened: [] } },
      (current, body) => (body.fields ? current : guideState('complete', body.preference.purpose)));
    read.server.flushFirst = flushFirst;
    read.page.openFacts();
    await read.page.saveFacts();
    read.flush();
    assert.equal(read.notice(), true);
    read.state.value = guideState('complete', 'inbox');
    read.flush();
    assert.equal(read.notice(), true, 'kept while only the purpose was read');
    read.state.value = guideState('reply', 'inbox');
    read.flush();
    assert.equal(read.notice(), false, 'gone with the next step');
  }
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
