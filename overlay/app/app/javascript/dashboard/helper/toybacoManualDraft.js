export const draftPending = result => ['queued', 'running'].includes(result?.state);

export function canApplyDraft(result, context) {
  return result?.state === 'completed' && result.current === true &&
    typeof result.content === 'string' && result.content.length > 0 && result.content.length <= 1600 &&
    String(result.incoming_id) === String(context.incomingId) &&
    result.draft_digest === context.digest && context.canEdit === true;
}

export async function digestDraft(value) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
}

export function draftError(result) {
  const messages = {
    cancelled: '作成を中止しました。',
    conversation_changed: '会話が更新されました。もう一度作成できます。',
    expired: '作成を完了できませんでした。AI枠は消費していません。',
    allowance_changed: 'AIの利用枠が変わりました。',
    result_unavailable: '下書きを表示できません。',
  };
  return messages[result?.error_code] || '作成できませんでした。AI枠は消費していません。';
}

// 返信案を作るときに参照した店舗情報の項目(DraftState の facts_fields。キーだけ)。名前は店舗情報の画面と同じ。
// 名前の中に「・」があるので、項目は「、」で区切る。記録の無い旧い返信案(facts_fields が無い)には何も出さない。
const FACT_LABELS = {
  name: '店舗名', hours: '営業日・営業時間', address: '住所', phone: '電話番号',
  services: 'サービス・メニュー', booking: '予約方法', cancellation: 'キャンセル条件',
};

export function draftFactsLine(fields) {
  if (!Array.isArray(fields)) return '';
  const labels = fields.filter(key => Object.prototype.hasOwnProperty.call(FACT_LABELS, key)).map(key => FACT_LABELS[key]);
  return labels.length ? `参照した店舗情報: ${labels.join('、')}` : '';
}

// 返信案を作ったあとに店舗情報が保存し直された(作ったときの revision と、今の店舗情報の revision が違う)。
export function draftFactsChanged(result, facts) {
  return typeof result?.facts_revision === 'string' && typeof facts?.revision === 'string' &&
    result.facts_revision !== facts.revision;
}

export function draftEndpoint(accountId, conversationId, requestId) {
  if (![accountId, conversationId].every(id => /^[1-9]\d*$/.test(String(id)))) return null;
  const params = new URLSearchParams({ account_id: accountId, conversation_id: conversationId });
  if (requestId) params.set('request_id', requestId);
  return `/toybaco/growth/drafts?${params}`;
}
