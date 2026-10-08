<script setup>
import {
  computed,
  nextTick,
  onBeforeUnmount,
  onMounted,
  ref,
  watch,
} from 'vue';
import { useRoute, useRouter } from 'vue-router';
import {
  supportGuideArticles,
  supportGuideStep,
} from 'dashboard/helper/toybacoSupportQuestion';
import { useAccount } from 'dashboard/composables/useAccount';
import {
  growthGuideState as state,
  growthGuideError,
  growthGuideBusy,
  growthTourCard,
  growthTourProgress,
  refreshGrowthGuide,
  selectGrowthGuideAccount,
  updateGrowthGuide,
  GROWTH_TOUR_REPLY_HINTS,
} from 'dashboard/composables/toybacoGrowthGuide';
import ToybacoTour from './ToybacoTour.vue';

const { accountId, currentAccount } = useAccount();
const route = useRoute();
const router = useRouter();
const paused = ref(false);
let supportStep = null;
let availability = '';
const supportEnabled = computed(
  () => currentAccount.value?.toybaco_support === true
);
const inSetup = computed(() => route.name === 'toybaco_growth_start');
const enabled = computed(
  () => currentAccount.value?.toybaco_growth_onboarding === true
);
let registry;
let guide;
let guideModule;
let observer;
let scanFrame;
let poll;
let disposed = false;
let lastStep;
const targets = new Map();
const selectors = {
  'purpose.inbox': '[data-toybaco-guide-action="purpose.inbox"]',
  'connection.google': '[data-toybaco-guide-action="connection.google"]',
  'connection.microsoft': '[data-toybaco-guide-action="connection.microsoft"]',
  'connection.line': '[data-toybaco-guide-action="connection.line"]',
  'connection.web_widget':
    '[data-toybaco-guide-action="connection.web_widget"]',
  'connection.instagram': '[data-toybaco-guide-action="connection.instagram"]',
  'connection.next': '[data-toybaco-guide-action="connection.next"]',
  'connection.skip': '[data-toybaco-guide-action="connection.skip"]',
  'facts.confirm': '[data-toybaco-guide-action="facts.confirm"]',
  'reply.open': '[data-toybaco-guide-action="reply.open"]',
  'reply.ai_draft': '[data-toybaco-guide-action="reply.ai_draft"]',
  'reply.editor':
    '[data-toybaco-guide-reply="public"] [contenteditable="true"]',
  'reply.send': '[data-toybaco-guide-action="reply.send"]',
  'posting.open': '[data-toybaco-guide-action="posting.open"]',
  // 段 1a のツアーの的: サイドバーの「店舗情報」「受信箱」と、窓口を追加する画面の媒体。
  'sidebar.store_facts': '[data-toybaco-guide-action="sidebar.store_facts"]',
  'sidebar.inboxes': '[data-toybaco-guide-action="sidebar.inboxes"]',
  'channel.website': '[data-toybaco-guide-action="channel.website"]',
  'channel.line': '[data-toybaco-guide-action="channel.line"]',
  'channel.email': '[data-toybaco-guide-action="channel.email"]',
  'channel.instagram': '[data-toybaco-guide-action="channel.instagram"]',
};
const setupSteps = {
  purpose: ['purpose.inbox', '最初に使いたい仕事を選んでください。'],
  connect: [
    'connection.google',
    '使う窓口を1つ選んでください。あとから追加できます。',
  ],
  facts: ['facts.confirm', 'お店情報を確認して保存してください。'],
  reply: ['reply.open', '届いたメッセージを開いてみましょう。'],
  posting: ['posting.open', '投稿画面で発信の準備を始めます。'],
};
// 接続の段: 案内は段の指示(setupSteps.connect)にして、カードに focus/hover している間だけ、そのカードで何が開くかを出す。
const connectionHints = {
  'connection.google': 'Googleのアカウントを選んで接続します。',
  'connection.microsoft': 'Microsoftのアカウントを選んで接続します。',
  'connection.line': 'LINE公式の接続設定を開きます。',
  'connection.web_widget': 'Webチャットの作成画面を開きます。',
  'connection.instagram': 'Instagramの接続画面を開きます。',
};
// 押せるカードが 1 つも無い(上限に達した・すべて準備中)ときは、カードではなく先へ進むボタン
// (「つないだ窓口で次へ」、無ければ「あとで設定する」)を指す。
const connectionFallback = [
  ['connection.next', 'connection.skip'],
  '接続はあとからでも追加できます。次へ進みましょう。',
];
// 窓口のカード(data-toybaco-connection を持つもの)だけ。先へ進むボタンは含めない。
const connectionCards = '[data-toybaco-connection][data-toybaco-guide-action]';
let hoveredCard = null;
let focusedCard = null;
let connectionTouched = false;

