import fs from 'node:fs';
import vm from 'node:vm';
import { webcrypto } from 'node:crypto';
import assert from 'node:assert/strict';
import test from 'node:test';

const root = new URL('../', import.meta.url);
const read = path => fs.readFileSync(new URL(path, root), 'utf8');
const helper = read('overlay/app/app/javascript/dashboard/helper/toybacoManualDraft.js');
const sandbox = { crypto: webcrypto, TextEncoder, URLSearchParams };
vm.runInNewContext(helper.replaceAll('export ', '') +
  '\nthis.api = { canApplyDraft, digestDraft, draftEndpoint, draftError, draftFactsChanged, draftFactsLine, draftPending };', sandbox);
const api = sandbox.api;

test('only a current, authorized result for the exact draft and question can be adopted', async () => {
  const digest = await api.digestDraft('入力中の文章');
  const result = { state: 'completed', current: true, content: '返信案', incoming_id: 10, draft_digest: digest };
  const context = { incomingId: '10', digest, canEdit: true };
  assert.equal(api.canApplyDraft(result, context), true);
  for (const change of [{ state: 'running' }, { current: false }, { incoming_id: 11 }, { content: '' }, { content: '字'.repeat(1601) }]) {
    assert.equal(api.canApplyDraft({ ...result, ...change }, context), false);
  }
  assert.equal(api.canApplyDraft(result, { ...context, digest: await api.digestDraft('編集後') }), false);
  assert.equal(api.canApplyDraft(result, { ...context, canEdit: false }), false);
  assert.equal(api.draftPending({ state: 'queued' }), true);
  assert.equal(api.draftPending(result), false);
});

test('endpoints stay within an explicit store and conversation', () => {
  assert.equal(api.draftEndpoint(4, 8, 12), '/toybaco/growth/drafts?account_id=4&conversation_id=8&request_id=12');
  for (const id of ['', 0, -1, '4&account_id=9', '../4']) assert.equal(api.draftEndpoint(id, 8), null);
});

const reply = read('overlay/app/app/javascript/dashboard/components/widgets/conversation/ReplyBox.vue');
const method = reply.slice(reply.indexOf('    applyToybacoManualDraft(candidate) {'), reply.indexOf('    addIntoEditor(content) {'));
const apply = vm.runInNewContext('({' + method + '}).applyToybacoManualDraft', { useAlert: () => {} });

test('applying an AI result preserves human edits and cannot cross conversations or notes', () => {
  const candidate = { content: '<img src=x onerror=alert(1)>', expectedDraft: '元の文', accountId: 4, conversationId: 8, incomingId: 10 };
  const inserted = [];
  const context = { isEditorDisabled: false, canSendPublicReply: true, isPrivate: false, hasAttachments: false, accountId: '4',
    currentChat: { id: 8 }, toybacoLatestIncomingId: 10, message: '元の文', messageEditor: { replaceToybacoDraft: (...args) => { inserted.push(args); return true; } } };
  apply.call(context, candidate);
  assert.deepEqual(inserted, [[candidate.content, candidate.expectedDraft]]);
  for (const change of [{ accountId: 5 }, { currentChat: { id: 9 } }, { toybacoLatestIncomingId: 11 }, { message: '編集を続けた文' },
    { isPrivate: true }, { hasAttachments: true }, { isEditorDisabled: true }, { canSendPublicReply: false }]) apply.call({ ...context, ...change }, candidate);
  assert.equal(inserted.length, 1);
});

test('editor inserts plain text nodes, keeps undo history, and refuses stale or media-bearing input', () => {
  const editor = read('overlay/app/app/javascript/dashboard/components/widgets/WootWriter/Editor.vue');
  const body = editor.slice(editor.indexOf('function replaceToybacoDraft('), editor.indexOf('defineExpose('));
  let media = false, focused = 0;
  const transactions = [];
  const props = { modelValue: '元の文', disabled: false };
  const state = { doc: { content: { size: 9 }, descendants: cb => { if (media) cb({ type: { name: 'image' } }); } },
    schema: { text: value => ({ text: value }), nodes: { paragraph: { create: (_, node) => ({ paragraph: node }) } } },
    tr: { replaceWith: (from, to, nodes) => ({ from, to, nodes }) } };
  const context = { props, contentFromEditor: () => props.modelValue, editorView: { state, dispatch: tx => transactions.push(tx), focus: () => focused++ } };
  vm.runInNewContext(body + '\nthis.replace = replaceToybacoDraft;', context);
  assert.equal(context.replace('<script>bad()</script>\n本文', '元の文'), true);
  assert.equal(transactions[0].nodes[0].paragraph.text, '<script>bad()</script>');
  assert.equal(transactions[0].nodes[1].paragraph.text, '本文');
  assert.equal(focused, 1);
  assert.equal(context.replace('案', '古い入力'), false);
  media = true;
  assert.equal(context.replace('案', '元の文'), false);
  media = false; props.disabled = true;
  assert.equal(context.replace('案', '元の文'), false);
  assert.equal(transactions.length, 1);
});

