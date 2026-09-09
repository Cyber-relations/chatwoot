import { computed, ref, watch } from 'vue';
import { useMapGetter } from 'dashboard/composables/store';

// One current login/account scope; switching away never reuses an earlier grant.
const access = ref({ scope: null, phase: 'idle', canView: false });
let requestSequence = 0;

export function useToybacoBillingAccess() {
  const accountId = useMapGetter('getCurrentAccountId');
  const userId = useMapGetter('getCurrentUserID');
  const scope = computed(() =>
    accountId.value && userId.value
      ? `${userId.value}:${accountId.value}`
      : null
  );
  const current = computed(() =>
    access.value.scope === scope.value
      ? access.value
      : { phase: 'idle', canView: false }
  );

  const load = async (refresh = false) => {
    const requestScope = scope.value;
    if (!requestScope) {
      requestSequence += 1;
      access.value = { scope: null, phase: 'idle', canView: false };
      return;
    }
    if (
      access.value.scope === requestScope &&
      (access.value.phase === 'loading' ||
        (!refresh && ['ready', 'error'].includes(access.value.phase)))
    ) {
      return;
    }

    const sequence = ++requestSequence;
    const requestedAccount = accountId.value;
    access.value = { scope: requestScope, phase: 'loading', canView: false };
    const controller = new AbortController();
    const isCurrent = () =>
      sequence === requestSequence && scope.value === requestScope;
    const timeout = setTimeout(() => {
      controller.abort();
      if (isCurrent()) {
        access.value = { scope: requestScope, phase: 'error', canView: false };
      }
    }, 10000);
    try {
      const response = await fetch(
        `/toybaco/billing/access?account_id=${encodeURIComponent(requestedAccount)}`,
        {
          credentials: 'same-origin',
          cache: 'no-store',
          headers: { Accept: 'application/json' },
          signal: controller.signal,
        }
      );
      if (!response.ok) throw new Error('billing_access_unavailable');
      const data = await response.json();
      if (typeof data?.can_view_billing !== 'boolean') {
        throw new Error('billing_access_invalid');
      }
      if (!isCurrent() || controller.signal.aborted) return;
      access.value = {
        scope: requestScope,
        phase: 'ready',
        canView: data.can_view_billing,
      };
    } catch {
      if (isCurrent()) {
        access.value = { scope: requestScope, phase: 'error', canView: false };
      }
    } finally {
      clearTimeout(timeout);
    }
  };

  watch(scope, () => load(), { immediate: true });

  return {
    accountId,
    phase: computed(() => current.value.phase),
    canViewBilling: computed(
      () => current.value.phase === 'ready' && current.value.canView === true
    ),
    refresh: () => load(true),
  };
}
