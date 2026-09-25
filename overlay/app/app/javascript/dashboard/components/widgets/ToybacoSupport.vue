<script setup>
import {
  computed,
  nextTick,
  onBeforeUnmount,
  onMounted,
  ref,
  reactive,
  watch,
} from "vue";
import { useRouter } from "vue-router";
import { useAccount } from "dashboard/composables/useAccount";
import ToybacoSupportReports from "./ToybacoSupportReports.vue";
import {
  createSupportQuestion,
  createSupportDiagnostics,
} from "dashboard/helper/toybacoSupportQuestion";

const { accountId, currentAccount } = useAccount();
const router = useRouter();
const opened = ref(false);
const busy = ref(false);
const error = ref("");
const search = ref("");
const articles = ref([]);
const selected = ref(null);
const field = ref(null);
const question = ref("");
const aiAvailable = ref(false);
const reportsAvailable = ref(false);
const billingReport = ref(false);
const answer = reactive({ busy: false, slow: false, error: "", retryAt: null });
const diagnosis = reactive({ busy: false, checks: [], error: "" });
const guideArticles = ref([]);
const diagnosticArticles = [
  "first_steps",
  "connection",
  "line",
  "gmail",
  "microsoft",
  "reply",
  "facts",
  "ai",
  "billing",
];
const VERSION = "2026-09-25.1";
const targets = {
  start: ["toybaco_growth_start", "初回案内を開く"],
  inboxes: ["settings_inbox_list", "受信箱を開く"],
  staff: ["agent_list", "スタッフを開く"],
  billing: ["toybaco_billing_settings_index", "契約を確認する"],
  conversations: ["home", "会話を開く"],
  posting: ["home", "投稿を開く"],
};
let epoch = 0;
let controller;
let previousFocus;
const enabled = computed(() => currentAccount.value?.toybaco_support === true);
const supportQuestion = createSupportQuestion({
  context: () => ({
    enabled: enabled.value && aiAvailable.value && opened.value,
    accountId: String(accountId.value),
    version: VERSION,
    articles: articles.value,
  }),
  change: (state) => {
    if (Object.prototype.hasOwnProperty.call(state, "article"))
      selected.value = state.article;
    for (const key of ["busy", "slow", "error", "retryAt"]) {
      if (Object.prototype.hasOwnProperty.call(state, key))
        answer[key] = state[key];
    }
  },
});
const diagnostics = createSupportDiagnostics({
  context: () => ({
    enabled: enabled.value && opened.value,
    accountId: String(accountId.value),
    articleId: selected.value?.id,
    version: VERSION,
  }),
  change: (state) => Object.assign(diagnosis, state),
});
function guideAvailability(event) {
  const detail = event.detail;
  if (
    String(detail?.accountId) !== String(accountId.value) ||
    !Array.isArray(detail?.articles)
  )
    return;
  guideArticles.value = detail.articles;
}
async function showPointer() {
  const article = selected.value;
  if (!article || !guideArticles.value.includes(article.id)) return;
  const account = String(accountId.value);
  const attempt = epoch + 1;
  await load();
  if (attempt !== epoch || account !== String(accountId.value) || !opened.value)
    return;
  selected.value =
    articles.value.find((item) => item.id === article.id) || null;
  if (!selected.value || !guideArticles.value.includes(article.id)) return;
  close();
  window.dispatchEvent(
    new CustomEvent("toybaco:support-guide", {
      detail: { accountId: account, articleId: article.id },
    }),
  );
}
const retryTime = computed(() =>
  answer.retryAt
    ? new Date(answer.retryAt).toLocaleTimeString("ja-JP", {
        hour: "2-digit",
        minute: "2-digit",
      })
    : "",
);
const results = computed(() => {
  const term = search.value.trim().toLocaleLowerCase("ja");
  return articles.value.filter((article) =>
    `${article.title} ${article.answer}`.toLocaleLowerCase("ja").includes(term),
  );
});

function close() {
  supportQuestion.cancel();
  diagnostics.cancel();
  epoch += 1;
  controller?.abort();
  opened.value = false;
  busy.value = false;
  articles.value = [];
  selected.value = null;
  search.value = "";
  question.value = "";
  answer.error = "";
  aiAvailable.value = false;
  reportsAvailable.value = false;
  if (previousFocus?.isConnected) previousFocus.focus();
}

