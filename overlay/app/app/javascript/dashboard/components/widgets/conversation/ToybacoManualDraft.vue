<script setup>
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import { canApplyDraft, digestDraft, draftEndpoint, draftError, draftPending } from 'dashboard/helper/toybacoManualDraft';

const props = defineProps({
  accountId: { type: [Number, String], required: true },
  conversationId: { type: [Number, String], required: true },
  incomingId: { type: [Number, String], default: null },
  draft: { type: String, default: '' },
  canEdit: { type: Boolean, default: false },
});
const emit = defineEmits(['apply']);
const available = ref(false);
const remaining = ref(0);
const result = ref(null);
const applied = ref(null);
const busy = ref(false);
const error = ref('');
const digest = ref('');
const elapsed = ref(0);
const uncertain = ref(false);
const startedAt = ref(0);
let generation = 0;
let timer;
let intent;
const pending = computed(() => draftPending(result.value));
const applicable = computed(() => canApplyDraft(result.value, {
  incomingId: props.incomingId, digest: digest.value, canEdit: props.canEdit,
}));
const hasResult = computed(() => result.value?.state === 'completed');
const wasApplied = computed(() => applied.value?.requestId === result.value?.id && applied.value?.draft === props.draft);
const billingUrl = computed(() => `/toybaco/billing?account_id=${encodeURIComponent(props.accountId)}`);

async function request(method = 'GET', body, requestId) {
  const endpoint = draftEndpoint(props.accountId, props.conversationId, requestId);
  if (!endpoint) throw new Error('この会話では利用できません。');
  const response = await fetch(endpoint, {
    method, credentials: 'same-origin', cache: 'no-store', redirect: 'error',
    headers: body ? { 'Content-Type': 'application/json' } : {},
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(12000),
  });
  if ([401, 403, 404].includes(response.status)) {
    const failure = new Error('現在、この会話ではAIを利用できません。');
    failure.denied = true;
    throw failure;
  }
  const data = await response.json();
  if (!response.ok) {
    const failure = new Error(data.error || '現在、AIを利用できません。');
    failure.rejected = response.status >= 400 && response.status < 500;
    throw failure;
  }
  return data;
}

function schedule(version) {
  clearTimeout(timer);
  if (pending.value && version === generation) timer = setTimeout(() => refresh(version), 1800);
}

async function refresh(version = generation) {
  try {
    const data = await request();
    if (version !== generation) return;
    available.value = data.available === true;
    remaining.value = data.remaining;
    result.value = data.result;
    if (!pending.value) {
      uncertain.value = false;
      error.value = result.value?.state === 'failed' ? draftError(result.value) : '';
    }
    elapsed.value = Math.floor((Date.now() - startedAt.value) / 1000);
    schedule(version);
  } catch (failure) {
    if (version !== generation) return;
    if (failure.denied) {
      available.value = false;
      result.value = null;
    } else if (pending.value || uncertain.value) {
      error.value = '作成状況を確認できません。再接続後に確認できます。';
      uncertain.value = true;
    }
  }
}

async function generate() {
  if (busy.value || pending.value || !props.canEdit || !available.value || remaining.value <= 0) return;
  const version = generation;
  busy.value = true;
  error.value = '';
  applied.value = null;
  startedAt.value = Date.now();
  elapsed.value = 0;
  // A lost response keeps the same intent. Retrying cannot spend another unit.
  intent ||= { nonce: crypto.randomUUID(), draft: props.draft };
  try {
    const data = await request('POST', intent);
    if (version !== generation) return;
    result.value = data;
    intent = null;
    uncertain.value = false;
    schedule(version);
    if (!pending.value) await refresh(version);
  } catch (failure) {
    if (version !== generation) return;
    error.value = failure.rejected || failure.denied ? failure.message : '通信を確認できません。同じ作成を再確認できます。';
    uncertain.value = !failure.rejected && !failure.denied;
    if (!uncertain.value) intent = null;
    if (failure.denied) available.value = false;
  } finally {
    if (version === generation) busy.value = false;
  }
}

async function cancel() {
  if (busy.value || !pending.value) return;
  const version = generation;
  busy.value = true;
  try {
    const data = await request('DELETE', {}, result.value.id);
    if (version !== generation) return;
    result.value = data;
    clearTimeout(timer);
    await refresh(version);
  } catch {
    if (version === generation) error.value = '中止を確認できません。作成状況を再確認してください。';
  } finally {
    if (version === generation) busy.value = false;
  }
}

