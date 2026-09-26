<script setup>
import { computed, onBeforeUnmount, reactive, ref, watch } from "vue";
import { useRoute, useRouter } from "vue-router";
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
const route = useRoute();
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
const factsSaved = ref(false);
// 店舗情報は、ガイドの最初の画面と設定メニューからいつでも開ける(接続の段を通らなくても入力できる)。
const settingsView = computed(
  () => route.name === "toybaco_store_facts_settings",
);
const factsRequested = ref(false);
const showFacts = computed(
  () =>
    Boolean(state.value) &&
    (settingsView.value ||
      factsRequested.value ||
      state.value.phase === "facts"),
);
const selectedInbox = computed(() =>
  state.value?.inboxes.find((inbox) => inbox.id === state.value.inbox_id),
);
const skipped = computed(() => state.value?.preference?.skipped || []);
// 画面を開いて済ませた段(投稿画面を開いた投稿の段)。「あとで設定する」とは分けて記録する。
const opened = computed(() => state.value?.preference?.opened || []);
// 完了画面で投稿の準備を案内するのは、「あとで設定する」にして、投稿画面を開いていないときだけ。
const postingLeft = computed(
  () => skipped.value.includes("posting") && !opened.value.includes("posting"),
);
const connections = computed(
  () => state.value?.connections || { count: 0, limit: null, channels: [] },
);
const atLimit = computed(
  () =>
    connections.value.limit !== null &&
    connections.value.limit !== undefined &&
    connections.value.count >= connections.value.limit,
);
const stepNumber = computed(() => {
  const steps = state.value?.steps || [];
  const index = steps.indexOf(state.value?.phase);
  return index < 0 ? "" : `${index + 1} / ${steps.length}`;
});
const channelStates = {
  ready: "設定済み",
  connected: "接続済み",
  available: "未接続",
  preparing: "準備中(近日対応)",
};
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
    factsSaved.value = false;
    factsRequested.value = false;
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

function channel(key) {
  return connections.value.channels.find((row) => row.key === key);
}

function channelState(key) {
  return channelStates[channel(key)?.state] || "";
}

