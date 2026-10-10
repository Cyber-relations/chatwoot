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
  growthAutoReplyPath,
  growthDecideLine,
  growthTourProgress,
  growthFactQuestions,
  growthUnderstanding,
  saveGrowthIndustry,
  GROWTH_FACT_ANSWERS,
} from "dashboard/composables/toybacoGrowthGuide";

const { accountId } = useAccount();
const route = useRoute();
const router = useRouter();
// ダークでは文字が白いロゴに替える(installation/onboarding と同じ切り替え)。
const brandLogoPath = "/brand-assets/toybaco-logo-c4.png";
const brandLogoDarkPath = "/brand-assets/toybaco-logo-c4-dark.png";
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
// 「店舗情報を保存しました」は、保存した時点の段と目的(保存直後の 1 画面)でだけ出す。段か目的が変わったら消す。
// 目的が未設定から値になっただけ(状態の読み直し)では消さない。
let factsSavedStep = [];
watch(
  [() => state.value?.phase, () => state.value?.preference?.purpose],
  ([phase, purpose]) => {
    const [savedPhase, savedPurpose] = factsSavedStep;
    if (
      phase !== savedPhase ||
      (savedPurpose != null && purpose !== savedPurpose)
    )
      factsSaved.value = false;
  },
);
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
// Web チャットの受信の確認: サイトに設置する前でも、同じ origin のウィジェット(/widget)を新しいタブで開けば 1 件送れる。
const widgetPreviewUrl = computed(() => {
  const token = selectedInbox.value?.website_token;
  return token ? `/widget?website_token=${encodeURIComponent(token)}` : "";
});
// 完了画面の「次にやること」1 行。案内した窓口(完了の段で決まっていないときは一覧の先頭)の媒体で出し分ける。
const nextSteps = {
  web_widget: "Webチャットの設置コードを、お店のサイトに貼る",
  instagram: "InstagramのDMに、受信箱から返信する",
  line: "LINEのメッセージに、受信箱から返信する",
  gmail: "届いたメールに、受信箱から返信する",
  microsoft: "届いたメールに、受信箱から返信する",
  // IMAP・転送のメールの受信箱(Gmail・Microsoft の API 以外の Channel::Email)。
  email: "届いたメールに、受信箱から返信する",
};
const nextInbox = computed(
  () => selectedInbox.value || state.value?.inboxes?.[0],
);
const nextStep = computed(() => nextSteps[nextInbox.value?.provider] || "");
// Web チャットの設置コードは、受信箱の設定の「設定」タブ(configuration)にある。受信箱の設定は管理者だけが開ける。
const snippetLink = computed(() =>
  nextInbox.value?.provider === "web_widget" && state.value?.administrator
    ? {
        name: "settings_inbox_show",
        params: {
          accountId: accountId.value,
          inboxId: nextInbox.value.id,
          tab: "configuration",
        },
      }
    : null,
);
// 完了画面の「次にやること」の 2 行目: AI返信の準備(窓口の自動応答の画面)への導線。bot の割当はここではしない。
// 会話画面の AI パネル(toybaco-post-entry.js)と同じく、/toybaco/ai_readiness の managed_auto_path がこの店舗の画面を
// 指すときだけ出す(登録できる店舗か登録済みの店舗にだけ付く)。この API は所属メンバーなら誰にでも path を返すが、
// 窓口の自動応答の画面は管理者しか開けないので、管理者に限る。読むのは管理者に完了画面(と、この窓口の AI返信を決める段。
// 窓口の状態の 1 行と「自動で返す」の行き先に使う)を出したときに 1 回だけで、
// 画面を離れたら捨てる。完了画面から店舗情報を入力して戻ったときは 1 回読み直す(確認済みの店舗情報で準備できるように
// なるため)。読めなかったときは行を出さない(再試行しない。console にも出さない)。
const aiReadiness = ref(null);
let aiReadinessEpoch = 0;
const aiReadinessAccount = () =>
  !showFacts.value &&
  ["complete", "decide"].includes(state.value?.phase) &&
  state.value.administrator
    ? String(accountId.value)
    : "";