// U5 (2026-09-29, staging store 15): a reply draft is made by a Sidekiq job (Bedrock, read timeout 40 s, no retry) and
// can take over a minute. The waiting text follows the time, and one failed status read no longer stops the panel:
// a network error or a 5xx is read again with a backoff (at most 10 s, 8 times in a row). 401/403 still stop it.
// The component script runs with a minimal Vue stand-in, fake timers and a fake clock.
const panelSource = read('overlay/app/app/javascript/dashboard/components/widgets/conversation/ToybacoManualDraft.vue');
const panelTemplate = panelSource.slice(panelSource.indexOf('<template>'), panelSource.lastIndexOf('</template>'));
const answer = (status, body) => ({ status, ok: status >= 200 && status < 300, json: async () => body });
const htmlError = status => ({ status, ok: false, json: async () => { throw new SyntaxError('Unexpected token <'); } });
const settle = () => new Promise(resolve => setImmediate(resolve));
function draftPanel(respond, props = {}, context = {}) {
  const script = panelSource.slice(panelSource.indexOf('<script setup>') + '<script setup>'.length, panelSource.indexOf('</script>'));
  const body = script.replace(/import\s+(\{[^}]*\})\s+from\s+'([^']+)';/g, (_, names, from) => `const ${names} = modules[${JSON.stringify(from)}];`);
  assert(!/^import /m.test(body), 'every import is replaced');
  const clock = { now: 1_000_000 };
  const timers = new Map();
  let lastTimer = 0;
  const requests = [];
  const shared = { accountId: 4, conversationId: 8, incomingId: 10, draft: '', canEdit: true, ...props };
  // Like Vue: `rerun` calls a watcher again when its source changed (a list changes when one of its values does).
  const watchers = [];
  const unmounts = [];
  const emitted = [];
  const same = (a, b) => (Array.isArray(a) ? a.every((value, index) => Object.is(value, b[index])) : Object.is(a, b));
  const rerun = () => watchers.forEach((watcher) => {
    const value = watcher.source();
    if (same(value, watcher.last)) return;
    watcher.last = value;
    watcher.callback(value);
  });
  const modules = {
    vue: {
      ref: value => ({ value }),
      computed: get => ({ get value() { return get(); } }),
      watch: (source, callback, options = {}) => {
        const watcher = { source, callback, last: source() };
        watchers.push(watcher);
        if (options.immediate) callback(watcher.last);
      },
      onBeforeUnmount(hook) { unmounts.push(hook); },
    },
    'dashboard/helper/toybacoManualDraft': api,
    // The growth guide state (the onboarding JSON) the panel compares the store facts revision with.
    'dashboard/composables/toybacoGrowthGuide': { growthGuideState: context.guide || { value: null } },
  };
  const panel = vm.runInNewContext(`${body};\n({ refresh, generate, cancel, pending, pendingText, checkable, error, uncertain, available, result, remaining, narrow, expanded, toggleExpanded, botDraftLocked, botDraftHint, factsLine, factsChanged });`, {
    modules,
    defineProps: () => shared,
    defineEmits: () => (...args) => emitted.push(args),
    fetch: async (url, options) => { requests.push({ url, method: options.method }); return respond(options.method, url, requests.length); },
    setTimeout: (fn, ms) => { lastTimer += 1; timers.set(lastTimer, { fn, ms }); return lastTimer; },
    clearTimeout: id => timers.delete(id),
    Date: { now: () => clock.now },
    AbortSignal: { timeout: () => undefined },
    crypto: { randomUUID: () => '9f1c2b6e-2f7a-4c1e-9a53-0d6f4d1f6a10' },
    ...context,
  });
  // The panel keeps at most one read waiting; `poll` runs it and returns its delay.
  const waiting = () => [...timers.values()].map(timer => timer.ms);
  const poll = async (at) => {
    assert.equal(timers.size, 1, 'one read is waiting');
    const [[id, timer]] = timers;
    timers.delete(id);
    if (at !== undefined) clock.now = 1_000_000 + at * 1000;
    timer.fn();
    await settle();
    return timer.ms;
  };
  const unmount = () => unmounts.forEach(hook => hook());
  return { panel, clock, waiting, poll, requests, props: shared, rerun, timers, emitted, unmount };
}
const QUEUED = { id: 21, state: 'queued', draft_digest: 'd', incoming_id: 10 };
const status = (result, extra = {}) => answer(200, { available: true, remaining: 5, result, ...extra });

