<script setup>
import { computed, onBeforeUnmount, reactive, ref, watch } from "vue";
import { useRouter } from "vue-router";
import { useAccount } from "dashboard/composables/useAccount";
import googleClient from "dashboard/api/channel/googleClient";
import microsoftClient from "dashboard/api/channel/microsoftClient";
import {
  growthGuideState as state,
  growthGuideError as error,
  growthGuideBusy as busy,
  refreshGrowthGuide,
  updateGrowthGuide,
  saveGrowthFacts,
} from "dashboard/composables/toybacoGrowthGuide";

const { accountId } = useAccount();
const router = useRouter();
const brandLogoPath = "/brand-assets/toybaco-logo-c4.png";
const connecting = ref(null);
let connectionEpoch = 0;
const providers = {
  google: {
    client: googleClient,
    origin: "https://accounts.google.com",
    available: "gmail_available",
  },
  microsoft: {
    client: microsoftClient,
    origin: "https://login.microsoftonline.com",
    available: "microsoft_available",
  },
};
onBeforeUnmount(() => {
  connectionEpoch += 1;
});
const fields = reactive({
  name: "",
  hours: "",
  address: "",
  phone: "",
  services: "",
  booking: "",
  cancellation: "",
});
const edited = ref(false);
const selectedInbox = computed(() =>
  state.value?.inboxes.find((inbox) => inbox.id === state.value.inbox_id),
);
const extras = [
  { key: "address", label: "住所", max: 500 },
  { key: "phone", label: "電話番号", max: 100 },
  { key: "services", label: "サービス・メニュー", max: 2000 },
  { key: "booking", label: "予約方法", max: 1000 },
  { key: "cancellation", label: "キャンセル条件", max: 1000 },
];
watch(
  () => String(accountId.value),
  () => {
    connectionEpoch += 1;
    connecting.value = null;
    edited.value = false;
    Object.keys(fields).forEach((key) => {
      fields[key] = "";
    });
  },
);
watch(
  () => state.value?.facts,
  (facts) => {
    if (facts && !edited.value) Object.assign(fields, facts.fields);
  },
  { immediate: true },
);

async function connectProvider(provider) {
  const selected = providers[provider];
  if (
    connecting.value ||
    !selected ||
    !state.value?.[selected.available] ||
    !state.value?.administrator
  )
    return;
  connecting.value = provider;
  const originalEpoch = ++connectionEpoch;
  const originalAccount = String(accountId.value);
  try {
    const { data } = await selected.client.generateAuthorization({
      return_to: "growth",
    });
    if (
      originalEpoch !== connectionEpoch ||
      originalAccount !== String(accountId.value)
    )
      return;
    const url = new URL(data.url);
    if (url.origin !== selected.origin || url.username || url.password)
      throw new Error("invalid authorization");
    window.location.assign(url.href);
  } catch {
    if (originalEpoch === connectionEpoch)
      error.value = "接続を始められませんでした。もう一度お試しください。";
  } finally {
    if (originalEpoch === connectionEpoch) connecting.value = null;
  }
}

function openLine() {
  if (!state.value?.administrator) return;
  router.push({
    name: "settings_inboxes_page_channel",
    params: { accountId: accountId.value, sub_page: "line" },
  });
}

function openConversation() {
  if (!state.value?.conversation_id) return;
  router.push({
    name: "conversation_through_inbox",
    params: {
      accountId: accountId.value,
      inbox_id: state.value.inbox_id,
      conversation_id: state.value.conversation_id,
    },
  });
}

async function saveFacts() {
  const result = await saveGrowthFacts({ ...fields });
  if (result) edited.value = false;
}

function openPosting() {
  router.push({
    name: "home",
    params: { accountId: accountId.value },
    hash: "#/toybaco/posting",
  });
}
</script>