function hasConnectionHint(id) {
  return Object.prototype.hasOwnProperty.call(connectionHints, id);
}

function connectionStep() {
  if (!state.value.administrator) return null;
  const touched = hoveredCard || focusedCard;
  if (
    touched &&
    hasConnectionHint(touched) &&
    registry.find(touched, document)
  )
    return [touched, connectionHints[touched]];
  // 指す先は、並びの先頭にある押せるカード(押せる未接続のカードが上に並ぶ)。
  const first = [...document.querySelectorAll(connectionCards)]
    .map(card => card.dataset.toybacoGuideAction)
    .find(id => hasConnectionHint(id) && registry.find(id, document));
  if (first) return [first, setupSteps.connect[1]];
  const next = connectionFallback[0].find(id => registry.find(id, document));
  return next ? [next, connectionFallback[1]] : null;
}

function wantedStep() {
  if (
    supportStep &&
    supportEnabled.value &&
    supportStep.accountId === String(accountId.value)
  )
    return supportGuideStep(supportStep.articleId);
  if (!state.value || paused.value || state.value.preference.dismissed)
    return null;
  if (inSetup.value && state.value.phase === 'connect') return connectionStep();
  if (inSetup.value) return setupSteps[state.value.phase] || null;
  // 案内の画面の外では、ツアーのカード(ToybacoTour)が文とボタンを持つ。ここでは文付きの案内を出さない。
  return null;
}

// 段 1a: 本物の管理画面の上のカード。開いた画面がツアーの画面(toybaco_growth_start)のときと、サポートの「画面で案内」の
// 間は出さない(どちらも文付きの案内を使う)。「あとで続ける」の後は上部の帯の「設定を続ける」で戻す。
const replyHint = ref(null);
// 段 decide の readiness は、読んだ店舗と組で持つ({ account, data }。data は応答の JSON、読めなかったときは false)。
// カードは今の店舗の値だけを使う(別の店舗の窓口の状態を一瞬でも出さない)。
const readiness = ref(null);
const tourReadiness = computed(() =>
  readiness.value?.account === String(accountId.value)
    ? readiness.value.data
    : null
);
const tourPlacement = ref(null);
const tourRef = ref(null);
// カードを的の横に置くときに覆わないもの: 返信欄のまわりの操作(ツールバー・送信ボタン・返信欄)、ページの見出しと
// サイドバーの見出し。案内の的(光らせている的を含む)も覆わない(placeTour)。
const TOUR_AVOIDS = [
  ...['button', '[role="button"]', 'a[href]', '[contenteditable="true"]'].map(
    control => `[data-toybaco-guide-reply] ${control}`
  ),
  'header',
  '[data-toybaco-sidebar-header]',
].join(', ');
// 会話画面の返信の段は、返信欄と送信ボタンが画面の下にある。的の横に置けないとき(幅 640px 未満を含む)は、カードを
// 画面の下ではなく上(会話の見出しの下)に出す。
const tourAtTop = computed(
  () => state.value?.phase === 'reply' && Boolean(route.params.conversation_id)
);
const tourCard = computed(() => {
  const card = growthTourCard(
    state.value,
    tourReadiness.value,
    accountId.value
  );
  if (!card || card.phase !== 'reply' || !replyHint.value) return card;
  // 届いた会話の画面では、これまでの 3 段の案内(返信案・入力・送信)を本文に出し、その操作を光らせる。
  return {
    ...card,
    body: [GROWTH_TOUR_REPLY_HINTS[replyHint.value]],
    actions: card.actions.filter(action => action.id !== 'open:conversation'),
    targets: [replyHint.value],
  };
});
const tourVisible = computed(() =>
  Boolean(
    enabled.value &&
    state.value &&
    !inSetup.value &&
    !paused.value &&
    !state.value.preference.dismissed &&
    tourCard.value
  )
);
const bandProgress = computed(() => {
  const progress = growthTourProgress(state.value);
  return progress ? `${progress.index} / ${progress.total}` : '';
});

