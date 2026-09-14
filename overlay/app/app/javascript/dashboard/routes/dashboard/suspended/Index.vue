<script setup>
import EmptyState from 'dashboard/components/widgets/EmptyState.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import { computed, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import { useAdmin } from 'dashboard/composables/useAdmin';
import { useMapGetter } from 'dashboard/composables/store';

const { isAdmin } = useAdmin();
const route = useRoute();
const userAccounts = useMapGetter('getUserAccounts');
const otherAccounts = computed(() =>
  (userAccounts.value || [])
    .filter(account => Number(account.id) !== Number(route.params.accountId))
    .sort((a, b) => a.name.localeCompare(b.name))
);
const isOnChatwootCloud = useMapGetter('globalConfig/isOnChatwootCloud');

const showBillingLink = computed(
  () => isAdmin.value && isOnChatwootCloud.value
);

const toggleSupportWidgetVisibility = () => {
  if (window.$chatwoot) {
    window.$chatwoot.toggleBubbleVisibility('show');
  }
};

const toggleSupportWidget = () => {
  if (typeof window.$chatwoot?.toggle === 'function') {
    window.$chatwoot.toggle();
    return;
  }
  window.location.href = 'mailto:support@toybaco.jp';
};

const setupListenerForWidgetEvent = () => {
  window.addEventListener('chatwoot:on-message', () => {
    toggleSupportWidgetVisibility();
  });
};

onMounted(() => {
  toggleSupportWidgetVisibility();
  setupListenerForWidgetEvent();
});
</script>

<template>
  <div class="items-center bg-n-slate-2 flex justify-center h-full w-full">
    <EmptyState
      class="max-w-lg"
      :title="$t('APP_GLOBAL.ACCOUNT_SUSPENDED.TITLE')"
      :message="$t('APP_GLOBAL.ACCOUNT_SUSPENDED.MESSAGE')"
    >
      <div class="flex flex-col items-center gap-3 mt-4">
        <NextButton
          icon="i-lucide-life-buoy"
          :label="$t('SIDEBAR_ITEMS.CONTACT_SUPPORT')"
          @click="toggleSupportWidget"
        />
        <router-link
          v-if="showBillingLink"
          :to="{ name: 'billing_settings_index' }"
          class="text-sm text-n-slate-11 hover:text-n-slate-12 hover:underline"
        >
          {{ $t('APP_GLOBAL.ACCOUNT_SUSPENDED.MANAGE_BILLING') }}
        </router-link>
      </div>
      <nav
        v-if="otherAccounts.length"
        aria-labelledby="suspended-account-switch-title"
        class="w-full max-w-sm px-4 mt-6 mx-auto"
      >
        <h2
          id="suspended-account-switch-title"
          class="mb-3 text-sm font-medium text-center text-n-slate-12"
        >
          {{ $t('SIDEBAR_ITEMS.SWITCH_ACCOUNT') }}
        </h2>
        <ul class="flex flex-col gap-2 max-h-48 overflow-y-auto">
          <li v-for="account in otherAccounts" :key="account.id">
            <a
              :href="`/app/accounts/${account.id}/dashboard`"
              class="flex items-center min-h-11 px-4 py-3 text-sm leading-5 break-words rounded-lg border border-n-weak text-n-slate-12 hover:bg-n-alpha-1 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-n-brand"
            >
              <span class="min-w-0 break-words">{{ account.name }}</span>
            </a>
          </li>
        </ul>
      </nav>
    </EmptyState>
  </div>
</template>