test('the waiting text follows the time and offers「状況を確認」after a minute', async () => {
  let latest = null;
  const { panel, poll, waiting } = draftPanel(method => (method === 'POST' ? answer(202, QUEUED) : status(latest)));
  await settle();
  assert.equal(panel.available.value, true);
  await panel.generate();
  latest = QUEUED;
  assert.equal(panel.pending.value, true);
  assert.deepEqual(waiting(), [1800]);
  const seen = [];
  for (const at of [9, 10, 59, 60, 75]) {
    assert.equal(await poll(at), 1800);
    seen.push([at, panel.pendingText.value, panel.checkable.value]);
  }
  assert.deepEqual(seen, [
    [9, '返信案を作成中…', false],
    [10, '作成に時間がかかっています。入力は続けられます。', false],
    [59, '作成に時間がかかっています。入力は続けられます。', false],
    [60, '時間がかかっています。「状況を確認」で最新の状況を読み直すか、そのまま入力を続けてください。', true],
    [75, '時間がかかっています。「状況を確認」で最新の状況を読み直すか、そのまま入力を続けてください。', true],
  ]);
  assert(!panelSource.includes('もう少しで完了します'), 'no promise that it is almost done');
  // The page shows that text while the draft is being made. One「状況を確認」sits outside the status lines (so it is not
  // read aloud with them) and shows from a minute on, or once the reads stopped.
  assert(panelTemplate.includes('<p v-if="pending" role="status">{{ pendingText }}</p>'));
  assert(panelTemplate.includes('<button v-if="checkable" type="button" class="toybaco-manual-ai__quiet toybaco-manual-ai__check" @click="refresh()">状況を確認</button>'));
  assert.equal(panelTemplate.split('>状況を確認</button>').length - 1, 1, 'one「状況を確認」');
  const statusLines = [...panelTemplate.matchAll(/<p\b[^>]*role="status"[^>]*>([\s\S]*?)<\/p>/g)].map(([, line]) => line);
  // 作成中・返信欄に入れた(返信案)・返信欄に入れた(ボットの案)・エラー・店舗情報の更新(段 1b-1)の5行。
  assert.equal(statusLines.length, 5);
  for (const line of statusLines) assert(!line.includes('<button'), `no button inside a status line: ${line}`);
  latest = { ...QUEUED, state: 'completed', content: '返信案', current: true };
  await poll(80);
  assert.equal(panel.pending.value, false);
  assert.deepEqual(waiting(), [], 'a finished draft is not read again');

  // A panel opened again while a draft is on the way does not know when it started: it counts from the first read.
  const reopened = draftPanel(() => status({ ...QUEUED, state: 'running' }));
  await settle();
  assert.equal(reopened.panel.pendingText.value, '返信案を作成中…');
  await reopened.poll(10);
  assert.equal(reopened.panel.pendingText.value, '作成に時間がかかっています。入力は続けられます。');
});