function onConversationOfStep() {
  return (
    state.value?.phase === 'reply' &&
    String(route.params.conversation_id) ===
      String(state.value.conversation_id) &&
    String(route.params.accountId) === String(accountId.value)
  );
}

function currentReplyHint() {
  if (!onConversationOfStep()) return null;
  if (registry.find('reply.ai_draft', document)) return 'reply.ai_draft';
  const editor = registry.find('reply.editor', document);
  if (!editor) return null;
  if (editor.textContent.trim() && registry.find('reply.send', document))
    return 'reply.send';
  return 'reply.editor';
}

function occupiedBoxes() {
  const registered = [...targets.values()].flatMap(entries =>
    entries.map(entry => entry.el)
  );
  return [...document.querySelectorAll(TOUR_AVOIDS), ...registered]
    .map(element => element.getBoundingClientRect())
    .filter(box => box.width > 0 && box.height > 0);
}

// カードはデスクトップでは光らせた的の近く(案内の配置の決まりをそのまま使う)、幅 640px 未満は画面下のシート。
function placeTour(target) {
  const card = tourRef.value?.root;
  let next = null;
  if (target && card && guideModule && window.innerWidth >= 640) {
    const position = guideModule.guidePosition(
      target.getBoundingClientRect(),
      card.getBoundingClientRect(),
      { left: 0, top: 0, width: window.innerWidth, height: window.innerHeight },
      occupiedBoxes()
    );
    if (position)
      next = { left: Math.round(position.left), top: Math.round(position.top) };
  }
  if (JSON.stringify(next) !== JSON.stringify(tourPlacement.value))
    tourPlacement.value = next;
}

function showTour() {
  const hint = currentReplyHint();
  if (hint !== replyHint.value) replyHint.value = hint;
  const spot = tourVisible.value
    ? tourCard.value.targets.find(id => registry.find(id, document))
    : null;
  if (!spot) {
    guide.hide();
    lastStep = null;
    placeTour(null);
    return;
  }
  const key = `${accountId.value}:spotlight:${spot}`;
  if (key !== lastStep) {
    guide.spotlight({ actionId: spot, dim: 'strong' });
    lastStep = key;
  } else guide.schedule();
  placeTour(registry.find(spot, document));
}

async function later() {
  paused.value = true;
  // 閉じたことを保存できなかったら、カードを消したままにしない(帯も出ず、案内が見えなくなるため)。
  if (!(await updateGrowthGuide({ dismissed: true })) && !supportStep)
    paused.value = false;
}

async function onTourAction(action) {
  const id = accountId.value;
  const [kind, value] = action.id.split(':');
  const preference = state.value?.preference || {};
  if (kind === 'purpose') await updateGrowthGuide({ purpose: value });
  else if (kind === 'skip')
    await updateGrowthGuide({
      skipped: [...new Set([...(preference.skipped || []), value])],
    });
  else if (kind === 'choose')
    await updateGrowthGuide({ ai_reply_choice: value });
  else if (kind === 'proceed') {
    const [first] = state.value?.inboxes || [];
    if (first)
      await updateGrowthGuide({ inbox_id: state.value.inbox_id ?? first.id });
  } else if (kind === 'close') await later();
  else if (action.id === 'open:facts')
    router.push({
      name: 'toybaco_store_facts_settings',
      params: { accountId: id },
    });
  else if (action.id === 'open:inbox_new')
    router.push({ name: 'settings_inbox_new', params: { accountId: id } });
  else if (action.id === 'open:conversation' && state.value?.conversation_id)
    router.push({
      name: 'conversation_through_inbox',
      params: {
        accountId: id,
        inbox_id: state.value.inbox_id,
        conversation_id: state.value.conversation_id,
      },
    });
  else if (action.id === 'open:posting') {
    // 投稿画面を開いたら投稿の段は済み(「あとで設定する」ではない)。ToybacoStart の openPosting と同じ。
    const opened = preference.opened || [];
    if (!opened.includes('posting'))
      await updateGrowthGuide({ opened: [...opened, 'posting'] });
    router.push({
      name: 'home',
      params: { accountId: id },
      hash: '#/toybaco/posting',
    });
  }
}