async function connectProvider(provider) {
  const selected = providers[provider];
  if (
    connecting.value ||
    atLimit.value ||
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

function openChannel(subPage) {
  if (!state.value?.administrator || atLimit.value) return;
  router.push({
    name: "settings_inboxes_page_channel",
    params: { accountId: accountId.value, sub_page: subPage },
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

function openFacts() {
  factsSaved.value = false;
  factsRequested.value = true;
}

async function saveFacts() {
  const result = await saveGrowthFacts({ ...fields });
  if (!result) return;
  edited.value = false;
  factsSaved.value = true;
  factsRequested.value = false;
}

// 「あとで設定する」: この段を先へ進めた段の一覧に加える。サーバーが次の段を決める。
function skipStep(step) {
  updateGrowthGuide({ skipped: [...new Set([...skipped.value, step])] });
}

function resumeSteps(...steps) {
  updateGrowthGuide({
    skipped: skipped.value.filter((step) => !steps.includes(step)),
    dismissed: false,
  });
}

// 投稿画面を開いたら投稿の段は済み(「あとで設定する」ではない)。投稿の作成は投稿画面側で続ける。
async function openPosting() {
  if (!opened.value.includes("posting"))
    await updateGrowthGuide({ opened: [...opened.value, "posting"] });
  router.push({
    name: "home",
    params: { accountId: accountId.value },
    hash: "#/toybaco/posting",
  });
}
</script>

<template>
  <section class="toybaco-start" :class="{ settings: settingsView }">
    <header v-if="!settingsView">
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
      <p class="eyebrow">
        {{ settingsView ? "設定" : "お店の準備"
        }}<span v-if="!settingsView && !factsRequested && stepNumber">
          · {{ stepNumber }}</span
        >
      </p>
      <p v-if="error" role="alert" class="error">
        {{ error }}
        <button type="button" class="text-button" @click="refreshGrowthGuide">
          再読み込み
        </button>
      </p>
      <p v-if="!state && !error" role="status">準備しています…</p>
      <p v-if="factsSaved && !showFacts" role="status" class="saved">
        店舗情報を保存しました。
      </p>
      <template v-if="showFacts">
        <h1>{{ settingsView ? "店舗情報" : "AIにお店のことを伝える" }}</h1>
        <p>
          AIの返信案や投稿文に使います。分かる内容だけで大丈夫です。空欄をAIが推測することはありません。
        </p>
        <form
          v-if="state.administrator"
          @submit.prevent="saveFacts"
          @input="
            edited = true;
            factsSaved = false;
          "
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
        <p v-else>店舗の管理者がお店情報を入力・確認します。</p>
        <p v-if="factsSaved" role="status" class="saved">保存しました。</p>
        <div v-if="!settingsView" class="later">
          <button
            v-if="factsRequested"
            type="button"
            class="text-button"
            @click="factsRequested = false"
          >
            案内に戻る
          </button>
          <button
            v-else
            type="button"
            class="text-button"
            data-toybaco-guide-skip="facts"
            :disabled="busy"
            @click="skipStep('facts')"
          >
            あとで設定する
          </button>
        </div>
      </template>
      <template v-else-if="state?.phase === 'purpose'">
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
        <p class="later">
          <button
            type="button"
            class="text-button"
            data-toybaco-guide-action="facts.open"
            @click="openFacts"
          >
            先に店舗情報を入力する
          </button>
          <span>(AIの返信案・投稿文に使います。設定メニューの「店舗情報」からも開けます)</span>
        </p>
      </template>
      <template v-else-if="state?.phase === 'connect'">
        <h1>使う窓口をつなぎましょう</h1>
        <p>アカウントを選んで、トイバコの利用を許可します。</p>
        <p class="summary">
          接続済みの受信箱: {{ connections.count }}件<span
            v-if="connections.limit !== null && connections.limit !== undefined"
            >(このプランの上限: {{ connections.limit }}件)</span
          >
        </p>
        <p v-if="atLimit" role="status" class="notice">
          このプランでは受信箱を{{ connections.limit }}件まで接続できます(現在{{
            connections.count
          }}件)。<span v-if="connections.free"
            >上位プランへの変更は「ご契約内容」の「有料プランを見る」から行えます。</span
          ><span v-else
            >プランの変更やご不明な点は、サポートへお問い合わせください。</span
          >
        </p>
        <div class="choices">
          <div
            v-if="channel('email_forward')"
            class="unavailable"
            data-toybaco-connection="email_forward"
          >
            <strong>メール(転送用)</strong
            ><span v-if="channel('email_forward').address"
              >お店のメールを {{ channel("email_forward").address }}
              へ転送すると、受信箱に届きます。</span
            ><span class="state">{{ channelState("email_forward") }}</span>
          </div>
          <button
            type="button"
            data-toybaco-guide-action="connection.google"
            data-toybaco-connection="gmail"
            :disabled="
              !state.gmail_available ||
              !state.administrator ||
              connecting ||
              atLimit
            "
            @click="connectProvider('google')"
          >
            <strong>{{
              connecting === "google"
                ? "接続画面を開いています…"
                : "Googleで接続"
            }}</strong
            ><span>Gmail・Google Workspace</span
            ><span class="state">{{ channelState("gmail") }}</span>
          </button>
          <button
            type="button"
            data-toybaco-guide-action="connection.microsoft"
            data-toybaco-connection="microsoft"
            :disabled="
              !state.microsoft_available ||
              !state.administrator ||
              connecting ||
              atLimit
            "
            @click="connectProvider('microsoft')"
          >
            <strong>{{
              connecting === "microsoft"
                ? "接続画面を開いています…"
                : "Microsoftで接続"
            }}</strong
            ><span>Outlook・Microsoft 365</span
            ><span class="state">{{ channelState("microsoft") }}</span>
          </button>
          <button
            type="button"
            data-toybaco-guide-action="connection.line"
            data-toybaco-connection="line"
            :disabled="!state.administrator || connecting || atLimit"
            @click="openChannel('line')"
          >
            <strong>LINE公式</strong
            ><span>管理者による初期設定が必要です</span
            ><span class="state">{{ channelState("line") }}</span>
          </button>
          <button
            type="button"
            data-toybaco-connection="web_widget"
            :disabled="
              !state.administrator ||
              connecting ||
              atLimit ||
              channel('web_widget')?.state === 'preparing'
            "
            @click="openChannel('website')"
          >
            <strong>Webチャット</strong
            ><span>お店のサイトに問い合わせ窓口を置きます</span
            ><span class="state">{{ channelState("web_widget") }}</span>
          </button>
          <button
            v-if="channel('instagram')?.state !== 'preparing'"
            type="button"
            data-toybaco-connection="instagram"
            :disabled="
              !state.administrator ||
              connecting ||
              atLimit ||
              channel('instagram')?.state === 'connected'
            "
            @click="openChannel('instagram')"
          >
            <strong>Instagram</strong><span>InstagramのDMを受け取ります</span
            ><span class="state">{{ channelState("instagram") }}</span>
          </button>
          <div v-else class="unavailable" data-toybaco-connection="instagram">
            <strong>Instagram</strong><span>InstagramのDMを受け取ります</span
            ><span class="state">{{ channelState("instagram") }}</span>
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
        <div class="later">
          <button
            type="button"
            class="text-button"
            data-toybaco-guide-skip="connect"
            :disabled="busy"
            @click="skipStep('connect')"
          >
            あとで設定する
          </button>
        </div>
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
        <div class="later">
          <button
            type="button"
            class="text-button"
            data-toybaco-guide-skip="receive"
            :disabled="busy"
            @click="skipStep('receive')"
          >
            あとで設定する
          </button>
        </div>
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
        <div class="later">
          <button
            type="button"
            class="text-button"
            data-toybaco-guide-skip="reply"
            :disabled="busy"
            @click="skipStep('reply')"
          >
            あとで設定する
          </button>
        </div>
      </template>
      <template v-else-if="state?.phase === 'posting'">
        <h1>お店の発信を始めましょう</h1>
        <p>投稿先をつないで、最初の投稿を準備します。</p>
        <button
          class="primary"
          type="button"
          data-toybaco-guide-action="posting.open"
          :disabled="busy"
          @click="openPosting"
        >
          投稿画面を開く
        </button>
        <div class="later">
          <button
            type="button"
            class="text-button"
            data-toybaco-guide-skip="posting"
            :disabled="busy"
            @click="skipStep('posting')"
          >
            あとで設定する
          </button>
        </div>
      </template>
      <template v-else-if="state?.phase === 'complete'">
        <template v-if="state.replied">
          <h1>最初の返信を送信しました</h1>
          <p>これで、この窓口から対応を始められます。</p>
          <button class="primary" type="button" @click="openConversation">
            受信箱を開く
          </button>
        </template>
        <template v-else>
          <h1>お店の準備ができました</h1>
          <p>あとで設定した項目は、いつでもここから続けられます。</p>
        </template>
        <ul
          v-if="
            state.pending?.length ||
            skipped.includes('receive') ||
            skipped.includes('reply') ||
            postingLeft
          "
          class="pending"
        >
          <li v-if="state.pending?.includes('facts')">
            <span>店舗情報(AIの返信案・投稿文に使います)</span
            ><button
              type="button"
              class="text-button"
              data-toybaco-guide-resume="facts"
              @click="openFacts"
            >
              入力する
            </button>
          </li>
          <li v-if="state.pending?.includes('connect')">
            <span>受信箱の接続</span
            ><button
              type="button"
              class="text-button"
              data-toybaco-guide-resume="connect"
              :disabled="busy"
              @click="resumeSteps('connect')"
            >
              つなぐ
            </button>
          </li>
          <li v-if="postingLeft">
            <span>投稿の準備</span
            ><button
              type="button"
              class="text-button"
              data-toybaco-guide-resume="posting"
              :disabled="busy"
              @click="resumeSteps('posting')"
            >
              続ける
            </button>
          </li>
          <li
            v-if="
              state.inbox_id &&
              !state.replied &&
              (skipped.includes('receive') || skipped.includes('reply'))
            "
          >
            <span>受信と返信の練習</span
            ><button
              type="button"
              class="text-button"
              data-toybaco-guide-resume="receive"
              :disabled="busy"
              @click="resumeSteps('receive', 'reply')"
            >
              続ける
            </button>
          </li>
        </ul>
        <RouterLink
          class="home-link"
          :to="{
            name: 'home',
            params: { accountId },
            query: { toybaco_skip_tour: '1' },
          }"
          >ホームへ</RouterLink
        >
      </template>
      <div
        v-if="!settingsView && !showFacts && state?.inboxes.length > 1"
        class="inbox-choice"
      >
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
        v-if="
          state && state.phase !== 'purpose' && !settingsView && !factsRequested
        "
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
  overflow-wrap: anywhere;
}
.choices .state {
  font-size: 12px;
  font-weight: 600;
  color: #1f3a5f;
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
.toybaco-start .later {
  margin-top: 20px;
}
.toybaco-start p.later span {
  display: block;
  font-size: 12px;
  margin-top: 4px;
}
.toybaco-start .summary {
  font-weight: 600;
  color: #1f3a5f;
}
.toybaco-start .notice,
.toybaco-start .saved {
  border-left: 3px solid #1f3a5f;
  padding: 10px;
  background: #eef2f7;
}
.toybaco-start .saved {
  margin-top: 12px;
}
.toybaco-start .pending {
  list-style: none;
  margin: 0 0 20px;
  padding: 0;
  display: grid;
  gap: 8px;
}
.toybaco-start .pending li {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 12px;
  padding: 12px 16px;
  background: #fff;
  border: 1px solid #e7e2da;
  border-radius: 8px;
  font-size: 14px;
}
.toybaco-start .home-link {
  display: inline-block;
  margin-top: 8px;
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
.toybaco-start.settings main {
  margin: 24px;
}
@media (max-width: 680px) {
  .toybaco-start header {
    padding: 20px;
  }
  .toybaco-start main {
    margin: 8px 12px 24px;
    padding: 24px;
  }
  .toybaco-start.settings main {
    margin: 8px 12px 24px;
  }
  .toybaco-start h1 {
    font-size: 22px;
  }
}
</style>