test('a failed status read keeps the panel reading with a backoff, then stops with「状況を確認」', async () => {
  const replies = [];
  const { panel, poll, waiting } = draftPanel((method) => {
    if (method === 'POST') return answer(202, QUEUED);
    const next = replies.shift() || status(QUEUED);
    if (next instanceof Error) throw next;
    return next;
  });
  await settle();
  await panel.generate();
  // Network down, the load balancer's HTML 503/502, a JSON 500 and a timeout: each is read again, twice as late,
  // at most 10 seconds later. Nothing alarming is shown while it is read again.
  replies.push(new TypeError('Failed to fetch'), htmlError(503), htmlError(502), answer(500, { error: 'x' }),
    new DOMException('signal timed out', 'TimeoutError'));
  const delays = [];
  for (let i = 0; i < 5; i += 1) {
    await poll();
    delays.push(...waiting());
    assert.equal(panel.error.value, '');
    assert.equal(panel.uncertain.value, false);
    assert.equal(panel.checkable.value, false, 'reading again on its own: no button needed yet');
  }
  assert.deepEqual(delays, [3600, 7200, 10000, 10000, 10000]);
  // Read again: the usual interval comes back.
  await poll();
  assert.deepEqual(waiting(), [1800]);
  assert.equal(panel.pending.value, true);

  // Eight reads again in a row, then the panel stops and says so, with「状況を確認」.
  for (let i = 0; i < 9; i += 1) replies.push(new TypeError('Failed to fetch'));
  const backoff = [];
  for (let i = 0; i < 9; i += 1) { await poll(); backoff.push(...waiting()); }
  assert.deepEqual(backoff, [3600, 7200, 10000, 10000, 10000, 10000, 10000, 10000]);
  assert.deepEqual(waiting(), [], 'the reads stop after eight tries in a row');
  assert.equal(panel.error.value, '作成状況を確認できません。再接続後に確認できます。');
  assert.equal(panel.uncertain.value, true);
  assert.equal(panel.pending.value, true);
  assert.equal(panel.checkable.value, true, '「状況を確認」stays on screen after the reads stopped');
  // 「状況を確認」 reads once more; once it can read, the message leaves and the panel follows the draft again.
  await panel.refresh();
  assert.equal(panel.error.value, '');
  assert.equal(panel.uncertain.value, false);
  assert.deepEqual(waiting(), [1800]);
});

test('401 and 403 stop the panel, and a refused read or a failed draft is not read again', async () => {
  for (const code of [401, 403]) {
    let reads = 0;
    const { panel, poll, waiting, requests } = draftPanel((method) => {
      if (method === 'POST') return answer(202, QUEUED);
      reads += 1;
      return reads === 1 ? status(null) : answer(code, {});
    });
    await settle();
    await panel.generate();
    await poll();
    assert.deepEqual(waiting(), [], `${code}: no read is waiting`);
    assert.equal(panel.available.value, false, `${code}: the panel closes`);
    assert.equal(panel.result.value, null);
    assert.equal(requests.filter(call => call.method === 'GET').length, 2, `${code}: read once, not again`);
  }
  // Any other 4xx is not a passing failure: the reads stop with the message, as before.
  for (const reply of [answer(409, { error: '入力内容が変わりました。' }), answer(429, {}), htmlError(400)]) {
    let reads = 0;
    const { panel, poll, waiting } = draftPanel((method) => {
      if (method === 'POST') return answer(202, QUEUED);
      reads += 1;
      return reads === 1 ? status(null) : reply;
    });
    await settle();
    await panel.generate();
    await poll();
    assert.deepEqual(waiting(), [], `${reply.status}: no read is waiting`);
    assert.equal(panel.error.value, '作成状況を確認できません。再接続後に確認できます。');
  }
  // The job said it failed: the panel shows why and stops reading.
  let reads = 0;
  const failed = draftPanel((method) => {
    if (method === 'POST') return answer(202, QUEUED);
    reads += 1;
    return status(reads === 1 ? null : { ...QUEUED, state: 'failed', error_code: 'expired' });
  });
  await settle();
  await failed.panel.generate();
  await failed.poll();
  assert.deepEqual(failed.waiting(), []);
  assert.equal(failed.panel.error.value, '作成を完了できませんでした。AI枠は消費していません。');
});

test('the sentence beside the adopt button reads as guidance and matches the button', () => {
  const actions = panelTemplate.slice(panelTemplate.indexOf('<div v-else class="toybaco-manual-ai__actions">'), panelTemplate.indexOf('</div>', panelTemplate.indexOf('<div v-else class="toybaco-manual-ai__actions">')));
  assert(actions.includes("<span v-else>{{ draft.trim() ? '内容を確認してから、返信欄をこの案に置き換えてください。' : '内容を確認してから、返信欄に入れてください。' }}</span>"));
  assert(actions.includes("{{ draft.trim() ? '返信欄をこの案に置き換える' : '返信欄に入れる' }}"));
  assert(!panelTemplate.includes('内容を確認してから送信<'), 'no label-like fragment next to the button');
});

