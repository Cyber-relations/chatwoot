<script setup>
// トイバコ: パスワード設定・変更画面の要件チェックリスト。入力欄の直下に静的に並べる
// (上流 signup の PasswordRequirements は absolute のポップオーバーで、モバイル幅だと form の外へはみ出すため使わない)。
// 1 行 1 項目(li は flex。inline-flex だと短い日本語の文言が横に並ぶ)。入力のたびに読み上げると煩いので aria-live は付けない。
// 達成/未達は色とアイコンだけにせず sr-only の文言でも伝える。入力欄は aria-describedby でこの ul の id を指す。
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import { toybacoPasswordRequirements } from 'shared/helpers/toybacoPasswordRules';

const props = defineProps({
  password: { type: String, default: '' },
  id: { type: String, default: 'toybaco-password-requirements' },
});

const { t } = useI18n();

const requirements = computed(() =>
  toybacoPasswordRequirements(props.password || '').map(item => ({
    ...item,
    label: item.key ? t(item.key) : item.label,
  }))
);
</script>

<template>
  <ul
    :id="id"
    role="list"
    aria-label="パスワードの条件"
    data-testid="toybaco-password-requirements"
    class="mt-2 space-y-1 text-xs"
  >
    <li
      v-for="item in requirements"
      :key="item.id"
      :data-requirement="item.id"
      :data-met="item.met"
      class="flex gap-1.5 items-start"
    >
      <Icon
        aria-hidden="true"
        class="flex-none flex-shrink-0 w-3 mt-0.5"
        :icon="item.met ? 'i-lucide-circle-check-big' : 'i-lucide-circle'"
        :class="item.met ? 'text-n-teal-10' : 'text-n-slate-10'"
      />
      <span :class="item.met ? 'text-n-slate-11' : 'text-n-slate-10'">
        {{ item.label }}
      </span>
      <span class="sr-only">{{ item.met ? '（満たしています）' : '（未達）' }}</span>
    </li>
  </ul>
</template>
