<script setup>
import { onBeforeUnmount, onMounted, ref } from 'vue';

// 段 1a: 本物の管理画面の上に出す初回ツアーのカード。中身(見出し・本文・進捗・ボタン)は ToybacoGrowthGuide が
// サーバーの値から作り(growthTourCard)、ここは表示と操作の受け渡しだけ。背後の画面の操作は塞がない。
const props = defineProps({
  card: { type: Object, required: true },
  // デスクトップで的の近くに置くときの位置。null なら画面の右下(幅 640px 未満は CSS で画面下のシート)。
  placement: { type: Object, default: null },
  // 会話画面の返信の段: 的の横に置けないときは、返信欄を覆わないよう画面の上に置く。
  top: { type: Boolean, default: false },
  busy: { type: Boolean, default: false },
});
const emit = defineEmits(['action', 'later']);
const root = ref(null);
const titleId = `toybaco-tour-${Math.random().toString(36).slice(2)}`;
const DIALOGS = '[role="dialog"], [aria-modal="true"], dialog[open]';
const FIELDS = 'input, textarea, select';

// ESC は「あとで続ける」。アプリのダイアログが開いて見えているときと、入力欄(返信欄の候補を閉じるなど)の ESC は、
// そちらの操作に任せる(隠れて残っているダイアログは数えない)。押し続け(repeat)と保存中は何もしない。
function dialogShown() {
  return [...document.querySelectorAll(DIALOGS)].some(
    dialog => dialog.getClientRects().length > 0
  );
}
function onKeydown(event) {
  if (event.key !== 'Escape' || event.repeat || event.defaultPrevented) return;
  if (props.busy || dialogShown()) return;
  const field = event.target;
  if (
    !root.value?.contains(field) &&
    (field?.isContentEditable || field?.matches?.(FIELDS))
  )
    return;
  emit('later');
}
onMounted(() => document.addEventListener('keydown', onKeydown));
onBeforeUnmount(() => document.removeEventListener('keydown', onKeydown));

function act(action) {
  if (!action.href) emit('action', action);
}

defineExpose({ root });
</script>

<template>
  <section
    ref="root"
    class="toybaco-tour"
    :class="{
      placed: Boolean(props.placement),
      'toybaco-tour--top': props.top,
    }"
    :style="
      props.placement
        ? { left: `${props.placement.left}px`, top: `${props.placement.top}px` }
        : null
    "
    role="region"
    :aria-labelledby="titleId"
    data-toybaco-tour
  >
    <!-- 段が変わったら、進捗・見出し・本文をまとめて読み上げる。カードは非モーダルなので、フォーカスは移さない。 -->
    <div aria-live="polite">
      <p v-if="card.progress" class="toybaco-tour__progress">
        {{ card.progress }}
      </p>
      <h2 :id="titleId" class="toybaco-tour__title">{{ card.title }}</h2>
      <div class="toybaco-tour__body">
        <p v-for="(line, index) in card.body" :key="index">{{ line }}</p>
        <ul v-if="card.list.length" class="toybaco-tour__list">
          <li v-for="item in card.list" :key="item">{{ item }}</li>
        </ul>
        <p v-if="card.note" class="toybaco-tour__note">{{ card.note }}</p>
      </div>
    </div>
    <div v-if="card.actions.length" class="toybaco-tour__actions">
      <template v-for="action in card.actions" :key="action.id">
        <a
          v-if="action.href"
          :href="action.href"
          class="toybaco-tour__action"
          :class="action.kind"
          :target="action.id === 'open:widget_preview' ? '_blank' : undefined"
          :rel="
            action.id === 'open:widget_preview'
              ? 'noopener noreferrer'
              : undefined
          "
          :data-toybaco-tour-action="action.id"
          >{{ action.label }}</a
        >
        <button
          v-else
          type="button"
          class="toybaco-tour__action"
          :class="action.kind"
          :disabled="busy"
          :data-toybaco-tour-action="action.id"
          @click="act(action)"
        >
          {{ action.label }}
        </button>
      </template>
    </div>
    <button
      v-if="card.phase !== 'complete'"
      type="button"
      class="toybaco-tour__later"
      :disabled="busy"
      @click="emit('later')"
    >
      あとで続ける
    </button>
  </section>