// U5-R (Astra review): 「状況を確認」 can be pressed while an automatic read is on the way. Every read starts from
// refresh(): it cancels the read waiting on the timer, only the successful answer of the read started last counts,
// and any refusal (401/403/404) in the same conversation closes it. `later()` lets tests decide the order of answers.
function later() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
const RUNNING = { ...QUEUED, state: 'running' };
const DONE = { ...QUEUED, state: 'completed', content: '返信案', current: true };
function orderedPanel(gets, extra = {}) {
  const panel = draftPanel((method, url, index) => {
    if (method === 'POST') return answer(202, QUEUED);
    if (method === 'DELETE') return extra.delete;
    return gets.shift();
  });
  panel.reads = () => panel.requests.filter(call => call.method === 'GET').length;
  return panel;
}

test('a refused「状況を確認」closes the panel for good, even when the automatic read answers afterwards', async () => {
  const automatic = later();
  const { panel, poll, waiting, reads } = orderedPanel([status(null), automatic.promise, answer(403, {})]);
  await settle();
  await panel.generate();
  await poll(); // the automatic read is on the way
  await panel.refresh(); // 「状況を確認」 is refused
  assert.equal(panel.available.value, false);
  automatic.resolve(status(RUNNING)); // the older automatic read answers afterwards
  await settle();
  assert.equal(panel.available.value, false, 'the late answer never reopens the panel');
  assert.equal(panel.result.value, null);
  assert.deepEqual(waiting(), [], 'the automatic reads do not come back');
  assert.equal(reads(), 3, 'no further read');

  // A cancel still on the way when a read is refused does not bring the panel back or read again either.
  const deleting = later();
  const cancelled = orderedPanel([status(null), answer(403, {})], { delete: deleting.promise });
  await settle();
  await cancelled.panel.generate();
  const stopping = cancelled.panel.cancel(); // 「中止」 is on the way when the automatic read is refused
  await cancelled.poll();
  assert.equal(cancelled.panel.available.value, false);
  deleting.resolve(answer(200, { ...QUEUED, state: 'failed', error_code: 'cancelled' }));
  await stopping;
  await settle();
  assert.equal(cancelled.panel.available.value, false);
  assert.equal(cancelled.panel.result.value, null);
  assert.deepEqual(cancelled.waiting(), []);
  assert.equal(cancelled.reads(), 2, 'the cancel does not read again after the refusal');
});

test('a finished draft stays when an older read answers "running" afterwards', async () => {
  const automatic = later();
  const { panel, poll, waiting, reads } = orderedPanel([status(null), automatic.promise, status(DONE)]);
  await settle();
  await panel.generate();
  await poll(); // the automatic read is on the way
  await panel.refresh(); // 「状況を確認」 finds the finished draft
  assert.equal(panel.result.value.state, 'completed');
  automatic.resolve(status(RUNNING));
  await settle();
  assert.equal(panel.result.value.state, 'completed', 'the older "running" never rolls the finished draft back');
  assert.equal(panel.result.value.content, '返信案');
  assert.equal(panel.pending.value, false);
  assert.deepEqual(waiting(), [], 'a finished draft is not read again');
  assert.equal(reads(), 3);
});

test('pressing「状況を確認」cancels the read waiting on the timer, and a refused or rejected read leaves none', async () => {
  for (const reply of [answer(403, {}), answer(401, {}), answer(409, { error: '入力内容が変わりました。' })]) {
    const { panel, waiting, reads } = orderedPanel([status(null), reply]);
    await settle();
    await panel.generate();
    assert.deepEqual(waiting(), [1800], 'the next automatic read waits on the timer');
    const pressed = panel.refresh();
    assert.deepEqual(waiting(), [], `${reply.status}: pressing「状況を確認」cancels the waiting read at once`);
    await pressed;
    await settle();
    assert.deepEqual(waiting(), [], `${reply.status}: no read is left waiting`);
    assert.equal(reads(), 2, `${reply.status}: no further read`);
  }
});

test('when reads answer out of order, only the read started last counts', async () => {
  for (const older of ['answer', 'network error']) {
    const automatic = later();
    const pressedRead = later();
    const { panel, poll, waiting, reads } = orderedPanel([status(null), automatic.promise, pressedRead.promise]);
    await settle();
    await panel.generate();
    await poll(); // the automatic read (started first) is on the way
    const pressed = panel.refresh(); // 「状況を確認」 (started last)
    pressedRead.resolve(status(RUNNING, { remaining: 4 }));
    await pressed;
    assert.equal(panel.result.value.state, 'running');
    assert.equal(panel.remaining.value, 4);
    assert.deepEqual(waiting(), [1800]);
    // The read started first answers last: its answer or failure changes nothing.
    if (older === 'answer') automatic.resolve(status(QUEUED, { remaining: 5 }));
    else automatic.reject(new TypeError('Failed to fetch'));
    await settle();
    assert.equal(panel.result.value.state, 'running', `${older}: the older read is ignored`);
    assert.equal(panel.remaining.value, 4, `${older}: the older count is ignored`);
    assert.deepEqual(waiting(), [1800], `${older}: the waiting read keeps its usual interval`);
    assert.equal(panel.error.value, '');
    assert.equal(reads(), 3);
  }
});

