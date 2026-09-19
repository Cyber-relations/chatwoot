(function () {
  'use strict';
  const root = document.getElementById('packs');
  if (!root) return;
  const status = document.getElementById('pack-status');
  const error = document.getElementById('pack-error');
  const buy = document.getElementById('pack-buy');
  const refresh = document.getElementById('pack-refresh');
  const cancel = document.getElementById('pack-cancel');
  const messages = {
    none: '', prepared: '決済の準備ができています。', open: '決済画面からお支払いを完了してください。',
    payment_pending: '入金を確認しています。', complete: '追加パックを購入しました。',
    expired: 'この決済は終了しました。', refunded: 'この購入は返金処理済みです。',
    payment_review: 'この購入のお支払いを確認しています。'
  };
  let busy = false;
  let poll;
  let polls = 0;
  let disposed = false;
  let controller;
  const buttons = [buy, refresh, cancel].filter(Boolean);
  const input = {account_id: root.dataset.accountId, request_key: root.dataset.requestKey};
  function display(state) {
    status.textContent = messages[state] ?? '購入状況を確認してください。';
    if (buy) buy.hidden = !['none', 'prepared', 'open'].includes(state);
    cancel.hidden = !['prepared', 'open'].includes(state);
    refresh.hidden = state === 'none';
    if (state === 'payment_pending' && polls < 24 && !disposed) poll = setTimeout(() => run('refresh'), 5000);
  }
  async function run(action) {
    if (busy || disposed) return;
    clearTimeout(poll);
    busy = true;
    buttons.forEach(button => { button.disabled = true; });
    error.hidden = true;
    status.textContent = '購入状況を確認しています…';
    controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 15000);
    let problem = '購入状況を確認できませんでした。もう一度ご確認ください。';
    try {
      const response = await fetch('/toybaco/growth/packs' + (action ? '/' + action : ''), {
        method: 'POST', credentials: 'same-origin', cache: 'no-store', signal: controller.signal,
        headers: {'Content-Type': 'application/json', Accept: 'application/json'}, body: JSON.stringify(input)
      });
      const data = await response.json();
      if (disposed) return;
      if (!response.ok) {
        if (typeof data.error === 'string' && data.error.length <= 160) problem = data.error;
        throw new Error('checkout unavailable');
      }
      if (!Object.hasOwn(messages, data.state)) throw new Error('購入状況を確認できませんでした。');
      if (!action && data.state === 'open') {
        const url = new URL(data.url);
        if (url.origin !== 'https://checkout.stripe.com' || url.username || url.password) throw new Error('決済画面を確認できませんでした。');
        window.location.assign(url.href);
        return;
      }
      if (['complete', 'expired', 'refunded'].includes(data.state) && root.dataset.state !== data.state) {
        window.location.reload();
        return;
      }
      polls += 1;
      display(data.state);
    } catch (failure) {
      if (disposed) return;
      status.textContent = '';
      error.textContent = failure.name === 'AbortError' ? '確認に時間がかかっています。購入状況をもう一度ご確認ください。' : problem;
      error.hidden = false;
      refresh.hidden = false;
    } finally {
      clearTimeout(timer);
      busy = false;
      buttons.forEach(button => { button.disabled = false; });
    }
  }
  buy?.addEventListener('click', () => run(''));
  refresh.addEventListener('click', () => run('refresh'));
  cancel.addEventListener('click', () => run('cancel'));
  window.addEventListener('pagehide', () => { disposed = true; clearTimeout(poll); controller?.abort(); }, {once: true});
  window.addEventListener('pageshow', event => { if (event.persisted) window.location.reload(); });
  display(root.dataset.state);
  if (new URLSearchParams(window.location.search).has('pack_checkout') && ['prepared', 'open'].includes(root.dataset.state)) run('refresh');
})();
