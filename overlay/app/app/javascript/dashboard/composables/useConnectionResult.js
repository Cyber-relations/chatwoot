import { nextTick, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';

const messages = {
  connected: '受信箱を接続しました。',
  cancelled: '接続を中断しました。いつでも再開できます。',
  unavailable: 'この連携は現在準備中です。',
  retry: '接続できませんでした。もう一度お試しください。',
};

// A return notice is not a completed tour step. Tour progress must read the
// actual inbox state from the server, never this user-editable URL parameter.
export function useConnectionResult(ready) {
  const route = useRoute();
  const router = useRouter();
  let handling = false;
  watch(
    [() => route.query.toybaco_connection, ready],
    async ([status, canRender]) => {
      if (handling || !canRender || !Object.hasOwn(messages, status)) return;
      handling = true;
      const returnedPath = route.fullPath;
      try {
        await nextTick();
        if (route.fullPath !== returnedPath || !ready.value) return;
        useAlert(messages[status]);
        const query = { ...route.query };
        delete query.toybaco_connection;
        await router.replace({ path: route.path, hash: route.hash, query });
      } finally {
        handling = false;
      }
    },
    { immediate: true, flush: 'post' }
  );
}