test('an older automatic refusal clears a completed draft shown by a newer read', async (t) => {
  for (const code of [403, 401, 404]) {
    await t.test(`${code} closes the panel and clears the draft`, async () => {
      const automatic = later();
      const { panel, poll, waiting, reads } = orderedPanel([status(null), automatic.promise, status(DONE)]);
      await settle();
      await panel.generate();
      await poll(); // the automatic read is on the way
      await panel.refresh(); // 「状況を確認」 finds the finished draft first
      assert.equal(panel.result.value.state, 'completed');
      assert.equal(reads(), 3);
      automatic.resolve(answer(code, {})); // the older read is refused afterwards
      await settle();
      assert.equal(panel.available.value, false, 'the refusal closes the panel');
      assert.equal(panel.result.value, null, 'the finished draft is cleared');
      assert.deepEqual(waiting(), [], 'no automatic read is waiting');
      assert.equal(reads(), 3, 'no further read');
    });
  }
});

test('an older automatic refusal cancels polling after a newer read showed running', async () => {
  const automatic = later();
  const { panel, poll, waiting, reads } = orderedPanel([status(null), automatic.promise, status(RUNNING)]);
  await settle();
  await panel.generate();
  await poll();
  await panel.refresh();
  assert.equal(panel.result.value.state, 'running');
  assert.deepEqual(waiting(), [1800], 'the newer read schedules another automatic read');
  assert.equal(reads(), 3);
  automatic.resolve(answer(403, {}));
  await settle();
  assert.equal(panel.available.value, false, 'the refusal closes the panel');
  assert.equal(panel.result.value, null);
  assert.deepEqual(waiting(), [], 'the scheduled read is cancelled');
  assert.equal(reads(), 3, 'no further read');
});

test('an older automatic refusal keeps the panel closed when a newer read completes afterwards', async () => {
  const automatic = later();
  const pressedRead = later();
  const { panel, poll, waiting, reads } = orderedPanel([status(null), automatic.promise, pressedRead.promise]);
  await settle();
  await panel.generate();
  await poll();
  const pressed = panel.refresh(); // both reads are on the way
  assert.equal(reads(), 3);
  automatic.resolve(answer(403, {})); // the older read is refused first
  await settle();
  assert.equal(panel.available.value, false, 'the refusal closes the panel immediately');
  assert.equal(panel.result.value, null);
  assert.deepEqual(waiting(), []);
  pressedRead.resolve(status(DONE));
  await pressed;
  await settle();
  assert.equal(panel.available.value, false, 'the later success never reopens the panel');
  assert.equal(panel.result.value, null, 'the later success never restores a draft');
  assert.deepEqual(waiting(), [], 'the automatic reads do not come back');
  assert.equal(reads(), 3, 'no further read');
});

test('switching the conversation while a read is in flight ignores its later refusal', async () => {
  const automatic = later();
  const { panel, poll, waiting, reads, props, rerun, requests } = orderedPanel([status(null), automatic.promise, status(RUNNING)]);
  await settle();
  await panel.generate();
  await poll();
  props.conversationId = 9;
  rerun();
  await settle();
  assert.equal(requests.at(-1).url, '/toybaco/growth/drafts?account_id=4&conversation_id=9');
  assert.equal(panel.available.value, true);
  assert.equal(panel.result.value.state, 'running');
  assert.deepEqual(waiting(), [1800]);
  automatic.resolve(answer(403, {})); // refusal belongs to the former conversation
  await settle();
  assert.equal(panel.available.value, true, 'the former refusal never closes the new conversation');
  assert.equal(panel.result.value.state, 'running');
  assert.deepEqual(waiting(), [1800], 'the new conversation keeps its scheduled read');
  assert.equal(reads(), 3, 'the former refusal makes no further read');
});

