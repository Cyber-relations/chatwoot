import { nextTick, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';

// 新料金版の有料契約はアプリ内でプランを変更できないため、サポートへ案内する。無料プランは
// 「ご契約内容」の「有料プランを見る」(購入画面)から上位プランへ変えられる。
const LIMIT_GUIDANCE =
  'プランの変更やご不明な点は、サポートへお問い合わせください。';
const FREE_LIMIT_GUIDANCE =
  '上位プランへの変更は「ご契約内容」の「有料プランを見る」から行えます。';
const messages = {
  connected: '受信箱を接続しました。',
  cancelled: '接続を中断しました。いつでも再開できます。',
  unavailable: 'この連携は現在準備中です。',
  retry: '接続できませんでした。もう一度お試しください。',
  // 上限到達は再試行では解消しないため「もう一度お試しください」とは案内しない。
  // 実際の文は connectionResultMessage が件数と契約(無料かどうか)に合わせて組み立てる。
  limit: `このプランで接続できる受信箱の上限に達しています。${LIMIT_GUIDANCE}`,
};
const COUNT = /^\d{1,4}$/;
const NOTICE_PARAMS = [
  'toybaco_connection',
  'toybaco_limit',
  'toybaco_count',
  'toybaco_plan',
];

// The numbers and the plan only shape the notice; the server enforces the plan limit itself.
// Only the exact value 'free' selects the free-plan guidance (an array or any other value does not).
export function connectionResultMessage(status, query = {}) {
  if (status !== 'limit') return messages[status];
  const guidance =
    query.toybaco_plan === 'free' ? FREE_LIMIT_GUIDANCE : LIMIT_GUIDANCE;
  const limit = String(query.toybaco_limit ?? '');
  const count = String(query.toybaco_count ?? '');
  if (!COUNT.test(limit) || !COUNT.test(count))
    return `このプランで接続できる受信箱の上限に達しています。${guidance}`;
  return `このプランでは受信箱を${Number(limit)}件まで接続できます(現在${Number(count)}件)。${guidance}`;
}

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
        useAlert(connectionResultMessage(status, route.query));
        const query = { ...route.query };
        NOTICE_PARAMS.forEach(key => delete query[key]);
        await router.replace({ path: route.path, hash: route.hash, query });
      } finally {
        handling = false;
      }
    },
    { immediate: true, flush: 'post' }
  );
}
