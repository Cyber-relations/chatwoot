import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const root = new URL('../', import.meta.url);
const helper = fs.readFileSync(new URL('overlay/app/app/javascript/dashboard/helper/toybacoAiDraft.js', root), 'utf8');
const reply = fs.readFileSync(new URL('overlay/app/app/javascript/dashboard/components/widgets/conversation/ReplyBox.vue', root), 'utf8');
const sandbox = {};
vm.runInNewContext(helper.replaceAll('export ', '') + '\nthis.latest = latestToybacoAiDraft; this.prefix = AI_DRAFT_PREFIX;', sandbox);
const bot = { id: 'fixture-draft', private: true, message_type: 1, sender: { type: 'agent_bot' }, content: sandbox.prefix + '<b>確認する文案</b>' };
assert.equal(sandbox.latest([bot]).content, '<b>確認する文案</b>');
for (const messages of [null, [], [{ ...bot, private: false }], [{ ...bot, sender: { type: 'user' } }], [{ ...bot, content: 'normal note' }], [bot, { private: false, message_type: 0 }], [bot, { private: false, message_type: 'outgoing' }]]) {
  assert.equal(sandbox.latest(messages), null);
}
assert.equal(sandbox.latest([bot, { private: true, message_type: 1, content: 'スタッフの別メモ' }]).id, bot.id);

assert.ok(reply.includes('v-if="toybacoAiDraftImported">AI下書きを返信欄に入れました'), 'successful import must have distinct feedback');
const body = reply.slice(reply.indexOf('    async useToybacoAiDraft() {'), reply.indexOf('    addIntoEditor(content) {'));
const useDraft = vm.runInNewContext('({' + body + '}).useToybacoAiDraft', { REPLY_EDITOR_MODES: { REPLY: 'reply' } });
function fixture() {
  const inserted = [], mode = []; let pending = false;
  const ctx = { $route: { params: { accountId: '4' } }, toybacoImportedAiDraft: null, currentChat: { id: 'conversation-A', messages: [bot] }, isEditorDisabled: false, canSendPublicReply: true, hasMeaningfulEditorContent: false, isPrivate: false, hasAttachments: false,
    get toybacoAiDraft() { return sandbox.latest(this.currentChat.messages); },
    $nextTick: async function () { if (pending) { this.hasMeaningfulEditorContent = true; pending = false; } }, setReplyMode(value) { mode.push(value); this.isPrivate = false; }, addIntoEditor(content) { inserted.push(content); pending = true; },
    sendMessage() { throw new Error('must never send'); } };
  return { ctx, inserted, mode };
}
{
  const f = fixture(); await useDraft.call(f.ctx);
  assert.deepEqual(f.inserted, ['<b>確認する文案</b>']); assert.equal(f.mode.length, 0);
}
{
  const f = fixture(); f.ctx.isPrivate = true; await useDraft.call(f.ctx);
  assert.deepEqual(f.mode, ['reply']); assert.equal(f.inserted.length, 1);
}
for (const state of [{ hasMeaningfulEditorContent: true }, { canSendPublicReply: false }, { isEditorDisabled: true }, { isPrivate: true, hasAttachments: true }]) {
  const f = fixture(); Object.assign(f.ctx, state); await useDraft.call(f.ctx); assert.equal(f.inserted.length, 0); assert.equal(f.mode.length, 0);
}
for (const change of [ctx => { ctx.$route.params.accountId = '13'; }, ctx => { ctx.currentChat = { id: 'conversation-B', messages: [bot] }; }, ctx => { ctx.currentChat.messages = []; }, ctx => { ctx.hasMeaningfulEditorContent = true; }, ctx => { ctx.canSendPublicReply = false; }, ctx => { ctx.isEditorDisabled = true; }]) {
  const f = fixture(); f.ctx.$nextTick = async () => change(f.ctx); await useDraft.call(f.ctx); assert.equal(f.inserted.length, 0);
}
const importedSource = reply.slice(reply.indexOf('    toybacoAiDraftImported() {'), reply.indexOf('    isBotOwnedPendingConversation() {'));
const imported = vm.runInNewContext('({' + importedSource + '}).toybacoAiDraftImported');
const messageWatch = vm.runInNewContext('({' + reply.slice(reply.indexOf('    message() {'), reply.indexOf('    showWhatsappTemplates(isAvailable) {')) + '}).message');
{
  const f = fixture(); await useDraft.call(f.ctx);
  assert.equal(imported.call(f.ctx), true, 'completed import must get success feedback');
  f.ctx.hasMeaningfulEditorContent = true;
  assert.equal(imported.call(f.ctx), true, 'editing an imported reply retains its successful origin');
  f.ctx.doAutoSaveDraft = () => {};
  f.ctx.hasMeaningfulEditorContent = false; messageWatch.call(f.ctx);
  assert.equal(f.ctx.toybacoImportedAiDraft, null, 'clearing resets local success feedback');
  f.ctx.hasMeaningfulEditorContent = true;
  assert.equal(imported.call(f.ctx), false, 'unrelated new typing must get the existing-content protection');
}
for (const change of [ctx => { ctx.currentChat.id = 'conversation-B'; }, ctx => { ctx.$route.params.accountId = '13'; }, ctx => { ctx.currentChat.messages = [{ ...bot, id: 'new-draft' }]; }, ctx => { ctx.isPrivate = true; }]) {
  const f = fixture(); await useDraft.call(f.ctx); change(f.ctx);
  assert.equal(imported.call(f.ctx), false, 'success feedback must not cross the original context');
}
for (const change of [ctx => { ctx.currentChat.id = 'conversation-B'; }, ctx => { ctx.$route.params.accountId = '13'; }, ctx => { ctx.hasMeaningfulEditorContent = false; }, ctx => { ctx.isEditorDisabled = true; }]) {
  const f = fixture(); const originalTick = f.ctx.$nextTick; let tick = 0;
  f.ctx.$nextTick = async function () { await originalTick.call(this); if (++tick === 2) change(this); };
  await useDraft.call(f.ctx);
  assert.equal(f.ctx.toybacoImportedAiDraft, null, 'failed/stale editor settlement must not report success');
}
for (const state of [{ hasMeaningfulEditorContent: true }, { canSendPublicReply: false }, { isEditorDisabled: true }, { isPrivate: true, hasAttachments: true }]) {
  const f = fixture(); Object.assign(f.ctx, state); await useDraft.call(f.ctx);
  assert.equal(f.ctx.toybacoImportedAiDraft, null); assert.equal(f.inserted.length, 0);
}
assert.match(reply, /v-else-if="hasMeaningfulEditorContent \|\| \(isPrivate && hasAttachments\)">入力中の内容を残しています/);
assert.match(reply, /:disabled="isEditorDisabled \|\| !canSendPublicReply \|\| hasMeaningfulEditorContent/);
assert.doesNotMatch(body, /sendMessage\(|dispatch\(|fetch\(/);
console.log('AI draft: trusted private bot result, stale-message exclusion, content/permission/tenant race and no-send regressions PASS');
