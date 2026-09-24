export function releaseError(ids, state) {
  if (!ids.length) return '再開する受信ボックスを選んでください。';
  const active = state.inboxes.filter(row => !row.held).length;
  return active + ids.length > state.limit ? `利用できる受信ボックスは合計${state.limit}件です。` : '';
}

export function releaseRequestId(random = crypto) {
  return [...random.getRandomValues(new Uint8Array(32))].map(value => value.toString(16).padStart(2, '0')).join('');
}

export function mountInboxRelease(document, fetcher = fetch, idFactory = releaseRequestId) {
  const form = document.querySelector('#inbox-release-form');
  if (!form) return;
  let state = JSON.parse(document.querySelector('#inbox-release-state').textContent);
  const inputs = [...form.querySelectorAll('input[name="inbox_ids"]')];
  const button = document.querySelector('#inbox-release-submit');
  const error = document.querySelector('#inbox-release-error');
  const status = document.querySelector('#inbox-release-status');
  const refresh = document.querySelector('#inbox-release-refresh');
  const inputIds = new Set(inputs.map(input => input.value));
  let rows = new Map(state.inboxes.map(row => [row.id, row]));
  let busy = false, pending = null;
  const selected = () => inputs.filter(input => input.checked && rows.get(input.value).held).map(input => input.value).sort();
  const showError = message => { error.textContent = message; error.hidden = !message; };
  const render = (reset = false) => {
    for (const input of inputs) {
      const row = rows.get(input.value);
      input.disabled = busy || !row.held;
      if (!row.held) input.checked = true;
      else if (reset) input.checked = false;
      document.querySelector(`[data-inbox-state="${input.value}"]`).textContent = row.held ? ' · 保留中' : ' · 契約による保留なし';
    }
    button.disabled = busy || selected().length === 0;
  };
  const validResponse = payload => payload && payload.account_id === state.account_id &&
    typeof payload.revision === 'string' && /^[0-9a-f]{64}$/.test(payload.revision) &&
    Number.isInteger(payload.limit) && payload.limit >= 0 && Array.isArray(payload.inboxes) &&
    payload.inboxes.length === inputs.length && new Set(payload.inboxes.map(row => row.id)).size === inputs.length &&
    payload.inboxes.every(row => typeof row.held === 'boolean' && inputIds.has(row.id));
  form.addEventListener('change', () => {
    if (busy) return;
    status.textContent = '';
    showError(selected().length ? releaseError(selected(), state) : '');
    render();
  });
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (busy) return;
    const ids = selected();
    const invalid = releaseError(ids, state);
    if (invalid) { showError(invalid); return; }
    const key = JSON.stringify([state.account_id, state.revision, ids]);
    if (pending?.key !== key) pending = { key, id: idFactory() };
    busy = true;
    render();
    showError('');
    refresh.hidden = true;
    status.textContent = '契約と接続を確認しています…';
    let succeeded = false;
    let failureMessage = '再開状態を確認できませんでした。もう一度お試しください。';
    try {
      const response = await fetcher(`/toybaco/growth/inbox-release?account_id=${encodeURIComponent(state.account_id)}`, {
        method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ inbox_ids: ids, revision: state.revision, request_id: pending.id }),
      });
      const payload = await response.json();
      if (!response.ok) {
        failureMessage = '再開できませんでした。最新の状態を確認してください。';
        throw new Error('response rejected');
      }
      if (!validResponse(payload)) {
        failureMessage = '接続の状態が変わりました。最新の状態に更新してください。';
        throw new Error('state changed');
      }
      state = payload;
      rows = new Map(state.inboxes.map(row => [row.id, row]));
      render(true);
      if (ids.some(id => rows.get(id).held)) {
        failureMessage = '現在は保留中です。最新の状態を確認してください。';
        throw new Error('still held');
      }
      pending = null;
      succeeded = true;
      status.textContent = '選んだ受信ボックスを再開しました。';
    } catch {
      status.textContent = '';
      showError(failureMessage);
      refresh.hidden = false;
    } finally {
      busy = false;
      render();
      if (succeeded || button.disabled) status.focus();
      else button.focus();
    }
  });
  render();
}

if (typeof document !== 'undefined') mountInboxRelease(document);