async function apply() {
  if (busy.value || !applicable.value) return;
  const version = generation;
  const expectedDraft = props.draft;
  busy.value = true;
  try {
    const data = await request('GET', undefined, result.value.id);
    if (version !== generation || props.draft !== expectedDraft) return;
    result.value = data.result;
    if (data.available === true && applicable.value) emit('apply', {
      content: result.value.content, expectedDraft, accountId: props.accountId,
      conversationId: props.conversationId, incomingId: props.incomingId,
      onApplied: draft => { if (version === generation) applied.value = { requestId: result.value.id, draft }; },
    });
  } catch {
    if (version === generation) error.value = '会話の状態を確認できません。入力はそのまま残しています。';
  } finally {
    if (version === generation) busy.value = false;
  }
}

watch(() => props.draft, async value => {
  digest.value = '';
  const valueDigest = await digestDraft(value);
  if (props.draft === value) digest.value = valueDigest;
}, { immediate: true });
watch(() => [props.accountId, props.conversationId], () => {
  generation += 1;
  clearTimeout(timer);
  result.value = null;
  applied.value = null;
  available.value = false;
  busy.value = false;
  error.value = '';
  intent = null;
  uncertain.value = false;
  refresh(generation);
}, { immediate: true });
onBeforeUnmount(() => { generation += 1; clearTimeout(timer); });
</script>

<template>
  <section v-if="available" class="toybaco-manual-ai" aria-label="トイバコAI 返信下書き">
    <div class="toybaco-manual-ai__bar">
      <div><strong>トイバコAI</strong><span>あと {{ remaining }} 回</span></div>
      <button v-if="!pending" type="button" :disabled="busy || !canEdit || remaining <= 0" data-toybaco-guide-action="reply.generate" @click="generate">
        {{ uncertain ? '同じ作成を再確認' : hasResult ? '別の案を作る · 1回' : draft.trim() ? '文章を整える · 1回' : '返信案を作る · 1回' }}
      </button>
      <button v-else type="button" class="toybaco-manual-ai__quiet" :disabled="busy" @click="cancel">中止</button>
    </div>
    <p v-if="pending" role="status">{{ elapsed >= 10 ? 'もう少しで完了します。入力は続けられます。' : '返信案を作成中…' }}</p>
    <template v-if="hasResult">
      <p v-if="result.needs_review" class="toybaco-manual-ai__notice">送信前に内容の確認が必要です。</p>
      <p class="toybaco-manual-ai__text">{{ result.content }}</p>
      <p v-if="wasApplied" role="status">返信欄に入れました。内容を確認して送信してください。</p>
      <div v-else class="toybaco-manual-ai__actions">
        <span v-if="!applicable">入力・会話が更新されています。現在の内容から作り直せます。</span>
        <span v-else>内容を確認してから送信</span>
        <button type="button" :disabled="busy || !applicable" data-toybaco-guide-action="reply.ai_draft" @click="apply">
          {{ draft.trim() ? '返信欄をこの案に置き換える' : '返信欄に入れる' }}
        </button>
      </div>
    </template>
    <p v-if="error" role="status">{{ error }} <button v-if="uncertain && pending" type="button" class="toybaco-manual-ai__quiet" @click="refresh()">状況を確認</button></p>
    <p v-if="remaining <= 0 && !pending">AI枠を使い切りました。<a :href="billingUrl" target="_top">プランを確認</a></p>
  </section>
</template>

<style scoped>
.toybaco-manual-ai { --ink: #1f3a5f; --paper: #fcfbf8; margin: 8px 12px; border: 1px solid #e7e2da; border-radius: 14px; background: var(--paper); color: var(--ink); padding: 13px 16px; font-size: 12px; }
.toybaco-manual-ai__bar, .toybaco-manual-ai__actions { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
.toybaco-manual-ai__bar strong { font-size: 13px; }
.toybaco-manual-ai__bar span { margin-left: 12px; color: #5b6a75; }
.toybaco-manual-ai button { border: 0; border-radius: 9px; color: white; background: var(--ink); padding: 8px 12px; font-size: 12px; cursor: pointer; font-weight: 600; }
.toybaco-manual-ai button:disabled { opacity: .42; cursor: default; }
.toybaco-manual-ai button:focus-visible, .toybaco-manual-ai a:focus-visible { outline: 2px solid var(--ink); outline-offset: 3px; }
.toybaco-manual-ai button.toybaco-manual-ai__quiet { color: var(--ink); background: transparent; }
.toybaco-manual-ai p { margin: 10px 0 0; line-height: 1.7; }
.toybaco-manual-ai .toybaco-manual-ai__text { white-space: pre-wrap; overflow-wrap: anywhere; font-size: 13px; max-height: 180px; overflow: auto; padding: 12px 0; }
.toybaco-manual-ai__notice { color: #7a551a; }
.toybaco-manual-ai__actions span { color: #5b6a75; }
.toybaco-manual-ai a { color: var(--ink); text-decoration: underline; margin-left: 6px; }
</style>