async function readAiReadiness(account) {
  aiReadinessEpoch += 1;
  const epoch = aiReadinessEpoch;
  aiReadiness.value = null;
  if (!account) return;
  try {
    const response = await fetch(
      `/toybaco/ai_readiness?account_id=${encodeURIComponent(account)}`,
      {
        credentials: "same-origin",
        cache: "no-store",
        headers: { Accept: "application/json" },
      },
    );
    if (!response.ok || response.redirected) return;
    const data = await response.json();
    if (epoch === aiReadinessEpoch) aiReadiness.value = data;
  } catch {
    // 読めないときは行を出さない。
  }
}
watch(aiReadinessAccount, readAiReadiness, { immediate: true });
// 自動応答の画面から「戻る」で、このページがそのまま復元されたとき(bfcache)は、完了画面なら 1 回読み直す。
function rereadAiReadiness(event) {
  const account = aiReadinessAccount();
  if (event.persisted && account) readAiReadiness(account);
}
window.addEventListener("pageshow", rereadAiReadiness);
// 画面を離れたら、届く途中の応答を捨てる(破棄した画面に書かない)。
onBeforeUnmount(() => {
  aiReadinessEpoch += 1;
  window.removeEventListener("pageshow", rereadAiReadiness);
});
// 接続済み(configured)なら「接続済み」とだけ伝え、それ以外は画面へのリンクにする。1 行目(つないだ窓口)が無いときは出さない。
const aiStep = computed(() => {
  const readiness = aiReadiness.value;
  const path = `/toybaco/growth/automatic-replies?account_id=${encodeURIComponent(accountId.value)}`;
  if (
    !nextStep.value ||
    !state.value?.administrator ||
    readiness?.managed_auto_path !== path
  )
    return null;
  if (readiness.connection === "configured") return { state: "configured" };
  return ["unconnected", "unknown"].includes(readiness.connection)
    ? { state: "connect", href: path }
    : null;
});
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
// 画面の案内(ToybacoGrowthGuide の wantedStep)がこの段で出るときは、見出しの下の場所を先に取っておく。
// 案内が出た瞬間に内容が下がらないようにするため。閉じた案内・案内が指せない段では取らない(空白を残さない)。
// 設定メニューの店舗情報ページでは初回の案内は出ない(サポートの案内だけ)ので、先には取らない。
function keepsGuidePlace(phase) {
  const current = state.value;
  if (
    settingsView.value ||
    !current ||
    current.preference?.dismissed ||
    current.phase !== phase
  )
    return false;
  // 接続の段は、上限に達していても案内が出る(押せるカードが無ければ先へ進むボタンを指す)ので、管理者なら場所を取る。
  if (phase === "connect") return Boolean(current.administrator);
  if (phase === "facts") return Boolean(current.administrator);
  return true;
}
// 段の番号は、管理画面の上のカードと同じ数え方(問い合わせは 店舗情報・窓口・試す・AI返信を決める の 4 段)。
const stepNumber = computed(() => {
  const progress = growthTourProgress(state.value);
  return progress ? `${progress.index} / ${progress.total}` : "";
});
// 段 decide: 案内した窓口の AI返信の状態(サーバーの値のまま)と、「自動で返す」の行き先(窓口の自動応答の登録ページ)。
const decideLine = computed(() =>
  growthDecideLine(aiReadiness.value, state.value?.inbox_id),
);
const autoReplyPath = computed(() =>
  growthAutoReplyPath(aiReadiness.value, accountId.value),
);
const channelStates = {
  ready: "設定済み",
  connected: "接続済み",
  available: "未接続",
  preparing: "準備中(近日対応)",
};
// 段 1b-1: 「AI はこう理解しています」・業種・「よく聞かれること」。どれもサーバーの facts の値だけで描く。
const understanding = computed(() => growthUnderstanding(state.value?.facts));
const industryLabel = computed(() => {
  const facts = state.value?.facts;
  return (
    facts?.industries?.find((choice) => choice.id === facts.industry)?.label ||
    ""
  );
});
function questionsFor(key) {
  return growthFactQuestions(state.value?.facts, key);
}
// 業種は選んだときに保存する(店舗情報の確認とは別)。保存できなかったときも、選択肢はサーバーの値に戻す。
async function chooseIndustry(event) {
  const select = event.target;
  await saveGrowthIndustry(select.value || null);
  select.value = state.value?.facts?.industry || "";
}
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