// 段 decide の本文(この窓口の AI返信の状態)と「自動で返す」の行き先は readiness のサーバー値。段に入ったとき・画面に戻ったとき・
// 5 秒ごとの読み直しのたびに読む(古い応答は readinessEpoch で捨てる)。決めるのは管理者なので、読むのも管理者のときだけ
// (スタッフのカードは注記だけ。案内の画面と同じ)。
let readinessEpoch = 0;
async function readReadiness() {
  readinessEpoch += 1;
  const epoch = readinessEpoch;
  const account = String(accountId.value || '');
  // 別の店舗の値は、読み直しを待たずに捨てる。同じ店舗の読み直しの間は前の値を出したままにする(本文をちらつかせない)。
  if (readiness.value?.account !== account) readiness.value = null;
  if (
    !enabled.value ||
    state.value?.phase !== 'decide' ||
    !state.value.administrator ||
    !account
  ) {
    readiness.value = null;
    return;
  }
  let data = false;
  try {
    const response = await fetch(
      `/toybaco/ai_readiness?account_id=${encodeURIComponent(account)}`,
      {
        credentials: 'same-origin',
        cache: 'no-store',
        headers: { Accept: 'application/json' },
      }
    );
    if (response.ok && !response.redirected)
      data = (await response.json()) || false;
  } catch {
    data = false;
  }
  if (epoch === readinessEpoch) readiness.value = { account, data };
}
// 店舗情報の確認で「自動で返す」の行き先が出るので、確認が変わったときも読み直す。
watch(
  [
    () => String(accountId.value),
    () => state.value?.phase,
    () => Boolean(state.value?.administrator),
    () => Boolean(state.value?.facts?.confirmed),
  ],
  readReadiness,
  { immediate: true }
);
function returned(event) {
  if (!event.persisted || !enabled.value) return;
  refreshGrowthGuide();
  readReadiness();
}
// ほかのタブ・画面から戻ったときも、段 decide の本文を読み直す。
function shown() {
  if (document.visibilityState === 'visible' && enabled.value) readReadiness();
}

function scan() {
  scanFrame = undefined;
  if (!registry || !guide || disposed) return;
  for (const [id, selector] of Object.entries(selectors)) {
    const elements = [...document.querySelectorAll(selector)];
    const previous = targets.get(id) || [];
    if (
      elements.length === previous.length &&
      elements.every((el, index) => el === previous[index].el)
    )
      continue;
    previous.forEach(entry => entry.remove());
    targets.set(
      id,
      elements.map(el => ({ el, remove: registry.register(id, el) }))
    );
  }
  const available = supportEnabled.value
    ? supportGuideArticles().filter(id =>
        registry.find(supportGuideStep(id)[0], document)
      )
    : [];
  const keyOfAvailability = JSON.stringify([
    String(accountId.value),
    available,
  ]);
  if (availability !== keyOfAvailability) {
    availability = keyOfAvailability;
    window.dispatchEvent(
      new CustomEvent('toybaco:support-guide-availability', {
        detail: { accountId: String(accountId.value), articles: available },
      })
    );
  }
  if (supportStep && !available.includes(supportStep.articleId))
    supportStep = null;
  const step = wantedStep();
  if (!step) {
    showTour();
    return;
  }
  placeTour(null);
  if (!registry.find(step[0], document)) {
    guide.hide();
    lastStep = null;
    return;
  }
  const key = `${accountId.value}:${step.join(':')}`;
  if (key !== lastStep) {
    guide.show({ actionId: step[0], text: step[1] });
    // 接続の段でカードに触れたあとは、指す先と文言が替わってもポインタを戻さない(枠と案内文だけを替える)。
    if (
      !supportStep &&
      connectionTouched &&
      inSetup.value &&
      state.value?.phase === 'connect'
    )
      guide.suppress();
    lastStep = key;
  } else guide.schedule();
}

function scheduleScan() {
  if (scanFrame === undefined && !disposed)
    scanFrame = requestAnimationFrame(scan);
}