async function load() {
  supportQuestion.cancel();
  diagnostics.cancel();
  controller?.abort();
  controller = new AbortController();
  const attempt = ++epoch;
  const account = String(accountId.value);
  articles.value = [];
  selected.value = null;
  error.value = "";
  busy.value = true;
  aiAvailable.value = false;
  reportsAvailable.value = false;
  answer.error = "";
  answer.retryAt = null;
  try {
    const response = await fetch(
      `/toybaco/support?account_id=${encodeURIComponent(account)}`,
      {
        credentials: "same-origin",
        cache: "no-store",
        signal: controller.signal,
      },
    );
    if (!response.ok) throw new Error("support unavailable");
    const data = await response.json();
    if (attempt !== epoch || account !== String(accountId.value)) return;
    if (
      data.version !== VERSION ||
      String(data.account_id) !== account ||
      !Array.isArray(data.articles)
    )
      throw new Error("support version mismatch");
    articles.value = data.articles;
    aiAvailable.value = data.ai_available === true;
    reportsAvailable.value = data.reports_available === true;
    billingReport.value = data.billing_report === true;
  } catch (failure) {
    if (attempt === epoch && failure.name !== "AbortError")
      error.value = "手順を読み込めませんでした。";
  } finally {
    if (attempt === epoch) busy.value = false;
  }
}

function choose(article) {
  supportQuestion.cancel();
  diagnostics.cancel();
  answer.error = "";
  selected.value = article;
}

async function open(event) {
  if (!enabled.value) return;
  if (event?.detail?.accountId && String(event.detail.accountId) !== String(accountId.value)) return;
  event?.preventDefault();
  previousFocus = document.activeElement;
  opened.value = true;
  window.dispatchEvent(new Event("toybaco:support-guide-refresh"));
  await nextTick();
  field.value?.focus();
  await load();
}

async function navigate() {
  const article = selected.value;
  if (!article || !targets[article.action] || !enabled.value) return;
  const account = String(accountId.value);
  // Recheck current membership and feature availability before suggesting a screen.
  const attempt = epoch + 1;
  await load();
  if (attempt !== epoch || account !== String(accountId.value) || !opened.value)
    return;
  selected.value =
    articles.value.find((item) => item.id === article.id) || null;
  if (!selected.value || selected.value.action !== article.action) return;
  const failure = await router.push({
    name: targets[article.action][0],
    params: { accountId: account },
    query: { toybaco_skip_tour: "1" },
    ...(article.action === "posting" ? { hash: "#/toybaco/posting" } : {}),
  });
  if (!failure) close();
}

watch(
  () => String(accountId.value),
  () => {
    guideArticles.value = [];
    close();
  },
);
watch(selected, () => diagnostics.cancel());
watch(enabled, (value) => {
  if (!value) close();
});
onMounted(() => {
  window.addEventListener("toybaco:open-support", open);
  window.addEventListener(
    "toybaco:support-guide-availability",
    guideAvailability,
  );
});
onBeforeUnmount(() => {
  close();
  window.removeEventListener("toybaco:open-support", open);
  window.removeEventListener(
    "toybaco:support-guide-availability",
    guideAvailability,
  );
});
</script>