// 接続の段のカードの並び。押せる未接続 → 接続済み・設定済み → 準備中の順にし、準備中は見出し「審査完了後に使えます」の下に
// まとめる。同じ群の中は、これまでの並び(転送用メール・Google・Microsoft・LINE・Webチャット・Instagram)のまま。
const connectionKeys = [
  "email_forward",
  "gmail",
  "microsoft",
  "line",
  "web_widget",
  "instagram",
];
const connectionGroups = computed(() => {
  const open = [];
  const done = [];
  const preparing = [];
  for (const key of connectionKeys) {
    const rowState = channel(key)?.state;
    // 転送用メールは、開通時に作った店舗にだけ出す。
    if (key === "email_forward" && !rowState) continue;
    if (rowState === "preparing") preparing.push(key);
    else if (rowState === "connected" || rowState === "ready") done.push(key);
    // 押せる未接続と、行が無い・状態が分からないカードは押せる側に置く(押せるかどうかはカードが自分で決める)。
    else open.push(key);
  }
  const main = [...open, ...done];
  // 群が空なら、その群の枠(.choices)は描かない。
  return [
    ...(main.length ? [{ id: "main", keys: main }] : []),
    ...(preparing.length ? [{ id: "preparing", keys: preparing }] : []),
  ];
});
// 接続の段で「つないだ窓口で次へ」を主ボタンにするのは、ガイドが受信・返信まで案内できる窓口(この利用者に見える受信箱)が
// 1 件以上あるとき。接続済みでもガイドが案内できない窓口(提供元が閉じたメール、再認可待ち、所属していない受信箱)しか
// 無いときは押しても進めないので出さず、「あとで設定する」を主ボタンのままにする。
const canProceed = computed(() => (state.value?.inboxes?.length || 0) > 0);

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
  factsSavedStep = [state.value?.phase, state.value?.preference?.purpose];
  factsRequested.value = false;
}

// 「あとで設定する」: この段を先へ進めた段の一覧に加える。サーバーが次の段を決める。
function skipStep(step) {
  updateGrowthGuide({ skipped: [...new Set([...skipped.value, step])] });
}

