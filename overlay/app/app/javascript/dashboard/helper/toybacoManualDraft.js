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

export function draftEndpoint(accountId, conversationId, requestId) {
  if (![accountId, conversationId].every(id => /^[1-9]\d*$/.test(String(id)))) return null;
  const params = new URLSearchParams({ account_id: accountId, conversation_id: conversationId });
  if (requestId) params.set('request_id', requestId);
  return `/toybaco/growth/drafts?${params}`;
}
