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
  // The guide points at nothing for staff on the connect and facts steps: nothing is kept.
  assert.equal(keeps(guide('connect', { administrator: false })), false);
  // U4-R(V3): 上限到達時にも案内を出す(先へ進むボタンを指す)ため、場所を取る。
  assert.equal(keeps(guide('connect', { connections: { count: 4, limit: 4, channels: [] } })), true);
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
// The completion screen reads the AI readiness with fetch: `readiness` answers it (by default it never answers) and
// `requests` keeps what the page asked for. `pageshow(persisted)` plays the browser event and `unmount()` the page leaving.
function startScript(initial, respond, routeName = 'toybaco_growth_start', readiness = () => new Promise(() => {})) {
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
  const unmounts = [];
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
      onBeforeUnmount: (callback) => unmounts.push(callback),
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
  const requests = [];
  const fetch = (url, options) => {
    requests.push({ url, options });
    return readiness(url, options);
  };
  const listeners = {};
  const window = {
    addEventListener: (type, listener) => { listeners[type] = listener; },
    removeEventListener: (type, listener) => { if (listeners[type] === listener) delete listeners[type]; },
  };
  const page = runInNewContext(`(function (modules) {${body}
    return { factsSaved, showFacts, factsRequested, openFacts, saveFacts, updateGrowthGuide, keepsGuidePlace,
      connectionGroups, canProceed, proceed, widgetPreviewUrl, nextInbox, nextStep, snippetLink, aiStep };
  })`, { fetch, window })(modules);
  // The template shows「店舗情報を保存しました。」with exactly this condition.
  const notice = () => page.factsSaved.value && !page.showFacts.value;
  const pageshow = (persisted) => listeners.pageshow?.({ persisted });
  const unmount = () => unmounts.forEach((callback) => callback());
  return { page, state, server, flush, notice, requests, pageshow, unmount };
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

// U4 (2026-09-27, staging store 14): while Gmail/Microsoft wait for their review and Instagram for Meta, a store
// connects LINE or Web chat. The guide counts those windows (Ruby runtime test), and the guide screen follows.
// Objects made inside the page script belong to another realm; compare them as plain data.
const plain = (value) => JSON.parse(JSON.stringify(value));
const connectState = (extra = {}) => ({
  phase: 'connect', administrator: true, inboxes: [], connections: { count: 1, limit: 4, channels: [] },
  preference: { purpose: 'inbox', dismissed: false, skipped: [], opened: [] }, ...extra,
});

test('connection cards: pressable first, then connected or set up, reviews pending last under「審査完了後に使えます」', () => {
  const row = (key, state) => ({ key, state, count: ['connected', 'ready'].includes(state) ? 1 : 0 });
  const groups = (channels) =>
    plain(startScript(connectState({ connections: { count: 1, limit: 4, channels } }), (value) => value).page.connectionGroups.value);
  // Staging store 14: LINE and Web chat can be pressed; the forwarding mail is set up; three wait for a review.
  assert.deepEqual(groups([row('email_forward', 'ready'), row('gmail', 'preparing'), row('microsoft', 'preparing'),
    row('line', 'available'), row('web_widget', 'available'), row('instagram', 'preparing')]),
  [{ id: 'main', keys: ['line', 'web_widget', 'email_forward'] }, { id: 'preparing', keys: ['gmail', 'microsoft', 'instagram'] }]);
  // Within a group the former order stays (Google, Microsoft, LINE, Web chat, Instagram).
  assert.deepEqual(groups([row('email_forward', 'ready'), row('gmail', 'available'), row('microsoft', 'preparing'),
    row('line', 'available'), row('web_widget', 'connected'), row('instagram', 'available')]),
  [{ id: 'main', keys: ['gmail', 'line', 'instagram', 'email_forward', 'web_widget'] }, { id: 'preparing', keys: ['microsoft'] }]);
  // No forwarding mail and nothing waiting: one group and no heading.
  assert.deepEqual(groups([row('gmail', 'available'), row('microsoft', 'available'), row('line', 'connected'),
    row('web_widget', 'available'), row('instagram', 'available')]),
  [{ id: 'main', keys: ['gmail', 'microsoft', 'web_widget', 'instagram', 'line'] }]);
  // A card whose row is missing or whose state is unknown stays on the pressable side (the card decides whether it can be
  // pressed); a missing forwarding mail is still not drawn.
  assert.deepEqual(groups([]), [{ id: 'main', keys: ['gmail', 'microsoft', 'line', 'web_widget', 'instagram'] }]);
  assert.deepEqual(groups([row('gmail', 'connected'), row('microsoft', 'unknown'), row('line', 'available')]),
    [{ id: 'main', keys: ['microsoft', 'line', 'web_widget', 'instagram', 'gmail'] }]);
  // Everything waiting: no empty frame for the pressable group, only the waiting group under its heading.
  assert.deepEqual(groups(['gmail', 'microsoft', 'line', 'web_widget', 'instagram'].map((key) => row(key, 'preparing'))),
    [{ id: 'preparing', keys: ['gmail', 'microsoft', 'line', 'web_widget', 'instagram'] }]);
  // The page renders the groups in that order: the heading only before the waiting group, which is a labelled group.
  const connect = block(`<template v-else-if="state?.phase === 'connect'">`);
  const loop = connect.indexOf('<template v-for="group in connectionGroups" :key="group.id">');
  const cards = connect.indexOf('<template v-for="key in group.keys" :key="key">');
  assert(loop > 0 && cards > loop, 'the cards are drawn group by group');
  assert(/<h2\s+v-if="group\.id === 'preparing'"\s+id="toybaco-connections-preparing"\s+class="group-heading"\s*>\s*審査完了後に使えます\s*<\/h2>/
    .test(connect.slice(loop, cards)));
  assert(/:role="group\.id === 'preparing' \? 'group' : undefined"/.test(connect.slice(loop, cards)));
  assert(/:aria-labelledby="\s*group\.id === 'preparing'\s*\? 'toybaco-connections-preparing'\s*: undefined\s*"/.test(connect.slice(loop, cards)));
  for (const key of ['email_forward', 'gmail', 'microsoft', 'line', 'web_widget', 'instagram'])
    assert(connect.indexOf(`data-toybaco-connection="${key}"`) > cards, `${key} is drawn in its group`);
  assert.equal(connect.split('審査完了後に使えます').length - 1, 1);
  // LINE waiting like Web chat cannot be pressed either.
  for (const key of ['line', 'web_widget']) {
    const card = connect.slice(connect.indexOf(`data-toybaco-connection="${key}"`), connect.indexOf('</button>', connect.indexOf(`data-toybaco-connection="${key}"`)));
    assert(card.includes(`channel('${key}')?.state === 'preparing'`), `${key} is disabled while it waits`);
  }
});

test('「つないだ窓口で次へ」moves on with the connected window and never marks the step as left for later', () => {
  const connect = block(`<template v-else-if="state?.phase === 'connect'">`);
  assert(/<button\s+v-if="canProceed"\s+class="primary"\s+type="button"\s+data-toybaco-guide-next="connect"\s+data-toybaco-guide-action="connection\.next"\s+:disabled="busy"\s+@click="proceed"\s*>\s*つないだ窓口で次へ\s*<\/button>/
    .test(connect));
  // 「あとで設定する」is the main button only while no window can be guided, otherwise a secondary link.
  assert(/:class="canProceed \? 'text-button' : 'primary'"\s+data-toybaco-guide-skip="connect"\s+data-toybaco-guide-action="connection\.skip"/.test(connect));
  assert(connect.indexOf('data-toybaco-guide-next="connect"') < connect.indexOf('data-toybaco-guide-skip="connect"'));
  assert.equal(template.split('data-toybaco-guide-next="connect"').length - 1, 1);
  assert(!template.includes('この内容で次へ'));
  const script = start.slice(start.indexOf('<script setup>'), start.indexOf('</script>'));
  const proceed = script.slice(script.indexOf('function proceed()'), script.indexOf('\n}\n', script.indexOf('function proceed()')));
  assert(proceed.includes('updateGrowthGuide({ inbox_id: state.value.inbox_id ?? first.id });'));
  assert(!/skip/.test(proceed), 'moving on never records the connection step as left for later');
  // Two connected windows and none chosen yet keep the connection step; the button records the first listed one.
  const inboxes = [{ id: 5, provider: 'line', label: '店 · LINE公式' }, { id: 7, provider: 'web_widget', label: '店 · Webチャット' }];
  const sent = [];
  const two = startScript(connectState({ inboxes }), (current, body) => {
    sent.push(plain(body));
    return { ...current, phase: 'facts', inbox_id: body.preference.inbox_id };
  });
  assert.equal(two.page.canProceed.value, true);
  two.page.proceed();
  assert.deepEqual(sent, [{ preference: { inbox_id: 5 } }]);
  assert.equal(two.state.value.phase, 'facts');
  // A window already chosen for the guide is kept.
  const chosen = startScript(connectState({ inboxes, inbox_id: 7 }), (current, body) => {
    sent.push(plain(body));
    return current;
  });
  chosen.page.proceed();
  assert.deepEqual(sent.at(-1), { preference: { inbox_id: 7 } });
  // Nothing the guide can guide (for example a staff member outside every window): no button, and nothing is sent.
  const none = startScript(connectState(), (current, body) => {
    sent.push(plain(body));
    return current;
  });
  assert.equal(none.page.canProceed.value, false);
  none.page.proceed();
  assert.equal(sent.length, 2);
});

test('the pointer names the connection step and describes a card only while it is hovered or focused', () => {
  const guide = readFileSync(new URL('../overlay/app/app/javascript/dashboard/components/widgets/ToybacoGrowthGuide.vue', import.meta.url), 'utf8');
  const script = guide.slice(guide.indexOf('<script setup>'), guide.indexOf('</script>'));
  const code = script.slice(script.indexOf('const setupSteps = {'), script.indexOf('\n}\n', script.indexOf('function wantedStep()')) + 3);
  const step = '使う窓口を1つ選んでください。あとから追加できます。';
  // cards: the connection cards in page order; enabled: the ones the registry finds (drawn, not disabled).
  const pointed = ({ cards, enabled = cards, hovered = null, focused = null, administrator = true }) => JSON.parse(runInNewContext(
    `${code}\nhoveredCard = ${JSON.stringify(hovered)};\nfocusedCard = ${JSON.stringify(focused)};\nJSON.stringify(wantedStep());`, {
      supportStep: null, supportEnabled: { value: false }, accountId: { value: 1 }, paused: { value: false },
      inSetup: { value: true }, route: { params: {} }, supportGuideStep: () => null,
      state: { value: { phase: 'connect', administrator, preference: { dismissed: false } } },
      registry: { find: (id) => (enabled.includes(id) ? { id } : null) },
      document: { querySelectorAll: () => cards.map((id) => ({ dataset: { toybacoGuideAction: id } })) },
    }));
  // Staging store 14: LINE and Web chat come first; Google and Microsoft wait (disabled) below.
  const staging = { cards: ['connection.line', 'connection.web_widget', 'connection.google', 'connection.microsoft'],
    enabled: ['connection.line', 'connection.web_widget'] };
  assert.deepEqual(pointed(staging), ['connection.line', step]);
  assert.deepEqual(pointed({ ...staging, hovered: 'connection.web_widget' }), ['connection.web_widget', 'Webチャットの作成画面を開きます。']);
  assert.deepEqual(pointed({ ...staging, focused: 'connection.line' }), ['connection.line', 'LINE公式の接続設定を開きます。']);
  assert.deepEqual(pointed({ ...staging, hovered: 'connection.web_widget', focused: 'connection.line' }),
    ['connection.web_widget', 'Webチャットの作成画面を開きます。']);
  // A card that cannot be pressed never takes the prompt.
  assert.deepEqual(pointed({ ...staging, hovered: 'connection.google' }), ['connection.line', step]);
  // Once Google is open it is the first card, as before; its description still waits for hover or focus.
  assert.deepEqual(pointed({ cards: ['connection.google', 'connection.line'] }), ['connection.google', step]);
  assert.deepEqual(pointed({ cards: ['connection.google', 'connection.instagram'], focused: 'connection.instagram' }),
    ['connection.instagram', 'Instagramの接続画面を開きます。']);
  assert.equal(pointed({ ...staging, administrator: false }), null);
  // No card can be pressed (at the plan limit, or everything waiting): never Google, but the button that moves on —
  // 「つないだ窓口で次へ」when it is there, otherwise「あとで設定する」.
  const fallback = '接続はあとからでも追加できます。次へ進みましょう。';
  const blocked = { cards: ['connection.google', 'connection.microsoft', 'connection.line', 'connection.web_widget'], enabled: [] };
  assert.deepEqual(pointed({ ...blocked, enabled: ['connection.next', 'connection.skip'] }), ['connection.next', fallback]);
  assert.deepEqual(pointed({ ...blocked, enabled: ['connection.skip'] }), ['connection.skip', fallback]);
  assert.equal(pointed(blocked), null);
  // The buttons that move on are not cards: hovering one never swaps in a card description.
  assert.deepEqual(pointed({ ...staging, enabled: [...staging.enabled, 'connection.skip'], hovered: 'connection.skip' }),
    ['connection.line', step]);
  assert(script.includes(`const connectionCards = '[data-toybaco-connection][data-toybaco-guide-action]';`));
  // Every text fits the pointer prompt (PointerGuide.show accepts at most 40 characters).
  const hints = code.slice(code.indexOf('const connectionHints = {'), code.indexOf('};', code.indexOf('const connectionHints = {')));
  const moveOn = code.match(/const connectionFallback = \[\n\s+\['connection\.next', 'connection\.skip'\],\n\s+'([^']+)',\n\];/);
  assert.equal(moveOn?.[1], fallback);
  const texts = [step, ...[...hints.matchAll(/: '([^']+)',/g)].map(([, text]) => text), moveOn[1]];
  assert.equal(texts.length, 7);
  for (const text of texts) assert([...text].length <= 40, text);
  // Hover and focus are followed on the whole page and released with the guide; after a card was touched the
  // pointer stays away while only the outline and the text move.
  for (const [type, handler] of [['pointerover', 'trackConnectionHover'], ['pointerout', 'trackConnectionHover'],
    ['focusin', 'trackConnectionFocus'], ['focusout', 'trackConnectionFocus']]) {
    assert(guide.includes(`document.addEventListener('${type}', ${handler}, true);`), `${type} followed`);
    assert(guide.includes(`document.removeEventListener('${type}', ${handler}, true);`), `${type} released`);
  }
  assert(/guide\.show\(\{ actionId: step\[0\], text: step\[1\] \}\);\n\s+\/\/[^\n]*\n\s+if \(\n\s+!supportStep &&\n\s+connectionTouched &&\n\s+inSetup\.value &&\n\s+state\.value\?\.phase === 'connect'\n\s+\)\n\s+guide\.suppress\(\);/
    .test(guide));
});

test('the receive step speaks to each kind of window', () => {
  const receive = block(`<template v-else-if="state?.phase === 'receive'">`);
  assert(receive.includes('ご自身のLINEから、この公式アカウントにメッセージを送ってください。'));
  assert(receive.includes('別のメールアドレスから、次の窓口にテストメールを送ってください。'));
  const web = receive.slice(receive.indexOf(`v-else-if="selectedInbox?.provider === 'web_widget'"`),
    receive.indexOf(`v-else-if="selectedInbox?.provider === 'instagram'"`));
  assert(web.includes('サイトに設置コードを貼ると問い合わせが届きます。今すぐ試すなら、プレビューから1件送ってください。'));
  assert(/<a\s+v-if="widgetPreviewUrl"\s+class="preview-link"\s+:href="widgetPreviewUrl"\s+target="_blank"\s+rel="noopener noreferrer"\s*>プレビューで送る<\/a/.test(web));
  assert(receive.includes('接続したInstagramのDMを受け取ります。テスト用に1件送ってください。'));
  // The preview is the store's own widget on this origin, opened with its public website token.
  const receiving = (inbox) => startScript({ ...connectState({ phase: 'receive', inbox_id: 3, inboxes: [inbox] }) }, (value) => value).page;
  assert.equal(receiving({ id: 3, provider: 'web_widget', website_token: 'tok en/1' }).widgetPreviewUrl.value, '/widget?website_token=tok%20en%2F1');
  assert.equal(receiving({ id: 3, provider: 'gmail', email: 'shop@example.test' }).widgetPreviewUrl.value, '');
});

test('the completion screen makes「ホームへ」the main button and adds one next step for the connected window', () => {
  const complete = block(`<template v-else-if="state?.phase === 'complete'">`);
  assert(/<RouterLink\s+class="home-link"\s+:class="\{ secondary: state\.replied \}"/.test(complete));
  const style = start.slice(start.indexOf('<style scoped>'));
  assert(/\n\.toybaco-start \.home-link \{[^}]*min-height: 46px;[^}]*background: #1f3a5f;[^}]*color: #fff;[^}]*text-decoration: none;\n\}/.test(style));
  assert(/\n\.toybaco-start \.home-link\.secondary \{\n  background: #fff;\n  color: #1f3a5f;\n\}/.test(style));
  assert(complete.indexOf('data-toybaco-next-step') > 0 && complete.indexOf('data-toybaco-next-step') < complete.indexOf('class="home-link"'));
  assert(/<RouterLink v-if="snippetLink" :to="snippetLink"\s*>設置コードを見る<\/RouterLink/.test(complete));
  const done = (inboxes, extra = {}) => startScript(connectState({ phase: 'complete', replied: false, pending: [],
    inbox_id: inboxes[0]?.id, inboxes, ...extra }), (value) => value).page;
  const web = done([{ id: 4, provider: 'web_widget' }]);
  assert.equal(web.nextStep.value, 'Webチャットの設置コードを、お店のサイトに貼る');
  // The snippet sits in the inbox settings (configuration tab), which only administrators can open.
  assert.deepEqual(plain(web.snippetLink.value), { name: 'settings_inbox_show', params: { accountId: 1, inboxId: 4, tab: 'configuration' } });
  assert.equal(done([{ id: 4, provider: 'web_widget' }], { administrator: false }).snippetLink.value, null);
  assert.equal(done([{ id: 5, provider: 'instagram' }]).nextStep.value, 'InstagramのDMに、受信箱から返信する');
  assert.equal(done([{ id: 6, provider: 'line' }]).nextStep.value, 'LINEのメッセージに、受信箱から返信する');
  for (const provider of ['gmail', 'microsoft'])
    assert.equal(done([{ id: 7, provider }]).nextStep.value, '届いたメールに、受信箱から返信する');
  assert.equal(done([{ id: 5, provider: 'instagram' }]).snippetLink.value, null);
  // The posting purpose completes without an inbox id: the first listed window decides the line.
  assert.equal(done([{ id: 8, provider: 'web_widget' }], { inbox_id: undefined }).nextStep.value, 'Webチャットの設置コードを、お店のサイトに貼る');
  // Nothing connected: no next step (the list of what is left offers「受信箱の接続」instead).
  assert.equal(done([]).nextStep.value, '');
});

// 所見 (c)(2026-10-01 裁定): a new Web chat inbox has no AI reply (no bot). The completion screen's next step gets a
// second line to the automatic reply screen (managed auto, a Rails page); the page never assigns a bot. The line shows
// only where /toybaco/ai_readiness offers that screen for this store (managed_auto_path, the same check as the
// conversation screen's AI panel), only to administrators (the API answers any member, the screen opens for
// administrators only) and only under the first line. A failed read shows nothing and is not retried.
const readinessAnswer = (body, status = 200) => async () =>
  ({ status, ok: status >= 200 && status < 300, redirected: false, json: async () => body });
const settle = () => new Promise((resolve) => setImmediate(resolve));
const managedPath = '/toybaco/growth/automatic-replies?account_id=1';
const readinessBody = (extra = {}) =>
  ({ connection: 'unconnected', configured_inboxes: 0, total_inboxes: 1, live_verification: 'unverified', ...extra });
const finished = (answer, extra = {}, routeName = undefined) => startScript(
  connectState({ phase: 'complete', replied: false, pending: [], inbox_id: 4, inboxes: [{ id: 4, provider: 'web_widget' }], ...extra }),
  (value) => value, routeName, answer);

test('the completion screen adds「AI応答を接続する」as the second next step where the store can prepare it', async () => {
  const complete = block(`<template v-else-if="state?.phase === 'complete'">`);
  // Right after the first line and before「ホームへ」: a plain link to the Rails page, or the connected notice without one.
  const first = complete.indexOf('data-toybaco-next-step');
  const second = complete.indexOf(':data-toybaco-ai-step="aiStep.state"');
  assert(first > 0 && second > first && second < complete.indexOf('class="home-link"'));
  assert(/<p v-if="aiStep" class="next-step" :data-toybaco-ai-step="aiStep\.state">\s*<a v-if="aiStep\.href" :href="aiStep\.href"\s*>AI応答を接続する<\/a\s*><span v-else>AI応答は接続済みです<\/span>\s*<\/p>/
    .test(complete));
  assert.equal(template.split('data-toybaco-ai-step').length - 1, 1);
  // The second line continues the first line's box: it takes back the paragraph gap (20px) and its own top padding, so
  // the first line's bottom padding (12px) is the space between the lines.
  const style = start.slice(start.indexOf('<style scoped>'));
  assert(/\n\.toybaco-start p \{\n  font-size: 14px;\n  color: #566579;\n  margin: 0 0 20px;\n\}/.test(style));
  assert(/\n\.toybaco-start \.next-step \{\n[^}]*  padding: 12px 16px;\n[^}]*\}/.test(style));
  assert(/\n\.toybaco-start \.next-step \+ \.next-step \{\n  margin-top: -20px;\n  padding-top: 0;\n\}/.test(style));
  // The narrow-screen block (≤ 680px, cut at its own closing brace) changes neither box.
  const css = style.replace(/\/\*[\s\S]*?\*\//g, '');
  const narrowAt = css.indexOf('@media (max-width: 680px) {');
  assert(narrowAt >= 0, 'the narrow-screen block is there');
  let depth = 0;
  let narrowEnd = narrowAt;
  for (; narrowEnd < css.length; narrowEnd += 1) {
    if (css[narrowEnd] === '{') depth += 1;
    if (css[narrowEnd] === '}') depth -= 1;
    if (css[narrowEnd] === '}' && depth === 0) break;
  }
  const narrow = css.slice(narrowAt, narrowEnd + 1);
  assert(narrow.endsWith('}') && narrow.includes('.toybaco-start h1 {'), 'the whole narrow-screen block is read');
  assert(!narrow.includes('.next-step'), 'narrow screens keep the same box');

  // (a) The store can prepare the automatic reply and it is not answering yet: a link to the screen.
  const open = finished(readinessAnswer(readinessBody({ managed_auto_path: managedPath, managed_auto_registered: false })));
  await settle();
  assert.deepEqual(plain(open.page.aiStep.value), { state: 'connect', href: managedPath });
  assert.deepEqual(plain(open.requests), [{ url: '/toybaco/ai_readiness?account_id=1',
    options: { credentials: 'same-origin', cache: 'no-store', headers: { Accept: 'application/json' } } }]);
  // A registered installation that is not answering, and a store whose connection is unknown, also lead to the screen.
  for (const extra of [{ managed_auto_registered: true }, { connection: 'unknown' }]) {
    const run = finished(readinessAnswer(readinessBody({ managed_auto_path: managedPath, ...extra })));
    await settle();
    assert.deepEqual(plain(run.page.aiStep.value), { state: 'connect', href: managedPath }, JSON.stringify(extra));
  }
  // (b) Already answering: the line says so, without a link.
  const connected = finished(readinessAnswer(readinessBody({ connection: 'configured', configured_inboxes: 1,
    managed_auto_path: managedPath, managed_auto_registered: true })));
  await settle();
  assert.deepEqual(plain(connected.page.aiStep.value), { state: 'configured' });
  // (c) No screen offered (free or Light, store facts not confirmed, another bot already set up): no line.
  for (const body of [readinessBody(), readinessBody({ connection: 'configured', configured_inboxes: 1 })]) {
    const run = finished(readinessAnswer(body));
    await settle();
    assert.equal(run.page.aiStep.value, null, JSON.stringify(body));
  }
  // A path to another store or another page never becomes a link (the conversation screen's panel checks the same).
  for (const other of ['/toybaco/growth/automatic-replies?account_id=2', `${managedPath}&inbox_id=4`,
    `https://example.test${managedPath}`, `//example.test${managedPath}`, 'javascript:alert(1)']) {
    const run = finished(readinessAnswer(readinessBody({ managed_auto_path: other })));
    await settle();
    assert.equal(run.page.aiStep.value, null, other);
  }
  // (d) A failed read shows nothing and is asked only once: no answer from the network, a refused or failed status, an
  // answer that is not JSON, a redirected answer, and an answer whose connection the page does not know.
  const failures = [
    () => Promise.reject(new TypeError('Failed to fetch')),
    readinessAnswer({ connection: 'unknown' }, 503),
    readinessAnswer(undefined, 401),
    readinessAnswer(readinessBody({ managed_auto_path: managedPath }), 403),
    readinessAnswer(readinessBody({ managed_auto_path: managedPath }), 500),
    async () => ({ status: 200, ok: true, redirected: false, json: async () => { throw new SyntaxError('Unexpected token <'); } }),
    async () => ({ status: 200, ok: true, redirected: true, json: async () => readinessBody({ managed_auto_path: managedPath }) }),
    readinessAnswer(null),
    readinessAnswer(readinessBody({ managed_auto_path: managedPath, connection: 'ready' })),
  ];
  for (const [index, answer] of failures.entries()) {
    const run = finished(answer);
    await settle();
    assert.equal(run.page.aiStep.value, null, `failure ${index}`);
    assert.equal(run.requests.length, 1, `failure ${index}: not asked again`);
  }
  // Staff never see the line and the page does not ask (the API would answer any member of the store with the path).
  const staff = finished(readinessAnswer(readinessBody({ managed_auto_path: managedPath })), { administrator: false });
  await settle();
  assert.equal(staff.page.aiStep.value, null);
  assert.deepEqual(staff.requests, []);
  // The line itself also asks for an administrator: a read answered for an administrator is not shown once the guide
  // state says otherwise, even before the read is dropped.
  const demoted = finished(readinessAnswer(readinessBody({ managed_auto_path: managedPath })));
  await settle();
  assert.deepEqual(plain(demoted.page.aiStep.value), { state: 'connect', href: managedPath });
  demoted.state.value = { ...demoted.state.value, administrator: false };
  assert.equal(demoted.page.aiStep.value, null);
  demoted.flush();
  assert.equal(demoted.page.aiStep.value, null);
  assert.equal(demoted.requests.length, 1);
  // Without a first line (no window connected yet) there is no second line.
  const empty = finished(readinessAnswer(readinessBody({ managed_auto_path: managedPath })), { inboxes: [], inbox_id: undefined });
  await settle();
  assert.equal(empty.page.nextStep.value, '');
  assert.equal(empty.page.aiStep.value, null);
  // The settings menu's store facts page uses the same component but never shows the completion screen: nothing is read.
  const settings = finished(readinessAnswer(readinessBody({ managed_auto_path: managedPath })), {}, 'toybaco_store_facts_settings');
  await settle();
  assert.deepEqual(settings.requests, []);
  assert.equal(settings.page.aiStep.value, null);
});

test('the completion screen reads the AI readiness once on arrival and drops an answer that comes too late', async () => {
  const answers = [];
  const run = startScript(connectState({ phase: 'reply', inbox_id: 4, inboxes: [{ id: 4, provider: 'web_widget' }] }),
    (value) => value, undefined, () => new Promise((resolve) => answers.push(resolve)));
  const answer = (body) => answers.shift()({ status: 200, ok: true, redirected: false, json: async () => body });
  assert.deepEqual(run.requests, [], 'nothing is read before the completion step');
  const done = { ...run.state.value, phase: 'complete', replied: false, pending: [] };
  run.state.value = done;
  run.flush();
  assert.equal(run.requests.length, 1, 'read when the completion step arrives');
  // The guide state changes on the completion screen (a purpose read, an inbox choice) without another read.
  run.state.value = { ...done, preference: { ...done.preference, purpose: 'posting' } };
  run.flush();
  run.state.value = { ...done, inbox_id: 5, inboxes: [...done.inboxes, { id: 5, provider: 'line' }] };
  run.flush();
  run.state.value = done;
  run.flush();
  assert.equal(run.requests.length, 1);
  answer(readinessBody({ managed_auto_path: managedPath }));
  await settle();
  assert.deepEqual(plain(run.page.aiStep.value), { state: 'connect', href: managedPath });
  // Leaving the completion step drops the line; coming back reads once more.
  run.state.value = { ...done, phase: 'connect' };
  run.flush();
  assert.equal(run.page.aiStep.value, null);
  run.state.value = done;
  run.flush();
  assert.equal(run.requests.length, 2);
  // The page left and came back while that read was on the way: its answer belongs to the earlier visit and is dropped.
  run.state.value = { ...done, phase: 'connect' };
  run.flush();
  run.state.value = done;
  run.flush();
  assert.equal(run.requests.length, 3);
  answer(readinessBody({ managed_auto_path: managedPath }));
  await settle();
  assert.equal(run.page.aiStep.value, null, 'the answer to the earlier visit is dropped');
  answer(readinessBody({ connection: 'configured', configured_inboxes: 1, managed_auto_path: managedPath, managed_auto_registered: true }));
  await settle();
  assert.deepEqual(plain(run.page.aiStep.value), { state: 'configured' });
  // The read never writes to the console. The page writes nothing for the AI (it never assigns a bot): its only fetch is
  // this read, a GET without a body (the options are checked above).
  const script = start.slice(start.indexOf('<script setup>'), start.indexOf('</script>'));
  assert(!script.includes('console.'));
  assert.equal(script.split('fetch(').length - 1, 1, 'one fetch: the AI readiness');
});

// 2026-10-04 の裁定: a store that left its facts for later confirms them from the completion screen (「店舗情報 /
// 入力する」). The automatic reply needs confirmed facts, so the save can make the screen available: back on the completion
// screen the page reads the AI readiness once more. Other changes there (purpose, inbox choice) still read nothing.
test('saving the store facts on the completion screen reads the AI readiness once more and shows the line it now offers', async () => {
  const unconfirmed = () => connectState({ phase: 'complete', replied: false, pending: ['facts'], inbox_id: 4,
    inboxes: [{ id: 4, provider: 'web_widget' }] });
  const save = (current, body) => (body.fields ? { ...current, pending: [] } : current);
  for (const flushFirst of [true, false]) {
    const answers = [];
    const run = startScript(unconfirmed(), save, undefined, () => new Promise((resolve) => answers.push(resolve)));
    run.server.flushFirst = flushFirst;
    const answer = (body) => answers.shift()({ status: 200, ok: true, redirected: false, json: async () => body });
    // Not confirmed yet: the store cannot prepare the automatic reply, so there is no line.
    assert.equal(run.requests.length, 1);
    answer(readinessBody());
    await settle();
    assert.equal(run.page.aiStep.value, null);
    // 「入力する」opens the form in place of the completion screen; nothing is read while it is open.
    run.page.openFacts();
    run.flush();
    assert.equal(run.page.showFacts.value, true);
    assert.equal(run.requests.length, 1);
    // The save brings the completion screen back and reads once more; the store can now prepare it, so the line shows.
    await run.page.saveFacts();
    run.flush();
    assert.equal(run.page.showFacts.value, false);
    assert.equal(run.requests.length, 2, `flushFirst=${flushFirst}: read once more after the save`);
    answer(readinessBody({ managed_auto_path: managedPath, managed_auto_registered: false }));
    await settle();
    assert.deepEqual(plain(run.page.aiStep.value), { state: 'connect', href: managedPath });
    run.flush();
    assert.equal(run.requests.length, 2, 'only once');
  }
  // A failed read after the save shows nothing and is not tried again, as on arrival.
  const replies = [readinessAnswer(readinessBody()), () => Promise.reject(new TypeError('Failed to fetch'))];
  const failed = startScript(unconfirmed(), save, undefined, (...args) => replies.shift()(...args));
  await settle();
  failed.page.openFacts();
  failed.flush();
  await failed.page.saveFacts();
  failed.flush();
  await settle();
  assert.equal(failed.page.aiStep.value, null);
  failed.flush();
  assert.equal(failed.requests.length, 2);
});

// Back from the automatic reply screen (a plain link), the browser may restore this page as it was (back-forward cache):
// the completion screen reads once more. A page that left takes no late answer and stops listening.
test('a page restored from the back-forward cache reads the AI readiness once more, and a page that left takes no answer', async () => {
  const answers = [];
  const run = finished(() => new Promise((resolve) => answers.push(resolve)));
  const answer = (body) => answers.shift()({ status: 200, ok: true, redirected: false, json: async () => body });
  answer(readinessBody({ managed_auto_path: managedPath }));
  await settle();
  run.pageshow(false);
  assert.equal(run.requests.length, 1, 'a page that was not restored is not read again');
  run.pageshow(true);
  assert.equal(run.requests.length, 2, 'restored on the completion screen: read once more');
  answer(readinessBody({ connection: 'configured', configured_inboxes: 1, managed_auto_path: managedPath, managed_auto_registered: true }));
  await settle();
  assert.deepEqual(plain(run.page.aiStep.value), { state: 'configured' });
  run.page.openFacts();
  run.flush();
  run.pageshow(true);
  assert.equal(run.requests.length, 2, 'restored on another screen: nothing is read');
  run.page.factsRequested.value = false;
  run.flush();
  assert.equal(run.requests.length, 3);
  run.unmount();
  answer(readinessBody({ managed_auto_path: managedPath }));
  await settle();
  assert.equal(run.page.aiStep.value, null, 'the answer that arrives after the page left is dropped');
  run.pageshow(true);
  assert.equal(run.requests.length, 3, 'the page stopped listening when it left');
});

test('the inbox finish screen leads back to the store setup while the guide is not complete', () => {
  const finish = readFileSync(new URL('../overlay/app/app/javascript/dashboard/routes/dashboard/settings/inbox/FinishSetup.vue', import.meta.url), 'utf8');
  assert(/const growthGuideOpen = computed\(\s*\(\) =>\s*currentAccount\.value\?\.toybaco_growth_onboarding === true &&\s*Boolean\(growthGuideState\.value\) &&\s*growthGuideState\.value\.phase !== 'complete'\s*\);/.test(finish));
  assert(/<div v-if="growthGuideOpen" class="flex justify-center mt-6">\s*<NextButton\s+solid\s+label="お店の準備に戻る"\s+data-toybaco-guide-return\s+@click="returnToGrowthGuide"\s*\/>\s*<\/div>/.test(finish));
  const back = finish.slice(finish.indexOf('async function returnToGrowthGuide()'), finish.indexOf('\n}\n', finish.indexOf('async function returnToGrowthGuide()')));
  assert(back.includes('await updateGrowthGuide({ dismissed: false });'));
  assert(/router\.push\(\{\s*name: 'toybaco_growth_start',\s*params: \{ accountId: accountId\.value \},\s*\}\);/.test(back));
  // The banner「設定を続ける」opens the same screen the same way.
  const guide = readFileSync(new URL('../overlay/app/app/javascript/dashboard/components/widgets/ToybacoGrowthGuide.vue', import.meta.url), 'utf8');
  const resume = guide.slice(guide.indexOf('async function resume()'), guide.indexOf('\n}\n', guide.indexOf('async function resume()')));
  assert(resume.includes('await updateGrowthGuide({ dismissed: false });') && resume.includes("name: 'toybaco_growth_start',"));
});

// U4: at the mobile width (≤ 680px) the connection step's prompt is two lines (2 × 22.4px + padding, border and
// 「あとで続ける」= 104.8px, headless Chrome at 390 and 375 wide). The page keeps two lines there in advance, so the
// cards never move down when the prompt appears (A10). Wider screens keep the one-line place.
test('the connection step keeps two lines for its prompt at the mobile width so the cards never move', () => {
  const style = start.slice(start.indexOf('<style scoped>'));
  const mobile = style.slice(style.indexOf('@media (max-width: 680px) {'));
  const kept = mobile.match(/\n  \.toybaco-start\.connect-step \[data-toybaco-guide-slot\]\.reserved \{\n    min-height: (\d+)px;\n  \}/);
  assert(kept, 'the connection step keeps a two-line place on narrow screens');
  assert.equal(Number(kept[1]), slotPlacement({ left: 0, top: 0, width: 316 }, { height: 104.8 }).reserve);
  assert(!style.slice(0, style.indexOf('@media (max-width: 680px) {')).includes('.connect-step'), 'wide screens keep one line');
  assert(/'connect-step': !settingsView && !showFacts && state\?\.phase === 'connect',/.test(template));
});

// U5 (2026-09-29, staging store 15): the conversation screen's AI panel (toybaco-post-entry.js) keeps the AI usage it
// read at login. Saving the store facts names the store that saved them (toybaco:store-facts-saved), so the panel reads
// that store's usage again instead of keeping「店舗情報を確認すると自動応答を設定できます。」until a reload.
function guideComposable(respond) {
  const source = readFileSync(new URL('../overlay/app/app/javascript/dashboard/composables/toybacoGrowthGuide.js', import.meta.url), 'utf8')
    .replace("import { ref } from 'vue';", 'const ref = (value) => ({ value });')
    .replace(/^export /gm, '');
  assert(!/^import /m.test(source), 'every import is replaced');
  const events = [];
  const requests = [];
  const answers = [];
  const api = runInNewContext(`${source}\n({ selectGrowthGuideAccount, saveGrowthFacts, updateGrowthGuide, growthGuideError });`, {
    AbortController,
    CustomEvent: class { constructor(type, init) { this.type = type; this.detail = init?.detail; } },
    window: { dispatchEvent: (event) => { events.push(plain({ type: event.type, detail: event.detail })); return true; } },
    // Each request waits until the test answers it, so a store can change while a save is on the way.
    fetch: (url, options) => {
      requests.push({ url, method: options.method, body: options.body && JSON.parse(options.body) });
      return new Promise((resolve) => answers.push(() => resolve(respond(url, options))));
    },
  });
  const answer = async () => { answers.shift()(); for (let i = 0; i < 10; i += 1) await Promise.resolve(); };
  return { api, events, requests, answer };
}
const guideResponse = (status, body = {}) => ({ status, ok: status >= 200 && status < 300, redirected: false, json: async () => body });

test('saving the store facts tells the AI panel which store saved them, only when the save succeeded', async () => {
  const saved = guideComposable(() => guideResponse(200, { account_id: 15, phase: 'receive' }));
  saved.api.selectGrowthGuideAccount(15);
  const pending = saved.api.saveGrowthFacts({ name: 'トイバコ食堂' });
  assert.deepEqual(saved.events, [], 'nothing is announced before the server answers');
  await saved.answer();
  assert.equal((await pending).phase, 'receive', 'the page still gets the saved guide state');
  assert.deepEqual(saved.requests, [{ url: '/toybaco/growth/facts?account_id=15', method: 'PUT',
    body: { fields: { name: 'トイバコ食堂' }, confirmed: true } }]);
  assert.deepEqual(saved.events, [{ type: 'toybaco:store-facts-saved', detail: { accountId: '15' } }]);

  // A refused or failed save announces nothing (the facts are unchanged on the server).
  for (const status of [401, 403, 404, 422, 500]) {
    const refused = guideComposable(() => guideResponse(status, { error: '店舗情報の入力内容を確認してください。' }));
    refused.api.selectGrowthGuideAccount(15);
    const result = refused.api.saveGrowthFacts({ name: 'トイバコ食堂' });
    await refused.answer();
    assert.equal(await result, undefined, `${status}: the page keeps the form`);
    assert.notEqual(refused.api.growthGuideError.value, '', `${status}: the page shows the error`);
    assert.deepEqual(refused.events, [], `${status}: nothing is announced`);
  }

  // The store changed while the save was on the way, or the answer belongs to another store: the page ignores the
  // answer and nothing is announced for the store now on screen.
  const moved = guideComposable(() => guideResponse(200, { account_id: 15, phase: 'receive' }));
  moved.api.selectGrowthGuideAccount(15);
  const late = moved.api.saveGrowthFacts({ name: 'トイバコ食堂' });
  moved.api.selectGrowthGuideAccount(16);
  await moved.answer();
  assert.equal(await late, null);
  assert.deepEqual(moved.events, []);
  const foreign = guideComposable(() => guideResponse(200, { account_id: 16, phase: 'receive' }));
  foreign.api.selectGrowthGuideAccount(15);
  const other = foreign.api.saveGrowthFacts({ name: 'トイバコ食堂' });
  await foreign.answer();
  assert.equal(await other, null);
  assert.deepEqual(foreign.events, []);

  // Guide choices are not store facts, and nothing is sent without a store.
  const choice = guideComposable(() => guideResponse(200, { account_id: 15, phase: 'connect' }));
  choice.api.selectGrowthGuideAccount(15);
  const chosen = choice.api.updateGrowthGuide({ purpose: 'inbox' });
  await choice.answer();
  await chosen;
  assert.equal(choice.requests[0].url, '/toybaco/growth/onboarding?account_id=15');
  assert.deepEqual(choice.events, []);
  const none = guideComposable(() => guideResponse(200, { account_id: 15 }));
  assert.equal(await none.api.saveGrowthFacts({ name: 'トイバコ食堂' }), undefined);
  assert.deepEqual([none.requests, none.events], [[], []]);
});