// 「つないだ窓口で次へ」: つないだ窓口のまま先へ進む。「あとで設定する」ではないので、段を skipped に記録しない。
// 窓口がつながっていても接続の段が残るのは、案内する窓口を 1 つに決められない(複数ある)ときなので、決まっている窓口が
// あればそれを、無ければ一覧の先頭を案内する窓口として記録する(あとから「案内する窓口」で選び直せる)。次の段はサーバーが決める。
function proceed() {
  const [first] = state.value?.inboxes || [];
  if (first) updateGrowthGuide({ inbox_id: state.value.inbox_id ?? first.id });
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
  <section
    class="toybaco-start"
    :class="{
      settings: settingsView,
      'connect-step': !settingsView && !showFacts && state?.phase === 'connect',
    }"
  >
    <header v-if="!settingsView">
      <img :src="brandLogoPath" alt="トイバコ" width="152" class="dark:hidden" />
      <img :src="brandLogoDarkPath" alt="トイバコ" width="152" class="hidden dark:block" />
      <RouterLink
        :to="{
          name: 'home',
          params: { accountId },
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
        <!-- 画面の案内は見出しの下のこの場所に出す(見出しと選択肢に重ねない)。案内が出る段では先に場所を取り、長い案内のときだけ案内側が高さを足す。設定メニューの店舗情報ページでもサポートの案内はここに出る。 -->
        <div
          data-toybaco-guide-slot
          :class="{ reserved: keepsGuidePlace('facts') }"
        ></div>
        <p>
          AIの返信案や投稿文に使います。分かる内容だけで大丈夫です。空欄をAIが推測することはありません。
        </p>
        <section
          v-if="understanding"
          class="understanding"
          aria-labelledby="toybaco-understanding"
        >
          <h2 id="toybaco-understanding">AI はこう理解しています</h2>
          <p id="toybaco-understanding-count">
            店舗情報 {{ understanding.total }} 項目のうち
            {{ understanding.filled }} 項目が入力済み
          </p>
          <div
            class="meter"
            role="progressbar"
            aria-labelledby="toybaco-understanding-count"
            aria-valuemin="0"
            :aria-valuemax="understanding.total"
            :aria-valuenow="understanding.filled"
          >
            <span
              :style="{
                width: `${(understanding.filled / understanding.total) * 100}%`,
              }"
            ></span>
          </div>
          <template v-if="!state.facts.confirmed">
            <p v-if="state.administrator" class="notice">
              まだ確認されていません。保存すると AI返信が使い始めます。
            </p>
            <p v-else class="notice">
              まだ確認されていません。店舗の管理者が保存すると
              AI返信が使い始めます。
            </p>
          </template>
          <div
            v-if="state.administrator && !state.facts.industry_fixed"
            class="industry"
          >
            <label for="toybaco-facts-industry">業種</label>
            <select
              id="toybaco-facts-industry"
              :value="state.facts.industry || ''"
              :disabled="busy"
              data-toybaco-industry
              @change="chooseIndustry"
            >
              <option value="">指定なし</option>
              <option
                v-for="choice in state.facts.industries"
                :key="choice.id"
                :value="choice.id"
              >
                {{ choice.label }}
              </option>
            </select>
          </div>
          <p v-else-if="industryLabel" class="industry">
            業種: {{ industryLabel }}
          </p>
          <table>
            <thead>
              <tr>
                <th scope="col">項目</th>
                <th scope="col">状態</th>
                <th scope="col">お客さまに聞かれたら</th>
              </tr>
            </thead>
            <tbody>
              <tr
                v-for="row in understanding.rows"
                :key="row.key"
                :data-toybaco-fact="row.key"
              >
                <th scope="row">{{ row.label }}</th>
                <td>{{ row.filled ? "入力済み" : "未入力" }}</td>
                <td>
                  {{
                    row.filled
                      ? GROWTH_FACT_ANSWERS.filled
                      : GROWTH_FACT_ANSWERS.missing
                  }}
                </td>
              </tr>
            </tbody>
          </table>
        </section>
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
            :aria-describedby="
              questionsFor('hours').length
                ? 'toybaco-facts-hours-asked'
                : undefined
            "
          />
          <p
            v-if="questionsFor('hours').length"
            id="toybaco-facts-hours-asked"
            class="asked"
          >
            よく聞かれること: {{ questionsFor("hours").join(" / ") }}
          </p>
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
                :aria-describedby="
                  questionsFor(field.key).length
                    ? `toybaco-facts-${field.key}-asked`
                    : undefined
                "
              />
              <p
                v-if="questionsFor(field.key).length"
                :id="`toybaco-facts-${field.key}-asked`"
                class="asked"
              >
                よく聞かれること: {{ questionsFor(field.key).join(" / ") }}
              </p>
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
        <div
          data-toybaco-guide-slot
          :class="{ reserved: keepsGuidePlace('purpose') }"
        ></div>
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
        <div
          data-toybaco-guide-slot
          :class="{ reserved: keepsGuidePlace('connect') }"
        ></div>
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
        <!-- カードは connectionGroups の順(押せる未接続 → 接続済み・設定済み → 準備中)。準備中は見出しの下にまとめる。 -->
        <template v-for="group in connectionGroups" :key="group.id">
          <h2
            v-if="group.id === 'preparing'"
            id="toybaco-connections-preparing"
            class="group-heading"
          >
            審査完了後に使えます
          </h2>
          <div
            class="choices"
            :data-toybaco-connection-group="group.id"
            :role="group.id === 'preparing' ? 'group' : undefined"
            :aria-labelledby="
              group.id === 'preparing'
                ? 'toybaco-connections-preparing'
                : undefined
            "
          >
            <template v-for="key in group.keys" :key="key">
              <div
                v-if="key === 'email_forward'"
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
                v-else-if="key === 'gmail'"
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
                v-else-if="key === 'microsoft'"
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
                v-else-if="key === 'line'"
                type="button"
                data-toybaco-guide-action="connection.line"
                data-toybaco-connection="line"
                :disabled="
                  !state.administrator ||
                  connecting ||
                  atLimit ||
                  channel('line')?.state === 'preparing'
                "
                @click="openChannel('line')"
              >
                <strong>LINE公式</strong
                ><span>管理者による初期設定が必要です</span
                ><span class="state">{{ channelState("line") }}</span>
              </button>
              <button
                v-else-if="key === 'web_widget'"
                type="button"
                data-toybaco-guide-action="connection.web_widget"
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
                v-else-if="
                  key === 'instagram' &&
                  channel('instagram')?.state !== 'preparing'
                "
                type="button"
                data-toybaco-guide-action="connection.instagram"
                data-toybaco-connection="instagram"
                :disabled="
                  !state.administrator ||
                  connecting ||
                  atLimit ||
                  channel('instagram')?.state === 'connected'
                "
                @click="openChannel('instagram')"
              >
                <strong>Instagram</strong
                ><span>InstagramのDMを受け取ります</span
                ><span class="state">{{ channelState("instagram") }}</span>
              </button>
              <div
                v-else-if="key === 'instagram'"
                class="unavailable"
                data-toybaco-connection="instagram"
              >
                <strong>Instagram</strong
                ><span>InstagramのDMを受け取ります</span
                ><span class="state">{{ channelState("instagram") }}</span>
              </div>
            </template>
          </div>
        </template>
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
        <!-- 案内できる窓口があれば「つないだ窓口で次へ」が主ボタンで、「あとで設定する」は副リンク。無ければ「あとで設定する」が主ボタン。
             押せるカードが 1 つも無いとき、画面の案内はこのどちらかを指す(connection.next / connection.skip)。 -->
        <div class="later" :class="{ next: canProceed }">
          <button
            v-if="canProceed"
            class="primary"
            type="button"
            data-toybaco-guide-next="connect"
            data-toybaco-guide-action="connection.next"
            :disabled="busy"
            @click="proceed"
          >
            つないだ窓口で次へ
          </button>
          <button
            type="button"
            :class="canProceed ? 'text-button' : 'primary'"
            data-toybaco-guide-skip="connect"
            data-toybaco-guide-action="connection.skip"
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
        <div
          v-else-if="selectedInbox?.provider === 'web_widget'"
          data-toybaco-receive="web_widget"
        >
          <p>
            サイトに設置コードを貼ると問い合わせが届きます。今すぐ試すなら、プレビューから1件送ってください。
          </p>
          <a
            v-if="widgetPreviewUrl"
            class="preview-link"
            :href="widgetPreviewUrl"
            target="_blank"
            rel="noopener noreferrer"
            >プレビューで送る</a
          >
        </div>
        <p
          v-else-if="selectedInbox?.provider === 'instagram'"
          data-toybaco-receive="instagram"
        >
          接続したInstagramのDMを受け取ります。テスト用に1件送ってください。
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
        <div
          data-toybaco-guide-slot
          :class="{ reserved: keepsGuidePlace('reply') }"
        ></div>
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
        <div
          data-toybaco-guide-slot
          :class="{ reserved: keepsGuidePlace('posting') }"
        ></div>
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
      <template v-else-if="state?.phase === 'decide'">
        <h1>この窓口の AI返信を決める</h1>
        <p v-if="decideLine" class="summary" data-toybaco-decide-line>
          {{ decideLine.text }}
        </p>
        <p v-if="decideLine?.reason">{{ decideLine.reason }}</p>
        <template v-if="state.administrator">
          <div class="choices">
            <a
              v-if="state.facts?.confirmed && autoReplyPath"
              class="choice-link"
              :href="autoReplyPath"
              data-toybaco-decide="auto"
              ><strong>自動で返す</strong
              ><span>窓口の自動応答を登録します</span></a
            >
            <button
              v-else-if="!state.facts?.confirmed"
              type="button"
              data-toybaco-decide="facts"
              @click="openFacts"
            >
              <strong>店舗情報を開く</strong
              ><span>自動で返すには、先に店舗情報の確認が要ります</span>
            </button>
            <button
              type="button"
              data-toybaco-decide="draft_only"
              :disabled="busy"
              @click="updateGrowthGuide({ ai_reply_choice: 'draft_only' })"
            >
              <strong>まずは返信案だけ使う</strong
              ><span>AIの返信案を確認してから、人が送ります</span>
            </button>
          </div>
        </template>
        <p v-else>AI返信の使い方は、店舗の管理者が決めます。</p>
        <div class="later">
          <button
            type="button"
            class="text-button"
            data-toybaco-guide-skip="decide"
            :disabled="busy"
            @click="skipStep('decide')"
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
        <p v-if="nextStep" class="next-step" data-toybaco-next-step>
          <strong>次にやること</strong><span>{{ nextStep }}</span
          ><RouterLink v-if="snippetLink" :to="snippetLink"
            >設置コードを見る</RouterLink
          ><span v-else-if="nextInbox?.provider === 'web_widget'"
            >(店舗の管理者が行えます)</span
          >
        </p>
        <!-- 「次にやること」の 2 行目。窓口の自動応答の画面は Rails の単独ページなので、通常のリンクで開く。 -->
        <p v-if="aiStep" class="next-step" :data-toybaco-ai-step="aiStep.state">
          <a v-if="aiStep.href" :href="aiStep.href">AI返信を接続する</a
          ><span v-else>AI返信は接続済みです</span>
        </p>
        <!-- 「ホームへ」は主ボタン。最初の返信を送った画面では「受信箱を開く」が主ボタンなので、枠線のボタンにする。 -->
        <RouterLink
          class="home-link"
          :class="{ secondary: state.replied }"
          :to="{
            name: 'home',
            params: { accountId },
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
  background: var(--toybaco-offwhite);
  color: var(--toybaco-ink);
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
  background: var(--toybaco-surface);
  border: 1px solid var(--toybaco-hairline);
  border-radius: 10px;
}
.toybaco-start h1 {
  font-size: 26px;
  color: var(--toybaco-heading);
  line-height: 1.5;
  margin: 0 0 16px;
}
.toybaco-start p {
  font-size: 14px;
  color: var(--toybaco-muted);
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
.choices .choice-link,
.unavailable {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 4px;
  padding: 20px;
  background: var(--toybaco-card);
  border: 1px solid var(--toybaco-control-border);
  border-radius: 10px;
  font: inherit;
  text-align: left;
  color: var(--toybaco-heading);
}
.choices button:hover:not(:disabled),
.choices .choice-link:hover {
  border-color: var(--toybaco-heading);
  background: var(--toybaco-wash);
}
.choices .choice-link {
  text-decoration: none;
}
.choices span {
  font-size: 13px;
  color: var(--toybaco-muted);
  overflow-wrap: anywhere;
}
.choices .state {
  font-size: 12px;
  font-weight: 600;
  color: var(--toybaco-heading);
}
.unavailable {
  background: var(--toybaco-wash);
}
.toybaco-start button:disabled {
  cursor: default;
  opacity: 0.6;
}
.toybaco-start .primary {
  display: block;
  background: var(--toybaco-button);
  color: var(--toybaco-on-button);
  border: 0;
  border-radius: 8px;
  min-height: 46px;
  padding: 12px 20px;
  font: inherit;
  font-weight: 600;
  cursor: pointer;
}
.primary:hover:not(:disabled) {
  background: var(--toybaco-button-hover);
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
  border: 1px solid var(--toybaco-control-border);
  border-radius: 8px;
  background: var(--toybaco-card);
  color: var(--toybaco-ink);
  font: inherit;
  margin-bottom: 12px;
}
.toybaco-start textarea {
  resize: vertical;
}
.toybaco-start details {
  margin-bottom: 16px;
}
/* 段 1b-1: 「AI はこう理解しています」と「よく聞かれること」。 */
.toybaco-start .understanding {
  margin: 0 0 24px;
  padding: 16px;
  border: 1px solid var(--toybaco-hairline);
  border-radius: 12px;
  background: var(--toybaco-card);
}
.toybaco-start .understanding h2 {
  margin: 0 0 8px;
  font-size: 16px;
  color: var(--toybaco-heading);
}
.toybaco-start .understanding p {
  margin: 0 0 8px;
}
.toybaco-start .meter {
  height: 8px;
  margin: 0 0 12px;
  border-radius: 4px;
  background: var(--toybaco-wash);
  overflow: hidden;
}
.toybaco-start .meter span {
  display: block;
  height: 100%;
  background: var(--toybaco-heading);
}
.toybaco-start .understanding .notice {
  margin-bottom: 12px;
}
.toybaco-start .industry select {
  margin-top: 4px;
}
.toybaco-start .understanding table {
  width: 100%;
  border-collapse: collapse;
  font-size: 13px;
}
.toybaco-start .understanding th,
.toybaco-start .understanding td {
  padding: 6px 8px;
  border-top: 1px solid var(--toybaco-hairline);
  text-align: left;
  vertical-align: top;
}
.toybaco-start .understanding thead th {
  border-top: 0;
  font-size: 12px;
  color: var(--toybaco-muted);
}
.toybaco-start .asked {
  margin: -8px 0 12px;
  font-size: 12px;
  color: var(--toybaco-muted);
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
  color: var(--toybaco-muted);
  margin-left: 8px;
}
.toybaco-start a,
.text-button {
  font: inherit;
  font-size: 13px;
  color: var(--toybaco-heading);
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
  display: block;
  margin-top: 28px;
}
/* 案内の場所: 1 行の案内(82.4px)+ 間隔 16px。toybaco-pointer-guide.mjs の slotPlacement と同じ基準で、
   1280・768・390 幅の実測値。案内が折り返して高くなるときだけ、案内側が高さを足す。 */
[data-toybaco-guide-slot].reserved {
  min-height: 99px;
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
  color: var(--toybaco-heading);
}
.toybaco-start .notice,
.toybaco-start .saved {
  border-left: 3px solid var(--toybaco-heading);
  padding: 10px;
  background: var(--toybaco-wash);
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
  background: var(--toybaco-card);
  border: 1px solid var(--toybaco-hairline);
  border-radius: 8px;
  font-size: 14px;
}
.toybaco-start .home-link {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-height: 46px;
  margin-top: 8px;
  padding: 12px 20px;
  background: var(--toybaco-button);
  border: 1px solid var(--toybaco-button);
  border-radius: 8px;
  color: var(--toybaco-on-button);
  font-size: 14px;
  font-weight: 600;
  text-decoration: none;
}
.toybaco-start .home-link:hover {
  background: var(--toybaco-button-hover);
}
.toybaco-start .home-link.secondary {
  background: var(--toybaco-card);
  border-color: var(--toybaco-heading);
  color: var(--toybaco-heading);
}
.toybaco-start .home-link.secondary:hover {
  background: var(--toybaco-wash);
}
.toybaco-start .group-heading {
  margin: 24px 0 12px;
  font-size: 13px;
  font-weight: 600;
  line-height: 1.5;
  color: var(--toybaco-muted);
}
.toybaco-start .later.next {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 12px 20px;
}
.toybaco-start .preview-link {
  display: inline-flex;
  align-items: center;
  min-height: 44px;
  margin: 0 0 20px;
  padding: 10px 18px;
  background: var(--toybaco-card);
  border: 1px solid var(--toybaco-heading);
  border-radius: 8px;
  font-size: 14px;
  font-weight: 600;
  text-decoration: none;
}
.toybaco-start .preview-link:hover {
  background: var(--toybaco-wash);
}
.toybaco-start .next-step {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 4px 12px;
  padding: 12px 16px;
  background: var(--toybaco-wash);
  border-left: 3px solid var(--toybaco-heading);
  color: var(--toybaco-ink);
}
.toybaco-start .next-step strong {
  font-size: 12px;
  color: var(--toybaco-heading);
}
/* 「次にやること」の 2 行目(AI返信の行)は 1 行目の枠に続けて 1 つの枠に見せる。行の間は 1 行目の下の余白(12px)。 */
.toybaco-start .next-step + .next-step {
  margin-top: -20px;
  padding-top: 0;
}
.toybaco-start .mailbox {
  font-size: 18px;
  color: var(--toybaco-heading);
  overflow-wrap: anywhere;
  padding: 16px;
  background: var(--toybaco-wash);
  border-radius: 8px;
}
.inbox-choice {
  margin-top: 24px;
}
.toybaco-start .error {
  border-left: 3px solid var(--toybaco-coral);
  padding: 10px;
  background: var(--toybaco-notice-wash);
}
.toybaco-start :focus-visible {
  outline: 3px solid var(--toybaco-focus);
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
  /* 接続の段の案内「使う窓口を1つ選んでください。あとから追加できます。」は、この幅では 2 行(104.8px)になる。
     案内が出た瞬間に窓口のカードが下がらないよう、2 行分(+ 間隔 16px)を先に取る。 */
  .toybaco-start.connect-step [data-toybaco-guide-slot].reserved {
    min-height: 121px;
  }
}
</style>
