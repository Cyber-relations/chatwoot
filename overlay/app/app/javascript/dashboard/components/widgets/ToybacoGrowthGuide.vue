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
  connect: ['connection.google', 'Googleのアカウントを選んで接続します。'],
  facts: ['facts.confirm', 'お店情報を確認して保存してください。'],
  reply: ['reply.open', '届いたメッセージを開いてみましょう。'],
  posting: ['posting.open', '投稿画面で発信の準備を始めます。'],
};

function wantedStep() {
  if (
    supportStep &&
    supportEnabled.value &&
    supportStep.accountId === String(accountId.value)
  )
    return supportGuideStep(supportStep.articleId);
  if (!state.value || paused.value || state.value.preference.dismissed)
    return null;
  if (inSetup.value && state.value.phase === 'connect') {
    if (!state.value.administrator) return null;
    if (state.value.gmail_available) return setupSteps.connect;
    if (state.value.microsoft_available)
      return [
        'connection.microsoft',
        'Microsoftのアカウントを選んで接続します。',
      ];
    return ['connection.line', 'LINE公式の接続設定を開きます。'];
  }
  if (inSetup.value) return setupSteps[state.value.phase] || null;
  if (
    state.value.phase !== 'reply' ||
    String(route.params.conversation_id) !==
      String(state.value.conversation_id) ||
    String(route.params.accountId) !== String(accountId.value)
  )
    return null;
  if (registry.find('reply.ai_draft', document))
    return ['reply.ai_draft', 'AIの下書きを返信欄で確認できます。'];
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
    lastStep = key;
  } else guide.schedule();
}

function scheduleScan() {
  if (scanFrame === undefined && !disposed)
    scanFrame = requestAnimationFrame(scan);
}

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
      '/brand-assets/toybaco-pointer-guide.mjs?v=354fb2dac804544992dc00cc2c62fd6cbf782405f2f681c6afdf5be58760bf15',
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
    style.href = '/brand-assets/toybaco-pointer-guide.css?v=b2a1f2cc7a6a5cfe046982a73bb386f2edb9af206e4b29c67b6a7fed72a31de6';
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
    <span>最初の接続から、画面で案内します。</span>
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
  background: #fcfbf8;
  border-bottom: 1px solid #e7e2da;
  color: #1f3a5f;
  font-size: 12px;
}
.toybaco-guide-entry button {
  padding: 6px 12px;
  background: #1f3a5f;
  color: #fff;
  border: 0;
  border-radius: 8px;
  cursor: pointer;
  white-space: nowrap;
  font: inherit;
}
.toybaco-guide-entry button:focus-visible {
  outline: 3px solid #ff6b5b;
  outline-offset: 3px;
}
</style>