<template>
  <section class="toybaco-start">
    <header>
      <img :src="brandLogoPath" alt="トイバコ" width="152" />
      <RouterLink
        :to="{
          name: 'home',
          params: { accountId },
          query: { toybaco_skip_tour: '1' },
        }"
        @click="updateGrowthGuide({ dismissed: true })"
        >あとで続ける</RouterLink
      >
    </header>
    <main>
      <p class="eyebrow">お店の準備</p>
      <p v-if="error" role="alert" class="error">
        {{ error }}
        <button type="button" class="text-button" @click="refreshGrowthGuide">
          再読み込み
        </button>
      </p>
      <p v-if="!state && !error" role="status">準備しています…</p>
      <template v-if="state?.phase === 'purpose'">
        <h1>最初に何をしますか</h1>
        <div class="choices">
          <button
            type="button"
            data-toybaco-guide-action="purpose.inbox"
            :disabled="busy"
            @click="updateGrowthGuide({ purpose: 'inbox', dismissed: false })"
          >
            <strong>問い合わせに対応する</strong
            ><span>メールやLINEの窓口をまとめる</span>
          </button>
          <button
            type="button"
            :disabled="busy"
            @click="updateGrowthGuide({ purpose: 'posting', dismissed: false })"
          >
            <strong>お店の情報を発信する</strong
            ><span>SNSの投稿を作成・予約する</span>
          </button>
        </div>
      </template>
      <template v-else-if="state?.phase === 'connect'">
        <h1>使う窓口をつなぎましょう</h1>
        <p>アカウントを選んで、トイバコの利用を許可します。</p>
        <div class="choices">
          <button
            type="button"
            data-toybaco-guide-action="connection.google"
            :disabled="
              !state.gmail_available || !state.administrator || connecting
            "
            @click="connectProvider('google')"
          >
            <strong>{{
              connecting === "google"
                ? "接続画面を開いています…"
                : "Googleで接続"
            }}</strong
            ><span>Gmail・Google Workspace</span
            ><span v-if="!state.gmail_available">準備中</span>
          </button>
          <button
            type="button"
            data-toybaco-guide-action="connection.microsoft"
            :disabled="
              !state.microsoft_available || !state.administrator || connecting
            "
            @click="connectProvider('microsoft')"
          >
            <strong>{{
              connecting === "microsoft"
                ? "接続画面を開いています…"
                : "Microsoftで接続"
            }}</strong
            ><span>Outlook・Microsoft 365</span
            ><span v-if="!state.microsoft_available">準備中</span>
          </button>
          <button
            type="button"
            data-toybaco-guide-action="connection.line"
            :disabled="!state.administrator || connecting"
            @click="openLine"
          >
            <strong>LINE公式</strong><span>管理者による初期設定が必要です</span>
          </button>
          <div class="unavailable">
            <strong>Instagram</strong><span>接続方式を準備しています。</span>
          </div>
        </div>
        <p v-if="state.administrator && state.handoff_mail_available?.length">
          設定を任せる：
          <a
            v-if="state.handoff_mail_available.includes('gmail')"
            :href="`/toybaco/connections/handoff?account_id=${accountId}&provider=gmail`"
            >Google</a
          >
          <span v-if="state.handoff_mail_available.length > 1"> / </span>
          <a
            v-if="state.handoff_mail_available.includes('microsoft')"
            :href="`/toybaco/connections/handoff?account_id=${accountId}&provider=microsoft`"
            >Microsoft</a
          >
        </p>
        <p v-if="state.administrator && state.handoff_line_available">
          <a :href="`/toybaco/connections/handoff?account_id=${accountId}`"
            >LINEの設定を担当者に依頼</a
          >
        </p>
        <p v-if="!state.administrator">窓口の接続は店舗の管理者が行えます。</p>
      </template>
      <template v-else-if="state?.phase === 'facts'">
        <h1>AIにお店のことを伝える</h1>
        <p>分かる内容だけで大丈夫です。空欄をAIが推測することはありません。</p>
        <form
          v-if="state.administrator"
          @submit.prevent="saveFacts"
          @input="edited = true"
        >
          <label for="toybaco-facts-name">店舗名</label
          ><input
            id="toybaco-facts-name"
            v-model="fields.name"
            maxlength="100"
            required
          />
          <label for="toybaco-facts-hours"
            >営業日・営業時間 <small>任意</small></label
          ><textarea
            id="toybaco-facts-hours"
            v-model="fields.hours"
            rows="3"
            maxlength="1000"
            placeholder="例：火〜日 10:00〜19:00、月曜定休"
          />
          <details>
            <summary>ほかのお店情報を追加</summary>
            <template v-for="field in extras" :key="field.key"
              ><label :for="`toybaco-facts-${field.key}`">{{
                field.label
              }}</label
              ><textarea
                :id="`toybaco-facts-${field.key}`"
                v-model="fields[field.key]"
                rows="2"
                :maxlength="field.max"
              />
            </template>
          </details>
          <button
            class="primary"
            type="submit"
            data-toybaco-guide-action="facts.confirm"
            :disabled="busy"
          >
            確認して保存
          </button>
        </form>
        <p v-else>店舗の管理者がお店情報を確認すると、先へ進めます。</p>
      </template>
      <template v-else-if="state?.phase === 'receive'">
        <h1>メッセージを受け取ってみましょう</h1>
        <p v-if="selectedInbox?.provider === 'line'">
          ご自身のLINEから、この公式アカウントにメッセージを送ってください。
        </p>
        <p v-else>
          別のメールアドレスから、次の窓口にテストメールを送ってください。
        </p>
        <p class="mailbox">
          {{ selectedInbox?.label || selectedInbox?.email }}
        </p>
        <p role="status">届いたら、自動で次の案内に進みます。</p>
      </template>
      <template v-else-if="state?.phase === 'reply'">
        <h1>メッセージが届きました</h1>
        <button
          class="primary"
          type="button"
          data-toybaco-guide-action="reply.open"
          @click="openConversation"
        >
          開いて返信する
        </button>
      </template>
      <template v-else-if="state?.phase === 'complete'">
        <h1>最初の返信を送信しました</h1>
        <p>これで、この窓口から対応を始められます。</p>
        <button class="primary" type="button" @click="openConversation">
          受信箱を開く
        </button>
      </template>
      <template v-else-if="state?.phase === 'posting'">
        <h1>お店の発信を始めましょう</h1>
        <p>投稿先をつないで、最初の投稿を準備します。</p>
        <button
          class="primary"
          type="button"
          data-toybaco-guide-action="posting.open"
          @click="openPosting"
        >
          投稿画面を開く
        </button>
      </template>
      <div v-if="state?.inboxes.length > 1" class="inbox-choice">
        <label for="toybaco-onboarding-inbox">案内する窓口</label
        ><select
          id="toybaco-onboarding-inbox"
          :value="state.inbox_id || ''"
          :disabled="busy"
          @change="updateGrowthGuide({ inbox_id: Number($event.target.value) })"
        >
          <option disabled value="">選んでください</option>
          <option
            v-for="inbox in state.inboxes"
            :key="inbox.id"
            :value="inbox.id"
          >
            {{ inbox.label || inbox.email }}
          </option>
        </select>
      </div>
      <button
        v-if="state && state.phase !== 'purpose'"
        type="button"
        class="text-button change-purpose"
        :disabled="busy"
        @click="
          updateGrowthGuide({
            purpose: state.preference.purpose === 'inbox' ? 'posting' : 'inbox',
            dismissed: false,
          })
        "
      >
        {{
          state.preference.purpose === "inbox"
            ? "投稿から始める"
            : "問い合わせ対応から始める"
        }}
      </button>
    </main>
  </section>
