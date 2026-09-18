import { ref } from 'vue';

export const growthGuideState = ref(null);
export const growthGuideError = ref('');
export const growthGuideBusy = ref(false);
let accountId = null;
let epoch = 0;
let pendingRead = null;

export function selectGrowthGuideAccount(id) {
  if (String(id || '') === String(accountId || '')) return;
  accountId = id ? String(id) : null;
  epoch += 1;
  pendingRead?.abort();
  pendingRead = null;
  growthGuideState.value = null;
  growthGuideError.value = '';
  growthGuideBusy.value = false;
}

async function request(path, method, body, signal) {
  if (!accountId) return null;
  const selectedEpoch = epoch;
  const response = await fetch(
    `${path}?account_id=${encodeURIComponent(accountId)}`,
    {
      method,
      signal,
      credentials: 'same-origin',
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
    }
  );
  if (selectedEpoch !== epoch) return null;
  if ([401, 403, 404].includes(response.status)) {
    growthGuideState.value = null;
    throw new Error('この店舗の案内を開けません。');
  }
  if (!response.ok || response.redirected)
    throw new Error('読み込めませんでした。もう一度お試しください。');
  const data = await response.json();
  if (selectedEpoch !== epoch || String(data.account_id) !== accountId)
    return null;
  growthGuideState.value = data;
  growthGuideError.value = '';
  return data;
}

export async function refreshGrowthGuide() {
  if (!accountId || pendingRead || growthGuideBusy.value) return;
  const controller = new AbortController();
  const selectedEpoch = epoch;
  pendingRead = controller;
  try {
    return await request(
      '/toybaco/growth/onboarding',
      'GET',
      null,
      controller.signal
    );
  } catch (error) {
    if (selectedEpoch === epoch && error.name !== 'AbortError')
      growthGuideError.value = error.message;
  } finally {
    if (pendingRead === controller) pendingRead = null;
  }
}

async function update(path, body) {
  if (!accountId || growthGuideBusy.value) return;
  epoch += 1;
  pendingRead?.abort();
  pendingRead = null;
  const selectedEpoch = epoch;
  growthGuideBusy.value = true;
  try {
    return await request(path, 'PUT', body);
  } catch (error) {
    if (selectedEpoch === epoch) growthGuideError.value = error.message;
  } finally {
    if (selectedEpoch === epoch) growthGuideBusy.value = false;
  }
}

export const updateGrowthGuide = (preference) =>
  update('/toybaco/growth/onboarding', { preference });
export const saveGrowthFacts = (fields) =>
  update('/toybaco/growth/facts', { fields, confirmed: true });