<template>
  <aside
    v-if="opened && enabled"
    class="toybaco-support"
    role="region"
    aria-label="トイバコの使い方"
    @keydown.esc.stop="close"
  >
    <header>
      <img
        :src="'/brand-assets/toybaco-logo-c4.png'"
        alt="トイバコ"
        width="118"
      />
      <button type="button" aria-label="使い方を閉じる" @click="close">
        閉じる
      </button>
    </header>
    <h2>どの操作でお困りですか</h2>
    <form
      v-if="aiAvailable"
      class="ai-question"
      @submit.prevent="supportQuestion.ask(question)"
    >
      <label for="toybaco-support-question">トイバコAIに聞く</label>
      <textarea
        id="toybaco-support-question"
        v-model="question"
        rows="3"
        maxlength="500"
        placeholder="例：LINEの返信はどこから送るの？"
      />
      <p class="hint">個人情報や接続キーを入れず、操作を質問してください。</p>
      <button
        v-if="!answer.busy"
        type="submit"
        :disabled="busy || !question.trim()"
      >
        手順を探す
      </button>
      <button v-else type="button" @click="supportQuestion.cancel">
        中断する
      </button>
      <p v-if="answer.busy" role="status">
        {{
          answer.slow
            ? "もう少し確認しています。検索も使えます。"
            : "合う手順を探しています…"
        }}
      </p>
      <p v-if="answer.error" role="alert">
        {{ answer.error
        }}<span v-if="retryTime"> {{ retryTime }}以降に再開できます。</span>
      </p>
    </form>
    <label for="toybaco-support-search">使い方を検索</label>
    <input
      id="toybaco-support-search"
      ref="field"
      v-model="search"
      type="search"
      maxlength="100"
      placeholder="接続、返信、契約など"
    />
    <p v-if="busy" role="status">確認しています…</p>
    <p v-if="error" role="alert">
      {{ error }} <button type="button" @click="load">再読み込み</button>
      <a href="/toybaco-help.html" target="_blank" rel="noopener noreferrer">操作ガイド</a>
    </p>
    <section v-if="selected" class="answer" aria-live="polite">
      <h3>{{ selected.title }}</h3>
      <p>{{ selected.answer }}</p>
      <button
        v-if="guideArticles.includes(selected.id)"
        type="button"
        :disabled="busy"
        @click="showPointer"
      >
        画面で案内
      </button>
      <button
        v-if="diagnosticArticles.includes(selected.id)"
        type="button"
        :disabled="busy || diagnosis.busy"
        @click="diagnostics.inspect"
      >
        状況を確認
      </button>
      <p v-if="diagnosis.busy" role="status">状況を確認しています…</p>
      <p v-if="diagnosis.error" role="alert">{{ diagnosis.error }}</p>
      <ul
        v-if="diagnosis.checks.length"
        class="diagnostics"
        aria-label="確認できた状況"
      >
        <li
          v-for="check in diagnosis.checks"
          :key="check.id"
          :data-state="check.state"
        >
          {{ check.text }}
        </li>
      </ul>
      <button
        v-if="targets[selected.action] && !guideArticles.includes(selected.id)"
        type="button"
        :disabled="busy"
        @click="navigate"
      >
        {{ targets[selected.action][1] }}
      </button>
    </section>
    <ul v-if="!busy && !error">
      <li v-for="article in results" :key="article.id">
        <button
          type="button"
          :aria-pressed="selected?.id === article.id"
          @click="choose(article)"
        >
          {{ article.title }}<span aria-hidden="true">›</span>
        </button>
      </li>
    </ul>
    <p v-if="!busy && !error && !results.length">
      別の言葉で検索してください。
    </p>
    <ToybacoSupportReports
      v-if="reportsAvailable"
      :key="String(accountId)"
      :account-id="accountId"
      :article-id="selected?.id || ''"
      :billing="billingReport"
    />
    <footer>
      <a href="/toybaco-help.html" target="_blank" rel="noopener">操作ガイド</a>
    </footer>
  </aside>
</template>

<style scoped>
.toybaco-support {
  position: fixed;
  z-index: 1000;
  inset: 12px 12px 12px auto;
  width: min(380px, calc(100vw - 24px));
  padding: 24px;
  overflow-y: auto;
  color: #1f3a5f;
  background: #fcfbf8;
  border: 1px solid #e7e2da;
  border-radius: 18px;
  box-shadow: 0 12px 48px #1f3a5f24;
}
header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
}
h2 {
  margin: 24px 0 16px;
  font-size: 18px;
  font-weight: 600;
}
label {
  display: block;
  margin-bottom: 6px;
  font-size: 12px;
}
input {
  width: 100%;
  padding: 10px 12px;
  color: #1f3a5f;
  background: white;
  border: 1px solid #d7d2c9;
  border-radius: 10px;
}
.ai-question {
  margin: 0 0 24px;
}
.ai-question textarea {
  width: 100%;
  padding: 10px 12px;
  color: #1f3a5f;
  background: white;
  border: 1px solid #d7d2c9;
  border-radius: 10px;
  resize: vertical;
}
.ai-question button {
  padding: 10px 14px;
  background: #1f3a5f;
  color: #fcfbf8;
  border-radius: 8px;
}
.ai-question p {
  font-size: 12px;
  line-height: 1.7;
}
.hint {
  margin: 6px 0 12px;
  color: #626d7a;
}
button {
  cursor: pointer;
}
button:focus-visible,
a:focus-visible,
input:focus-visible,
textarea:focus-visible {
  outline: 2px solid #1f3a5f;
  outline-offset: 3px;
}
button:disabled {
  cursor: wait;
  opacity: 0.6;
}
ul {
  margin: 20px 0;
  padding: 0;
  list-style: none;
}
li button {
  display: flex;
  width: 100%;
  justify-content: space-between;
  padding: 14px 0;
  text-align: left;
  border-bottom: 1px solid #e7e2da;
  font-size: 14px;
}
.answer {
  margin-top: 20px;
  padding: 16px;
  background: #f0ece4;
  border-radius: 12px;
}
.answer h3 {
  font-size: 14px;
  font-weight: 600;
}
.answer p {
  margin: 10px 0;
  line-height: 1.8;
  font-size: 14px;
}
.diagnostics li {
  margin: 10px 0;
  font-size: 13px;
  line-height: 1.7;
}
.diagnostics [data-state="attention"] {
  border-left: 3px solid #de7966;
  padding-left: 10px;
}
.answer button {
  margin: 0 8px 8px 0;
  padding: 10px 14px;
  color: #fcfbf8;
  background: #1f3a5f;
  border-radius: 8px;
}
footer {
  margin-top: 20px;
  font-size: 12px;
}
</style>
