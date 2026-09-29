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
// 作成中は 1.8 秒ごとに状況を読む。通信の断・時間切れ・5xx で読めなかったときは間隔を倍にして
// (最大 10 秒)読み直す。読み直しは続けて 8 回まで。それでも読めなければ止めて「状況を確認」を出す。
const POLL_MS = 1800;
const RETRY_MAX_MS = 10000;
const RETRY_LIMIT = 8;
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
let retries = 0;
let reading = 0;
const pending = computed(() => draftPending(result.value));
// 待ち時間に合わせて案内を変える。「状況を確認」は作成中に 1 つだけ出す(60 秒を超えたときと、読み取りを止めたとき)。
const checkable = computed(() => pending.value && (uncertain.value || elapsed.value >= 60));
const pendingText = computed(() => {
  if (elapsed.value >= 60) return '時間がかかっています。「状況を確認」で最新の状況を読み直すか、そのまま入力を続けてください。';
  if (elapsed.value >= 10) return '作成に時間がかかっています。入力は続けられます。';
  return '返信案を作成中…';
});
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
  let data;
  try {
    data = await response.json();
  } catch {
    // 5xx の HTML など、本文が JSON でない応答も状態コードで見分けられるようにする。
    const failure = new Error('応答を読めませんでした。');
    failure.status = response.status;
    throw failure;
  }
  if (!response.ok) {
    const failure = new Error(data.error || '現在、AIを利用できません。');
    failure.status = response.status;
    failure.rejected = response.status >= 400 && response.status < 500;
    throw failure;
  }
  return data;
}

// 通信の断・時間切れ・5xx は一時的な失敗。401/403/404 と、そのほかの 4xx は読み直さない。
function transient(failure) {
  return !failure.denied && !failure.rejected && !(failure.status >= 400 && failure.status < 500);
}

function schedule(version, delay = POLL_MS) {
  clearTimeout(timer);
  if (pending.value && version === generation) timer = setTimeout(() => refresh(version), delay);
}

// 待ち時間は作成を始めた時刻から数える。開き直した画面などで始まりが分からない作成は、最初に見えた時刻から。
function tick() {
  if (!pending.value) return;
  startedAt.value ||= Date.now();
  elapsed.value = Math.floor((Date.now() - startedAt.value) / 1000);
}

// 手動の「状況を確認」も自動の読み取りも、ここから始める。始めるときに予約済みの読み取りを取り消し、
// 成功応答は最後に始めた読み取りのものだけを反映する。同じ会話の拒否は読み取りの順序に関係なく効く。
// 切り替え前の会話・閉じたパネルの予約が遅れて動いても、今の会話の予約や読み取りには触れない。
async function refresh(version = generation) {
  if (version !== generation) return;
  clearTimeout(timer);
  const ticket = ++reading;
  const latest = () => version === generation && ticket === reading;
  try {
    const data = await request();
    if (!latest()) return;
    retries = 0;
    available.value = data.available === true;
    remaining.value = data.remaining;
    result.value = data.result;
    if (!pending.value) {
      uncertain.value = false;
      error.value = result.value?.state === 'failed' ? draftError(result.value) : '';
    } else if (uncertain.value) {
      // 読み直せたので、止まっていた確認の案内を消して、作成中の表示に戻す。
      uncertain.value = false;
      error.value = '';
    }
    tick();
    schedule(version);
  } catch (failure) {
    if (version !== generation) return;
    if (failure.denied) {
      tick();
      // 読めない会話になった。読み取り中の応答・中止・予約をすべて無効にして閉じたままにする(自動の読み取りは再開しない)。
      generation += 1;
      clearTimeout(timer);
      available.value = false;
      result.value = null;
      return;
    }
    if (!latest()) return;
    tick();
    if (pending.value && transient(failure) && retries < RETRY_LIMIT) {
      retries += 1;
      schedule(version, Math.min(POLL_MS * 2 ** retries, RETRY_MAX_MS));
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
  retries = 0;
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
  retries = 0;
  startedAt.value = 0;
  elapsed.value = 0;
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
    <p v-if="pending" role="status">{{ pendingText }}</p>
    <template v-if="hasResult">
      <p v-if="result.needs_review" class="toybaco-manual-ai__notice">送信前に内容の確認が必要です。</p>
      <p class="toybaco-manual-ai__text">{{ result.content }}</p>
      <p v-if="wasApplied" role="status">返信欄に入れました。内容を確認して送信してください。</p>
      <div v-else class="toybaco-manual-ai__actions">
        <span v-if="!applicable">入力・会話が更新されています。現在の内容から作り直せます。</span>
        <span v-else>{{ draft.trim() ? '内容を確認してから、返信欄をこの案に置き換えてください。' : '内容を確認してから、返信欄に入れてください。' }}</span>
        <button type="button" :disabled="busy || !applicable" data-toybaco-guide-action="reply.ai_draft" @click="apply">
          {{ draft.trim() ? '返信欄をこの案に置き換える' : '返信欄に入れる' }}
        </button>
      </div>
    </template>
    <p v-if="error" role="status">{{ error }}</p>
    <!-- 読み上げが重ならないよう、ボタンは status の段落の外に置く。 -->
    <button v-if="checkable" type="button" class="toybaco-manual-ai__quiet toybaco-manual-ai__check" @click="refresh()">状況を確認</button>
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
.toybaco-manual-ai button.toybaco-manual-ai__check { margin-top: 4px; padding: 6px 0; }
.toybaco-manual-ai p { margin: 10px 0 0; line-height: 1.7; }
.toybaco-manual-ai .toybaco-manual-ai__text { white-space: pre-wrap; overflow-wrap: anywhere; font-size: 13px; max-height: 180px; overflow: auto; padding: 12px 0; }
.toybaco-manual-ai__notice { color: #7a551a; }
.toybaco-manual-ai__actions span { color: #5b6a75; }
.toybaco-manual-ai a { color: var(--ink); text-decoration: underline; margin-left: 6px; }
</style>