</template>

<style scoped>
.toybaco-tour {
  position: fixed;
  right: 24px;
  bottom: 24px;
  z-index: 10001;
  box-sizing: border-box;
  width: 360px;
  max-width: calc(100vw - 32px);
  padding: 16px 18px 10px;
  background: var(--toybaco-card);
  border: 1px solid var(--toybaco-hairline);
  border-radius: 12px;
  box-shadow: 0 10px 30px var(--toybaco-shadow);
  color: var(--toybaco-ink);
  font-size: 14px;
  line-height: 1.6;
  pointer-events: auto;
  animation: toybaco-tour-in 160ms ease-out;
}
.toybaco-tour.placed {
  right: auto;
  bottom: auto;
}
/* 会話の見出し(幅 1280px 未満で高さ 6rem)の下。 */
.toybaco-tour.toybaco-tour--top:not(.placed) {
  top: calc(env(safe-area-inset-top, 0px) + 6rem);
  bottom: auto;
}
.toybaco-tour__progress {
  margin: 0 0 4px;
  color: var(--toybaco-muted);
  font-size: 12px;
}
.toybaco-tour__title {
  margin: 0 0 6px;
  color: var(--toybaco-heading);
  font-size: 16px;
  font-weight: 600;
}
.toybaco-tour__body p {
  margin: 0 0 6px;
}
.toybaco-tour__list {
  margin: 0 0 6px;
  padding-left: 1.2em;
}
.toybaco-tour__note {
  color: var(--toybaco-muted);
  font-size: 13px;
}
.toybaco-tour__actions {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin-top: 10px;
}
.toybaco-tour__action {
  display: inline-flex;
  align-items: center;
  min-height: 36px;
  padding: 6px 14px;
  border-radius: 8px;
  font: inherit;
  font-size: 13px;
  font-weight: 600;
  text-decoration: none;
  cursor: pointer;
}
.toybaco-tour__action.primary {
  background: var(--toybaco-button);
  color: var(--toybaco-on-button);
  border: 1px solid var(--toybaco-button);
}
.toybaco-tour__action.primary:hover:not(:disabled) {
  background: var(--toybaco-button-hover);
}
.toybaco-tour__action.secondary {
  background: var(--toybaco-wash);
  color: var(--toybaco-heading);
  border: 1px solid var(--toybaco-control-border);
}
.toybaco-tour__action.secondary:hover:not(:disabled) {
  background: var(--toybaco-wash-strong);
}
.toybaco-tour__action:disabled,
.toybaco-tour__later:disabled {
  opacity: 0.55;
  cursor: default;
}
.toybaco-tour__later {
  display: block;
  min-height: 32px;
  margin: 6px 0 0 auto;
  padding: 4px 0;
  border: 0;
  background: transparent;
  color: var(--toybaco-muted);
  font: inherit;
  font-size: 12px;
  text-decoration: underline;
  text-underline-offset: 3px;
  cursor: pointer;
}
.toybaco-tour__action:focus-visible,
.toybaco-tour__later:focus-visible {
  outline: 3px solid var(--toybaco-focus);
  outline-offset: 3px;
}
@keyframes toybaco-tour-in {
  from {
    opacity: 0;
  }
  to {
    opacity: 1;
  }
}
/* 幅 640px 未満は画面下の固定シート(的の近くには置かない)。 */
@media (max-width: 639px) {
  .toybaco-tour,
  .toybaco-tour.placed {
    left: 0 !important;
    right: 0;
    top: auto !important;
    bottom: 0;
    width: auto;
    max-width: none;
    border-radius: 12px 12px 0 0;
  }
  /* 会話画面の返信の段は、画面下の返信欄と送信ボタンを覆わないよう、会話の見出しの下に出す。 */
  .toybaco-tour.toybaco-tour--top {
    top: calc(env(safe-area-inset-top, 0px) + 6rem) !important;
    bottom: auto;
    max-height: 40vh;
    overflow-y: auto;
    border-radius: 0 0 12px 12px;
  }
}
@media (prefers-reduced-motion: reduce) {
  .toybaco-tour {
    animation: none;
  }
}
</style>