</template>

<style scoped>
.toybaco-start {
  flex: 1;
  overflow: auto;
  background: #faf7f2;
  color: #24303f;
  font-family: -apple-system, BlinkMacSystemFont, "Hiragino Kaku Gothic ProN",
    "Noto Sans JP", sans-serif;
  line-height: 1.7;
}
.toybaco-start header {
  max-width: 960px;
  margin: 0 auto;
  padding: 28px 32px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
}
.toybaco-start header img {
  height: auto;
}
.toybaco-start main {
  max-width: 640px;
  margin: 32px auto;
  padding: 32px;
  background: #fcfbf8;
  border: 1px solid #e7e2da;
  border-radius: 10px;
}
.toybaco-start h1 {
  font-size: 26px;
  color: #1f3a5f;
  line-height: 1.5;
  margin: 0 0 16px;
}
.toybaco-start p {
  font-size: 14px;
  color: #566579;
  margin: 0 0 20px;
}
.toybaco-start .eyebrow {
  font-size: 12px;
  letter-spacing: 0.08em;
  margin: 0 0 8px;
}
.choices {
  display: grid;
  gap: 12px;
}
.choices button,
.unavailable {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 4px;
  padding: 20px;
  background: #fff;
  border: 1px solid #c9ced5;
  border-radius: 10px;
  font: inherit;
  text-align: left;
  color: #1f3a5f;
}
.choices button:hover:not(:disabled) {
  border-color: #1f3a5f;
  background: #f5f7fa;
}
.choices span {
  font-size: 13px;
  color: #566579;
}
.unavailable {
  background: #f3f1ed;
}
.toybaco-start button:disabled {
  cursor: default;
  opacity: 0.6;
}
.toybaco-start .primary {
  display: block;
  background: #1f3a5f;
  color: white;
  border: 0;
  border-radius: 8px;
  min-height: 46px;
  padding: 12px 20px;
  font: inherit;
  font-weight: 600;
  cursor: pointer;
}
.primary:hover:not(:disabled) {
  background: #163049;
}
.toybaco-start form {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.toybaco-start label {
  font-size: 13px;
  font-weight: 600;
}
.toybaco-start input,
.toybaco-start textarea,
.toybaco-start select {
  width: 100%;
  padding: 12px;
  border: 1px solid #c9ced5;
  border-radius: 8px;
  background: white;
  color: #24303f;
  font: inherit;
  margin-bottom: 12px;
}
.toybaco-start textarea {
  resize: vertical;
}
.toybaco-start details {
  margin-bottom: 16px;
}
.toybaco-start details label {
  display: block;
  margin-top: 12px;
}
.toybaco-start summary {
  font-size: 13px;
  cursor: pointer;
}
.toybaco-start small {
  font-size: 11px;
  color: #566579;
  margin-left: 8px;
}
.toybaco-start a,
.text-button {
  font: inherit;
  font-size: 13px;
  color: #1f3a5f;
  text-decoration: underline;
  text-underline-offset: 3px;
}
.text-button {
  background: none;
  border: 0;
  cursor: pointer;
  padding: 0;
}
.change-purpose {
  margin-top: 28px;
}
.toybaco-start .mailbox {
  font-size: 18px;
  color: #1f3a5f;
  overflow-wrap: anywhere;
  padding: 16px;
  background: #eef2f7;
  border-radius: 8px;
}
.inbox-choice {
  margin-top: 24px;
}
.toybaco-start .error {
  border-left: 3px solid #ff6b5b;
  padding: 10px;
  background: #fff0ed;
}
.toybaco-start :focus-visible {
  outline: 3px solid #ff6b5b;
  outline-offset: 3px;
}
@media (max-width: 680px) {
  .toybaco-start header {
    padding: 20px;
  }
  .toybaco-start main {
    margin: 8px 12px 24px;
    padding: 24px;
  }
  .toybaco-start h1 {
    font-size: 22px;
  }
}
</style>
