<script setup>
import { onBeforeUnmount, onMounted, ref, watch } from 'vue';

const props = defineProps({
  accountId: { type: [String, Number], required: true },
  articleId: { type: String, default: '' },
  billing: { type: Boolean, default: false },
});
const opened = ref(false);
const busy = ref(false);
const error = ref('');
const received = ref(false);
const category = ref('product');
const reports = ref([]);
let controller;
let epoch = 0;
let requestId;

function cancel() {
  epoch += 1;
  controller?.abort();
  busy.value = false;
}

async function request(method) {
  if (busy.value) return;
  controller = new AbortController();
  const activeController = controller;
  const attempt = ++epoch;
  const account = String(props.accountId);
  const timer = setTimeout(() => activeController.abort(), 15000);
  busy.value = true;
  error.value = '';
  if (method === 'POST') requestId ||= crypto.randomUUID();
  try {
    const response = await fetch(
      `/toybaco/support/reports?account_id=${encodeURIComponent(account)}`,
      {
        method,
        credentials: 'same-origin',
        cache: 'no-store',
        signal: controller.signal,
        ...(method === 'POST'
          ? {
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                request_id: requestId,
                category: category.value,
                article_id: props.articleId,
              }),
            }
          : {}),
      }
    );
    const data = await response.json();
    if (attempt !== epoch || account !== String(props.accountId)) return;
    if (!response.ok)
      throw new Error(response.status === 429 ? 'limit' : 'unavailable');
    if (String(data.account_id) !== account) throw new Error('wrong account');
    if (method === 'POST') {
      if (!data.report?.id) throw new Error('missing receipt');
      reports.value = [
        data.report,
        ...reports.value.filter(item => item.id !== data.report.id),
      ].slice(0, 20);
      received.value = true;
    } else {
      if (!Array.isArray(data.reports)) throw new Error('missing reports');
      reports.value = data.reports;
    }
  } catch (failure) {
    if (attempt === epoch)
      error.value =
        failure.message === 'limit'
          ? '本日の受付上限です。受付済みの内容は確認を続けます。'
          : '受付状況を確認できませんでした。再試行できます。';
  } finally {
    clearTimeout(timer);
    if (attempt === epoch) busy.value = false;
  }
}

watch(
  () => [props.accountId, props.articleId, category.value],
  () => {
    cancel();
    requestId = undefined;
    received.value = false;
    error.value = '';
  }
);
watch(
  () => props.accountId,
  () => {
    reports.value = [];
    opened.value = false;
    request('GET');
  }
);
onMounted(() => request('GET'));
onBeforeUnmount(cancel);
</script>

<template>
  <section class="support-reports" aria-label="未解決の内容を報告">
    <button type="button" @click="opened = true">解決しない・内容を報告</button>
    <form v-if="opened && !received" @submit.prevent="request('POST')">
      <label for="toybaco-report-category">確認が必要な内容</label>
      <select id="toybaco-report-category" v-model="category" :disabled="busy">
        <option value="product">操作・不具合</option>
        <option v-if="billing" value="billing">請求の確認・訂正</option>
        <option value="identity">本人確認</option>
        <option value="security">不正利用の疑い</option>
      </select>
      <p>
        選んだ手順と設定の確認結果を担当者へ共有します。質問文やお客様との会話は送りません。
      </p>
      <button type="submit" :disabled="busy">
        {{ busy ? '確認しています…' : '報告する' }}
      </button>
    </form>
    <p v-if="received" role="status">
      受け付けました。対応状況はここで確認できます。
    </p>
    <p v-if="error" role="alert">{{ error }}</p>
    <button v-if="error && !received" type="button" :disabled="busy" @click="request('GET')">受付状況を確認</button>
    <details v-if="reports.length">
      <summary>受付済み {{ reports.length }}件</summary>
      <ul>
        <li v-for="report in reports" :key="report.id">
          #{{ report.id }} {{ report.category }}：{{ report.state }}
          <p v-if="report.resolution">{{ report.resolution }}</p>
        </li>
      </ul>
      <button type="button" :disabled="busy" @click="request('GET')">
        状態を更新
      </button>
    </details>
    <p v-if="opened" class="hours">担当者の確認は平日10〜18時です。</p>
  </section>
</template>

<style scoped>
.support-reports {
  border-top: 1px solid #e7e2da;
  margin-top: 20px;
  padding-top: 16px;
  color: #1f3a5f;
  font-size: 13px;
}
button {
  padding: 8px 10px;
  border: 1px solid #d7d2c9;
  border-radius: 8px;
  cursor: pointer;
}
button:disabled {
  opacity: 0.6;
  cursor: wait;
}
form {
  margin-top: 12px;
}
label {
  display: block;
  margin-bottom: 6px;
}
select {
  width: 100%;
  padding: 8px;
  border: 1px solid #d7d2c9;
  border-radius: 8px;
  background: white;
}
p {
  line-height: 1.7;
  margin: 8px 0;
}
details {
  margin-top: 12px;
}
li {
  margin: 12px 0;
}
.hours {
  color: #626d7a;
  font-size: 12px;
}
button:focus-visible,
select:focus-visible,
summary:focus-visible {
  outline: 2px solid #1f3a5f;
  outline-offset: 3px;
}
</style>
