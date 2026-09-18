(function () {
  'use strict';
  const root = document.getElementById('trial');
  const form = document.getElementById('trial-form');
  if (!root || !form) return;
  const confirm = document.getElementById('trial-confirm');
  const start = document.getElementById('trial-start');
  const status = document.getElementById('trial-status');
  const error = document.getElementById('trial-error');
  let busy = false;
  confirm.addEventListener('change', () => { start.disabled = busy || !confirm.checked; });
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (busy || !confirm.checked) return;
    const chosen = form.querySelector('input[name="example_id"]:checked');
    if (!chosen) return;
    busy = true;
    start.disabled = true;
    error.hidden = true;
    status.textContent = '体験を開始しています。';
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), 15000);
    let problem = '開始状況を確認できませんでした。画面を更新して確認してください。';
    try {
      const response = await fetch('/toybaco/growth/trial', {
        method: 'POST', credentials: 'same-origin', cache: 'no-store', signal: abort.signal,
        headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify({ account_id: root.dataset.accountId, example_id: Number(chosen.value),
          revision: root.dataset.revision, confirmed: true })
      });
      const result = await response.json();
      if (!response.ok) {
        if (typeof result.error === 'string' && result.error.length <= 160) problem = result.error;
        throw new Error('start refused');
      }
      if (!['active', 'completed', 'included'].includes(result.state)) throw new Error('開始状況を確認できませんでした。');
      window.location.reload();
    } catch (_) {
      status.textContent = '';
      error.textContent = problem;
      error.hidden = false;
      busy = false;
      start.disabled = !confirm.checked;
    } finally {
      clearTimeout(timer);
    }
  });
})();