// 接続の段で、利用者が hover・focus しているカード。案内の文言を、そのカードで何が開くかに替える。
function cardOf(node) {
  return node?.closest?.(connectionCards)?.dataset.toybacoGuideAction || null;
}
function trackConnectionHover(event) {
  if (!inSetup.value) return;
  const card = cardOf(
    event.type === 'pointerout' ? event.relatedTarget : event.target
  );
  if (card === hoveredCard) return;
  hoveredCard = card;
  if (card) connectionTouched = true;
  scheduleScan();
}
function trackConnectionFocus(event) {
  if (!inSetup.value) return;
  const card = cardOf(
    event.type === 'focusout' ? event.relatedTarget : event.target
  );
  if (card === focusedCard) return;
  focusedCard = card;
  if (card) connectionTouched = true;
  scheduleScan();
}
watch(
  [() => String(accountId.value), () => state.value?.phase, inSetup],
  () => {
    hoveredCard = null;
    focusedCard = null;
    connectionTouched = false;
  }
);

// 上部の帯の「設定を続ける」: カードをもう一度出す(案内の画面へは移らない)。
async function resume() {
  supportStep = null;
  paused.value = false;
  await updateGrowthGuide({ dismissed: false });
}

function refreshSupportAvailability() {
  availability = '';
  scheduleScan();
}
function requestSupportGuide(event) {
  const detail = event.detail;
  const step = supportGuideStep(detail?.articleId);
  if (
    !supportEnabled.value ||
    String(detail?.accountId) !== String(accountId.value) ||
    !step ||
    !registry?.find(step[0], document)
  )
    return;
  paused.value = true;
  supportStep = {
    accountId: String(accountId.value),
    articleId: detail.articleId,
  };
  scheduleScan();
}
function finishSupportGuide(event) {
  if (!supportStep) return;
  const step = supportGuideStep(supportStep.articleId);
  const target = registry?.find(step[0], document);
  if (target?.contains(event.target)) {
    supportStep = null;
    guide?.hide();
    lastStep = null;
  }
}
watch(supportEnabled, () => {
  supportStep = null;
  scheduleScan();
});
watch(
  () => route.fullPath,
  () => {
    supportStep = null;
  }
);
watch(
  [accountId, enabled],
  async ([id, available]) => {
    guide?.hide();
    supportStep = null;
    availability = '';
    lastStep = null;
    paused.value = false;
    selectGrowthGuideAccount(available ? id : null);
    if (available) await refreshGrowthGuide();
  },
  { immediate: true }
);
// 案内の画面へは自動で移らない(段 1a)。画面と状態が変わるたびに、今の画面の的とカードを置き直す。案内の画面に出入りした
// とき・カードが出たり消えたりしたときは、前の画面の光と案内を scan を待たずに消す。
watch(
  [state, () => route.fullPath, tourVisible, inSetup],
  async ([, , visible, setup], previous = []) => {
    if (visible !== previous[2] || setup !== previous[3]) {
      guide?.hide();
      lastStep = null;
    }
    await nextTick();
    scheduleScan();
  }
);