test('switching the conversation while a read waits to retry leaves no read of the former one', async () => {
  const replies = [];
  const { panel, poll, waiting, requests, props, rerun, timers } = draftPanel((method) => {
    if (method === 'POST') return answer(202, QUEUED);
    const next = replies.shift() || status(null);
    if (next instanceof Error) throw next;
    return next;
  });
  await settle();
  await panel.generate();
  replies.push(new TypeError('Failed to fetch'));
  await poll(); // a passing failure: the read waits to retry
  assert.deepEqual(waiting(), [3600]);
  const [[, formerRetry]] = timers;
  props.conversationId = 9; // another conversation opens
  rerun();
  await settle();
  assert.deepEqual(waiting(), [], 'the retry of the former conversation is cancelled');
  assert.equal(requests.at(-1).url, '/toybaco/growth/drafts?account_id=4&conversation_id=9');
  const count = requests.length;
  formerRetry.fn(); // even if the former retry ran late, it reads nothing and leaves this conversation as it is
  await settle();
  assert.equal(requests.length, count, 'no read from the former retry');
  assert.equal(panel.available.value, true);
  assert.equal(panel.result.value, null);
  assert.deepEqual(waiting(), []);
});

// S0-1 (2026-10-06): the AI draft shows in one place. While the panel is available it offers the latest bot draft as
// 「AI の案（自動作成）」 when no requested draft is shown, and the reply box hides its own note about that draft.
test('the panel offers the latest bot draft in the same form and hands it to the reply box', () => {
  const start = panelTemplate.indexOf('<template v-else-if="botDraft && !pending">');
  const bot = panelTemplate.slice(start, panelTemplate.indexOf('</template>', start));
  assert(start > panelTemplate.indexOf('<template v-if="hasResult">'), 'a requested draft comes first');
  assert(bot.includes('AI の案（自動作成）'));
  assert(bot.includes('{{ botDraft.content }}'));
  assert(bot.includes('<p v-if="botDraftApplied" role="status">返信欄に入れました。内容を確認して送信してください。</p>'));
  assert(bot.includes('<span>{{ botDraftHint }}</span>'));
  assert(bot.includes(':disabled="botDraftLocked"'), 'the bot draft never replaces typed text');
  assert(bot.includes(`@click="emit('useBotDraft')"`));
});

test('the reply box wires the panel and hides its own draft note while the panel is available', () => {
  const start = reply.indexOf('<ToybacoManualDraft');
  const panel = reply.slice(start, reply.indexOf('/>', start));
  for (const binding of [':bot-draft="toybacoAiDraft"', ':bot-draft-applied="toybacoAiDraftImported"', ':has-content="hasMeaningfulEditorContent"',
    '@use-bot-draft="useToybacoAiDraft"', '@availability="toybacoManualAvailable = $event"']) assert(panel.includes(binding), binding);
  assert(reply.includes('<div v-if="toybacoAiDraft && isDefaultEditorMode && !toybacoManualAvailable" class="toybaco-ai-draft-result"'));
  assert(reply.includes('      toybacoManualAvailable: false,'));
});

// Astra (2026-10-06): a reply box that holds only the signature takes the bot draft; real input stays, and the panel
// suggests copying instead. The reply box decides what counts as input (hasMeaningfulEditorContent leaves the signature out).
test('the bot draft goes into a reply box holding only the signature, and never over real input', async () => {
  const signed = draftPanel(() => status(null), { draft: '\n\n--\nトイバコ店', hasContent: false });
  await settle();
  assert.equal(signed.panel.botDraftLocked.value, false, 'a signature alone is not input');
  assert.equal(signed.panel.botDraftHint.value, '内容を確認してから、返信欄に入れてください。');
  const typed = draftPanel(() => status(null), { draft: 'お問い合わせありがとうございます。\n\n--\nトイバコ店', hasContent: true });
  await settle();
  assert.equal(typed.panel.botDraftLocked.value, true, 'typed text is kept');
  assert.equal(typed.panel.botDraftHint.value, '入力中の内容を残しています。案から必要な部分をコピーして使えます。');
  signed.props.canEdit = false;
  assert.equal(signed.panel.botDraftLocked.value, true, 'a reply box that cannot be edited takes nothing');
});

test('the panel reports that it is available, and that it is gone when it closes', async () => {
  const opened = draftPanel(() => status(null));
  await settle();
  opened.rerun();
  opened.unmount();
  assert.deepEqual(opened.emitted.filter(([name]) => name === 'availability').map(([, value]) => value), [false, true, false]);
});

