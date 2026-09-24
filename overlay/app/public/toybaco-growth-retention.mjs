export function selectionFrom(form) {
  return Object.fromEntries(['inboxes', 'posting_accounts'].map(kind => [kind,
    [...form.querySelectorAll(`input[name="${kind}"]:checked`)].map(input => input.value)]));
}

export function selectionError(selected, limits) {
  return ['inboxes', 'posting_accounts'].some(kind => selected[kind].length > limits[kind])
    ? '上限を超えています。継続する接続を減らしてください。' : '';
}

export function mountRetention(document, fetcher = fetch) {
  const form = document.querySelector('#retention-form');
  if (!form) return;
  let state = JSON.parse(document.querySelector('#retention-state').textContent);
  const error = document.querySelector('#retention-error');
  const status = document.querySelector('#retention-status');
  const summary = document.querySelector('#retention-summary');
  const button = document.querySelector('#retention-save');
  let busy = false;
  const limits = Object.fromEntries(['inboxes', 'posting_accounts'].map(kind => [kind, state.plan[kind].limit]));
  const showError = message => { error.textContent = message; error.hidden = !message; };
  const summarize = () => {
    const selected = selectionFrom(form);
    const count = Object.entries(selected).reduce((sum, [kind, values]) => sum + state.inventory[kind].length - values.length, 0);
    summary.textContent = `${count}件の接続を停止予定`;
    showError(selectionError(selected, limits));
  };
  form.addEventListener('change', () => { status.textContent = ''; summarize(); });
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (busy) return;
    const selected = selectionFrom(form);
    const invalid = selectionError(selected, limits);
    if (invalid) { showError(invalid); return; }
    busy = true;
    form.querySelectorAll('input,button').forEach(control => { control.disabled = true; });
    status.textContent = '保存しています…';
    showError('');
    try {
      const response = await fetcher(`/toybaco/growth/retention?account_id=${encodeURIComponent(state.account_id)}&target=${encodeURIComponent(state.target)}`, {
        method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ revision: state.revision, selected }),
      });
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.error || '保存できませんでした。画面を更新してください。');
      state = { ...payload, account_id: state.account_id };
      status.textContent = '選択を保存しました。';
      const held = state.plan.posts.hold.length;
      summary.textContent = `${state.plan.inboxes.hold.length + state.plan.posting_accounts.hold.length}件の接続と${held}件の予約を保留予定`;
    } catch (failure) {
      status.textContent = '';
      showError(failure.message || '保存できませんでした。画面を更新してください。');
    } finally {
      busy = false;
      form.querySelectorAll('input,button').forEach(control => { control.disabled = false; });
      button.focus();
    }
  });
  summarize();
}

if (typeof document !== 'undefined') mountRetention(document);