onMounted(async () => {
  let module;
  try {
    const moduleUrl = new URL(
      '/brand-assets/toybaco-pointer-guide.mjs?v=494de6f79aa954895c93d34de99a5704a047e0211d3c7bfee39f1270572ca39f',
      window.location.origin
    ).href;
    module = await import(/* @vite-ignore */ moduleUrl);
  } catch {
    growthGuideError.value =
      '画面の案内を読み込めませんでした。再読み込みしてください。';
    return;
  }
  if (disposed) return;
  guideModule = module;
  if (!document.querySelector('link[data-toybaco-guide-style]')) {
    const style = document.createElement('link');
    style.rel = 'stylesheet';
    style.href = '/brand-assets/toybaco-pointer-guide.css?v=8df6f6a144be8e1ff75bc3d043fdee0e12779abfd1d21a28e3ad7eb790d1a424';
    style.dataset.toybacoGuideStyle = 'true';
    document.head.append(style);
  }
  registry = new module.GuideRegistry();
  guide = new module.PointerGuide({
    registry,
    onDismiss: () => {
      paused.value = true;
      if (supportStep) {
        supportStep = null;
        return;
      }
      updateGrowthGuide({ dismissed: true });
    },
  });
  observer = new MutationObserver(records => {
    if (
      records.some(
        record =>
          !record.target.closest?.('.toybaco-guide, [data-toybaco-tour]')
      )
    )
      scheduleScan();
  });
  observer.observe(document.body, {
    subtree: true,
    childList: true,
    characterData: true,
    attributes: true,
    attributeFilter: [
      'disabled',
      'contenteditable',
      'data-toybaco-guide-reply',
    ],
  });
  document.addEventListener('input', scheduleScan, true);
  document.addEventListener('click', finishSupportGuide, true);
  document.addEventListener('input', finishSupportGuide, true);
  document.addEventListener('pointerover', trackConnectionHover, true);
  document.addEventListener('pointerout', trackConnectionHover, true);
  document.addEventListener('focusin', trackConnectionFocus, true);
  document.addEventListener('focusout', trackConnectionFocus, true);
  window.addEventListener('toybaco:support-guide', requestSupportGuide);
  window.addEventListener(
    'toybaco:support-guide-refresh',
    refreshSupportAvailability
  );
  window.addEventListener('resize', scheduleScan);
  document.addEventListener('scroll', scheduleScan, true);
  // 窓口の自動応答の画面(Rails の単独ページ)から「戻る」で復元されたときは、段と AI返信の状態を読み直す。
  window.addEventListener('pageshow', returned);
  document.addEventListener('visibilitychange', shown);
  poll = window.setInterval(() => {
    if (
      document.visibilityState !== 'visible' ||
      !enabled.value ||
      !['connect', 'receive', 'reply', 'facts', 'decide'].includes(
        state.value?.phase
      )
    )
      return;
    refreshGrowthGuide();
    if (state.value.phase === 'decide') readReadiness();
  }, 5000);
  scheduleScan();
});

onBeforeUnmount(() => {
  disposed = true;
  clearInterval(poll);
  if (scanFrame !== undefined) cancelAnimationFrame(scanFrame);
  observer?.disconnect();
  guide?.destroy();
  targets.forEach(entries => entries.forEach(entry => entry.remove()));
  document.removeEventListener('input', scheduleScan, true);
  document.removeEventListener('click', finishSupportGuide, true);
  document.removeEventListener('input', finishSupportGuide, true);
  document.removeEventListener('pointerover', trackConnectionHover, true);
  document.removeEventListener('pointerout', trackConnectionHover, true);
  document.removeEventListener('focusin', trackConnectionFocus, true);
  document.removeEventListener('focusout', trackConnectionFocus, true);
  window.removeEventListener('toybaco:support-guide', requestSupportGuide);
  window.removeEventListener(
    'toybaco:support-guide-refresh',
    refreshSupportAvailability
  );
  window.removeEventListener('resize', scheduleScan);
  document.removeEventListener('scroll', scheduleScan, true);
  window.removeEventListener('pageshow', returned);
  document.removeEventListener('visibilitychange', shown);
  readinessEpoch += 1;
  selectGrowthGuideAccount(null);
});
</script>

<template>
  <aside
    v-if="
      enabled && state && !inSetup && state.phase !== 'complete' && !tourVisible
    "
    class="toybaco-guide-entry"
  >
    <span v-if="!bandProgress">お店の準備を、画面で案内します。</span>
    <span v-else>お店の準備の続きを案内します({{ bandProgress }})</span>
    <button type="button" @click="resume">
      {{ state.preference.purpose ? '設定を続ける' : '使い始める' }}
    </button>
  </aside>
  <ToybacoTour
    v-if="tourVisible"
    ref="tourRef"
    :card="tourCard"
    :placement="tourPlacement"
    :top="tourAtTop"
    :busy="growthGuideBusy"
    @action="onTourAction"
    @later="later"
  />
</template>

<style scoped>
.toybaco-guide-entry {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 8px 20px;
  flex-shrink: 0;
  background: var(--toybaco-surface);
  border-bottom: 1px solid var(--toybaco-hairline);
  color: var(--toybaco-heading);
  font-size: 12px;
}
.toybaco-guide-entry button {
  padding: 6px 12px;
  background: var(--toybaco-button);
  color: var(--toybaco-on-button);
  border: 0;
  border-radius: 8px;
  cursor: pointer;
  white-space: nowrap;
  font: inherit;
}
.toybaco-guide-entry button:focus-visible {
  outline: 3px solid var(--toybaco-focus);
  outline-offset: 3px;
}
</style>
