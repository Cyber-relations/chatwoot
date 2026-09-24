import { releaseRequestId } from './toybaco-growth-inbox-release.mjs';

export function postingSelectionError(ids, state) {
  if (!ids.length) return '再開する投稿先を選んでください。';
  if (new Set([...state.keep_ids, ...ids]).size > state.limit) return `利用できる投稿先は合計${state.limit}件です。`;
  return '';
}

export function mountPostingRelease(document, fetcher = fetch, idFactory = releaseRequestId) {
  const form = document.querySelector('#posting-release-form');
  if (!form) return;
  const state = JSON.parse(document.querySelector('#posting-release-state').textContent);
  const inputs = [...form.querySelectorAll('input[name="integration_ids"]')];
  const button = document.querySelector('#posting-release-submit');
  const error = document.querySelector('#posting-release-error');
  const status = document.querySelector('#posting-release-status');
  const refresh = document.querySelector('#posting-release-refresh');
  const current = new Set([...state.keep_ids, ...state.current_ids]);
  let busy = false, done = false, pending = null;
  const selected = () => inputs.filter(input => input.checked && !state.keep_ids.includes(input.value)).map(input => input.value).sort();
  const render = () => {
    inputs.forEach(input => { input.disabled = busy || done || current.has(input.value); });
    button.disabled = busy || done || !!postingSelectionError(selected(), state);
  };
  form.addEventListener('change', () => {
    if (busy || done) return;
    const ids = selected();
    const message = ids.some(id => !current.has(id)) ? postingSelectionError(ids, state) : '';
    error.textContent = message; error.hidden = !message; render();
  });
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (busy || done) return;
    const ids = selected();
    const invalid = postingSelectionError(ids, state);
    if (invalid) { error.textContent = invalid; error.hidden = false; return; }
    const key = JSON.stringify([state.account_id, state.revision, ids]);
    if (pending?.key !== key) pending = { key, id: idFactory() };
    busy = true; render(); error.hidden = true; refresh.hidden = true;
    status.textContent = '契約と投稿先を確認しています…';
    try {
      const response = await fetcher(`/toybaco/growth/posting-release?account_id=${encodeURIComponent(state.account_id)}`, {
        method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ integration_ids: ids, revision: state.revision, request_id: pending.id }),
      });
      const payload = await response.json();
      const expected = [...new Set([...state.keep_ids, ...ids])].sort();
      const valid = payload && payload.account_id === state.account_id && payload.state === 'active' &&
        payload.current === true && payload.execute === false && /^[0-9a-f]{64}$/.test(payload.authority_id) &&
        JSON.stringify(payload.keep_ids) === JSON.stringify(expected);
      if (!response.ok || !valid) throw new Error('release not confirmed');
      done = true;
      status.textContent = '選んだ投稿先を再開しました。保留中の原稿は、投稿画面で日時と投稿先を確認して保存してください。';
      status.focus();
    } catch {
      status.textContent = '';
      error.textContent = '再開状態を確認できませんでした。選択を保ったまま、もう一度確認できます。';
      error.hidden = false; refresh.hidden = false;
    } finally {
      busy = false; render();
      if (!done) button.focus();
    }
  });
  render();
}

if (typeof document !== 'undefined') mountPostingRelease(document);
