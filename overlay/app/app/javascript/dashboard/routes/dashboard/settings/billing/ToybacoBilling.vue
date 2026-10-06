<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue';
import { useToybacoBillingAccess } from 'dashboard/composables/useToybacoBillingAccess';
import Button from 'dashboard/components-next/button/Button.vue';

const { accountId, phase, canViewBilling, refresh } = useToybacoBillingAccess();
// Start before the first render so a cached sidebar grant cannot briefly
// mount the iframe before the fresh check finishes.
refresh();
// The billing pages render outside the SPA, so they take the dashboard theme
// from the URL (`.dark` sits on body after login, on html before it). A theme
// switch reloads the frame with the new value.
const dashboardTheme = () =>
  document.body.classList.contains('dark') ||
  document.documentElement.classList.contains('dark')
    ? 'dark'
    : 'light';
const theme = ref(dashboardTheme());
let themeObserver = null;
onMounted(() => {
  themeObserver = new MutationObserver(() => {
    theme.value = dashboardTheme();
  });
  [document.documentElement, document.body].forEach(node =>
    themeObserver.observe(node, {
      attributes: true,
      attributeFilter: ['class'],
    })
  );
});
onBeforeUnmount(() => themeObserver?.disconnect());
const billingUrl = computed(() =>
  canViewBilling.value
    ? `/toybaco/billing?account_id=${encodeURIComponent(accountId.value)}&theme=${theme.value}`
    : null
);

</script>

<template>
  <section class="flex flex-col flex-1 min-w-0 h-full bg-n-background">
    <iframe
      v-if="canViewBilling"
      :src="billingUrl"
      title="ご契約内容"
      class="flex-1 w-full h-full border-0"
    />
    <div v-else class="flex flex-col items-start gap-4 p-6 md:p-8">
      <h1 class="text-xl font-semibold text-n-slate-12">ご契約内容</h1>
      <p
        v-if="phase === 'idle' || phase === 'loading'"
        role="status"
        class="text-n-slate-11"
      >
        ご契約内容を確認しています…
      </p>
      <template v-else-if="phase === 'error'">
        <p role="alert" class="text-n-slate-11">
          ご契約内容を表示できませんでした。もう一度お試しください。
        </p>
        <Button label="再読み込み" @click="refresh" />
      </template>
      <p v-else class="text-n-slate-11">
        ご契約内容は契約者ご本人のみ確認できます。確認や変更が必要な場合は、契約者にお問い合わせください。
      </p>
    </div>
  </section>
</template>
