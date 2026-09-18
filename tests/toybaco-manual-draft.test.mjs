import fs from 'node:fs';
import vm from 'node:vm';
import { webcrypto } from 'node:crypto';
import assert from 'node:assert/strict';
import test from 'node:test';

const root = new URL('../', import.meta.url);
const read = path => fs.readFileSync(new URL(path, root), 'utf8');
const helper = read('overlay/app/app/javascript/dashboard/helper/toybacoManualDraft.js');
const sandbox = { crypto: webcrypto, TextEncoder, URLSearchParams };
vm.runInNewContext(helper.replaceAll('export ', '') + '\nthis.api = { canApplyDraft, digestDraft, draftEndpoint, draftPending };', sandbox);
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