test('on a phone the panel stays a chip until opened, and remembers that per conversation for the session', async () => {
  const stored = new Map();
  const matchMedia = () => ({ matches: true, addEventListener() {}, removeEventListener() {} });
  const window = { matchMedia, sessionStorage: { getItem: key => stored.get(key) ?? null,
    setItem: (key, value) => stored.set(key, value), removeItem: key => stored.delete(key) } };
  const { panel, props, rerun } = draftPanel(() => status(null), {}, { window });
  await settle();
  assert.equal(panel.narrow.value, true);
  assert.equal(panel.expanded.value, false);
  panel.toggleExpanded();
  assert.equal(panel.expanded.value, true);
  assert.deepEqual([...stored], [['toybaco:ai-reply-draft:4:8', '1']]);
  props.conversationId = 9;
  rerun();
  assert.equal(panel.expanded.value, false, 'another conversation opens folded');
  props.conversationId = 8;
  rerun();
  assert.equal(panel.expanded.value, true);
  assert(panelTemplate.includes('<button v-if="available && narrow && !expanded" type="button" class="toybaco-manual-ai__chip" aria-expanded="false" @click="toggleExpanded">'));
  assert(panelTemplate.includes('AI返信の案を見る'));

  const blocked = { matchMedia, get sessionStorage() { throw new Error('denied'); } };
  const folded = draftPanel(() => status(null), {}, { window: blocked });
  await settle();
  assert.equal(folded.panel.expanded.value, false, 'an unreadable session keeps the panel folded');
  folded.panel.toggleExpanded();
  assert.equal(folded.panel.expanded.value, true, 'the chip still opens when the session cannot be written');
});

// 段 1b-1: under a reply draft, the store facts it used (the keys DraftState keeps, never the values) and a notice when
// the store facts were saved again after the draft was made (its revision and the guide state's revision differ).
test('a reply draft names the store facts it used and tells when they were saved again', async () => {
  assert.equal(api.draftFactsLine(['name', 'hours', 'booking']), '参照した店舗情報: 店舗名、営業日・営業時間、予約方法');
  assert.equal(api.draftFactsLine(['services', 'secret', 'cancellation']), '参照した店舗情報: サービス・メニュー、キャンセル条件');
  for (const value of [undefined, null, [], ['secret'], 'name', { 0: 'name' }]) assert.equal(api.draftFactsLine(value), '', JSON.stringify(value));
  assert.equal(api.draftFactsChanged({ facts_revision: 'a' }, { revision: 'b' }), true);
  for (const [result, facts] of [[{ facts_revision: 'a' }, { revision: 'a' }], [{}, { revision: 'b' }], [{ facts_revision: 'a' }, null],
    [{ facts_revision: 'a' }, { revision: 1 }]]) assert.equal(api.draftFactsChanged(result, facts), false, JSON.stringify([result, facts]));
  // The panel shows both lines under the draft, from the server values only.
  assert(panelTemplate.includes('<p v-if="factsLine" class="toybaco-manual-ai__facts">{{ factsLine }}</p>'));
  // The notice may appear after the draft (the store facts saved again later): it is a status, so it is read out then.
  assert(panelTemplate.includes('<p v-if="factsChanged" class="toybaco-manual-ai__facts" role="status">店舗情報が更新されています。作り直すと反映されます。</p>'));
  const done = { id: 21, state: 'completed', current: true, content: '10時からです。', incoming_id: 10, draft_digest: 'd',
    facts_fields: ['name', 'hours'], facts_revision: 'r1' };
  const guide = { value: { account_id: 4, facts: { revision: 'r1' } } };
  const { panel } = draftPanel(() => status(done), {}, { guide });
  await settle();
  assert.equal(panel.factsLine.value, '参照した店舗情報: 店舗名、営業日・営業時間');
  assert.equal(panel.factsChanged.value, false);
  guide.value = { account_id: 4, facts: { revision: 'r2' } };
  assert.equal(panel.factsChanged.value, true);
  // Another store's guide state is never compared; a draft made before the keys were kept shows no line.
  guide.value = { account_id: 5, facts: { revision: 'r2' } };
  assert.equal(panel.factsChanged.value, false);
  const { panel: old } = draftPanel(() => status({ ...done, facts_fields: undefined }), {}, { guide });
  await settle();
  assert.equal(old.factsLine.value, '');
});
