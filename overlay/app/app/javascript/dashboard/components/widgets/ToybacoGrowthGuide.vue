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
  refreshGrowthGuide,
  selectGrowthGuideAccount,
  updateGrowthGuide,
} from 'dashboard/composables/toybacoGrowthGuide';

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
let observer;
let scanFrame;
let poll;
let disposed = false;
let lastStep;
const targets = new Map();
const launched = new Set();
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
  if (
    state.value.phase !== 'reply' ||
    String(route.params.conversation_id) !==
      String(state.value.conversation_id) ||
    String(route.params.accountId) !== String(accountId.value)
  )
    return null;
  if (registry.find('reply.ai_draft', document))
    return ['reply.ai_draft', 'AIの返信案を返信欄で確認できます。'];
  const editor = registry.find('reply.editor', document);
  if (!editor) return null;
  if (editor.textContent.trim() && registry.find('reply.send', document))
    return ['reply.send', '宛先と内容を確認して送信してください。'];
  return ['reply.editor', 'ここに返信を入力してください。'];
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
  if (!step || !registry.find(step[0], document)) {
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

async function resume() {
  supportStep = null;
  paused.value = false;
  await updateGrowthGuide({ dismissed: false });
  if (state.value)
    router.push({
      name: 'toybaco_growth_start',
      params: { accountId: accountId.value },
    });
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
watch([state, () => route.fullPath], async () => {
  if (
    enabled.value &&
    state.value?.phase === 'purpose' &&
    !state.value.preference.dismissed &&
    !paused.value &&
    route.name === 'home' &&
    route.query.toybaco_skip_tour !== '1' &&
    !launched.has(String(accountId.value))
  ) {
    launched.add(String(accountId.value));
    await router.replace({
      name: 'toybaco_growth_start',
      params: { accountId: accountId.value },
    });
  }
  await nextTick();
  scheduleScan();
});

onMounted(async () => {
  let module;
  try {
    const moduleUrl = new URL(
      '/brand-assets/toybaco-pointer-guide.mjs?v=8ba90f163fe5131724b90fb16fd010600b20081b121085f3dc2d174ef8dafa91',
      window.location.origin
    ).href;
    module = await import(/* @vite-ignore */ moduleUrl);
  } catch {
    growthGuideError.value =
      '画面の案内を読み込めませんでした。再読み込みしてください。';
    return;
  }
  if (disposed) return;
  if (!document.querySelector('link[data-toybaco-guide-style]')) {
    const style = document.createElement('link');
    style.rel = 'stylesheet';
    style.href = '/brand-assets/toybaco-pointer-guide.css?v=b67c0edd3eb908f6ef0b49716d5151270de54c4a452fcc6efeff1a321b9941d2';
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
    if (records.some(record => !record.target.closest?.('.toybaco-guide')))
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
  poll = window.setInterval(() => {
    if (
      document.visibilityState === 'visible' &&
      enabled.value &&
      ['connect', 'receive', 'reply', 'facts'].includes(state.value?.phase)
    )
      refreshGrowthGuide();
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
  selectGrowthGuideAccount(null);
});
</script>

<template>
  <aside
    v-if="enabled && state && !inSetup && state.phase !== 'complete'"
    class="toybaco-guide-entry"
  >
    <span>お店の準備を、画面で案内します。</span>
    <button type="button" @click="resume">
      {{ state.preference.purpose ? '設定を続ける' : '使い始める' }}
    </button>
  </aside>
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
