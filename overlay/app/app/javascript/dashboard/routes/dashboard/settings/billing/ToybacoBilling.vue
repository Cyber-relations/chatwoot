<script setup>
import { computed } from 'vue';
import { useToybacoBillingAccess } from 'dashboard/composables/useToybacoBillingAccess';
import Button from 'dashboard/components-next/button/Button.vue';

const { accountId, phase, canViewBilling, refresh } = useToybacoBillingAccess();
// Start before the first render so a cached sidebar grant cannot briefly
// mount the iframe before the fresh check finishes.
refresh();
const billingUrl = computed(() =>
  canViewBilling.value
    ? `/toybaco/billing?account_id=${encodeURIComponent(accountId.value)}`
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
