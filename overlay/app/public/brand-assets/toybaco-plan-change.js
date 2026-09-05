(function () {
  'use strict';
  var panel = document.getElementById('plan-change-panel');
  if (!panel) return;

  function el(name) { return document.getElementById('plan-change-' + name); }
  var page = document.getElementById('billing-content');
  var form = el('form');
  var select = el('select');
  var dialog = el('dialog');
  var state = {};
  var choices = [];
  var pending = null;
  var busy = false;
  var returnFocus = null;
  var previousInert = false;
  var fallback = '契約情報を確認できません。時間をおいて再度お試しください。';

  function money(amount) { return '¥' + new Intl.NumberFormat('ja-JP').format(amount); }
  function validAmount(amount) { return Number.isInteger(amount) && amount >= 0; }
  function cycleName(cycle) { return cycle === 'year' ? '年払い' : '月払い'; }
  function dateName(timestamp) {
    if (!Number.isInteger(timestamp) || timestamp <= 0) return null;
    var date = new Date(timestamp * 1000);
    if (!Number.isFinite(date.getTime())) return null;
    return new Intl.DateTimeFormat('ja-JP', {
      timeZone: 'Asia/Tokyo', year: 'numeric', month: 'long', day: 'numeric',
      hour: '2-digit', minute: '2-digit', hour12: false
    }).format(date) + '（日本時間）';
  }
  function serverMessage(data) {
    return data && typeof data.message === 'string' && data.message ? data.message : fallback;
  }
  function failureMessage(failure) { return failure && failure.toybacoMessage ? failure.message : fallback; }
  function error(message) {
    el('error').textContent = message;
    el('error').hidden = false;
  }
  function clearError() { el('error').hidden = true; el('error').textContent = ''; }
  function setBusy(value) {
    busy = value;
    panel.setAttribute('aria-busy', String(value));
    ['preview', 'refresh', 'cancel-reservation', 'reload', 'confirm', 'back', 'select'].forEach(function (id) {
      el(id).disabled = value;
    });
  }
  function post(action, body) {
    return fetch(window.location.pathname + '/' + action + window.location.search, {
      method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
      body: JSON.stringify(body)
    }).then(function (response) {
      return response.json().then(function (data) {
        if (!response.ok) {
          var failure = new Error(serverMessage(data));
          failure.toybacoMessage = true;
          throw failure;
        }
        return data;
      });
    });
  }
  function safePaymentUrl(value) {
    try {
      var url = new URL(value);
      return url.protocol === 'https:' && !url.username && !url.password && !url.port &&
        ['invoice.stripe.com', 'pay.stripe.com'].indexOf(url.hostname) >= 0 ? url.href : null;
    } catch (_) { return null; }
  }
  function changePolicy() {
    var choice = choices[Number(select.value)];
    el('policy').textContent = choice && choice.policy.kind === 'upgrade' ?
      '同じお支払い周期の上位プランへの変更です。日割りの差額を確認し、お支払い完了後に切り替わります。' :
      '現在の契約期間末に切り替わります。今すぐの請求や日割り精算はありません。';
  }
  function render(next) {
    state = next && typeof next === 'object' ? next : { status: 'unavailable' };
    el('state').textContent = JSON.stringify(state);
    form.hidden = true;
    ['refresh', 'cancel-reservation', 'payment', 'reload', 'support'].forEach(function (id) { el(id).hidden = true; });
    el('payment').removeAttribute('href');
    var status = state.status;
    var message;
    if (status === 'available') {
      choices = Array.isArray(state.choices) ? state.choices.filter(function (choice) {
        return choice && typeof choice.plan_id === 'string' && typeof choice.plan_version === 'string' &&
          ['month', 'year'].indexOf(choice.cycle) >= 0 && typeof choice.name === 'string' && validAmount(choice.amount) &&
          choice.policy && ['upgrade', 'downgrade', 'cycle_change'].indexOf(choice.policy.kind) >= 0;
      }) : [];
      select.replaceChildren();
      choices.forEach(function (choice, index) {
        var option = document.createElement('option');
        option.value = String(index);
        option.textContent = choice.name + '・' + cycleName(choice.cycle) + ' ' + money(choice.amount) + '（税別）';
        select.appendChild(option);
      });
      select.value = '0';
      form.hidden = choices.length === 0;
      message = choices.length ? '変更先を選び、料金と切り替え時期をご確認ください。' : '現在選択できる変更先がありません。';
      changePolicy();
      el('support').hidden = choices.length > 0;
    } else if (status === 'payment_pending') {
      message = 'プラン変更のお支払いを確認中です。お支払いが完了するまで現在のプランを継続します。';
      var paymentUrl = safePaymentUrl(state.payment_url);
      if (paymentUrl) { el('payment').href = paymentUrl; el('payment').hidden = false; }
      el('refresh').hidden = false;
      el('refresh').textContent = 'お支払い状況を再確認する';
      el('support').hidden = Boolean(paymentUrl);
    } else if (status === 'reserved') {
      var at = dateName(state.effective_at);
      message = (state.target_name || '選択したプラン') +
        (['month', 'year'].indexOf(state.cycle) >= 0 ? '・' + cycleName(state.cycle) : '') + 'への変更を予約しました。' +
        (at ? at + 'に切り替わります。' : '現在の契約期間末に切り替わります。') + 'それまでは現在のプランを継続します。';
      el('cancel-reservation').hidden = !(typeof state.cancellation_token === 'string' && state.cancellation_token);
      el('refresh').hidden = false;
      el('refresh').textContent = '予約状況を再確認する';
    } else if (['applied', 'released', 'expired'].indexOf(status) >= 0) {
      message = { applied: 'プラン変更を適用しました。', released: '変更予約を取り消しました。現在のプランを継続します。',
        expired: '変更のお支払い期限が過ぎました。現在のプランを継続します。' }[status];
      el('reload').hidden = false;
    } else if (['requested', 'creating', 'created', 'configuring', 'releasing', 'effective'].indexOf(status) >= 0) {
      message = status === 'effective' ? '予約した変更の適用を確認しています。契約内容を再確認してください。' :
        '前回のお申し込みを確認しています。新しく申し込まず、状況を再確認してください。';
      el('refresh').hidden = false;
      el('refresh').textContent = '前回のお申し込みを確認する';
    } else {
      message = typeof state.message === 'string' && state.message ? state.message :
        (status === 'review' ? '前回のお申し込みの確認が必要です。状況を再確認するか、サポートへご連絡ください。' : fallback);
      el('support').hidden = false;
      el('reload').hidden = false;
      if (status === 'review') { el('refresh').hidden = false; el('refresh').textContent = '前回のお申し込みを確認する'; }
    }
    el('status').textContent = message;
  }
  function openDialog(title, detail, button, operation, opener) {
    pending = operation;
    returnFocus = opener || document.activeElement;
    previousInert = page.inert;
    page.inert = true;
    el('dialog-title').textContent = title;
    el('detail').textContent = detail;
    el('confirm').textContent = button;
    dialog.hidden = false;
    el('back').focus();
  }
  function closeDialog() {
    dialog.hidden = true;
    page.inert = previousInert;
    pending = null;
    if (returnFocus && !returnFocus.hidden && !returnFocus.disabled) returnFocus.focus();
    else el('status').focus();
  }
  select.addEventListener('change', function () { clearError(); changePolicy(); });
  form.addEventListener('submit', function (event) {
    event.preventDefault();
    if (busy) return;
    var choice = choices[Number(select.value)];
    if (!choice) return;
    var opener = event.submitter || document.activeElement;
    if (!opener || opener === document.body) opener = el('preview');
    clearError();
    setBusy(true);
    post('change_preview', { plan_id: choice.plan_id, plan_version: choice.plan_version, cycle: choice.cycle }).then(function (data) {
      var quote = data && data.quote;
      if (!quote || typeof data.confirmation_token !== 'string' || !data.confirmation_token ||
          typeof quote.target_name !== 'string' || !validAmount(quote.target_amount) ||
          !quote.selection || ['month', 'year'].indexOf(quote.selection.cycle) < 0 ||
          !quote.policy || ['upgrade', 'downgrade', 'cycle_change'].indexOf(quote.policy.kind) < 0) throw new Error(fallback);
      var upgrade = quote.policy.kind === 'upgrade';
      var at = dateName(quote.period_end);
      if ((upgrade && !validAmount(quote.amount_due)) || (!upgrade && !at)) throw new Error(fallback);
      var effects = quote.effects;
      if (!effects || !(effects.agent_limit === null || validAmount(effects.agent_limit)) ||
          !(effects.ai_reply_limit === null || validAmount(effects.ai_reply_limit)) || typeof effects.posting !== 'boolean') throw new Error(fallback);
      var detail = quote.target_name + '・' + cycleName(quote.selection.cycle) + '\n通常料金 ' + money(quote.target_amount) + '（税別）\n\n';
      detail += '人数上限 ' + (effects.agent_limit === null ? '上限なし' : effects.agent_limit + '名') + '\n' +
        'AI の月間上限 ' + (effects.ai_reply_limit === null ? '上限なし' : effects.ai_reply_limit + '回') + '\n' +
        'SNS 予約投稿 ' + (effects.posting ? '利用できます' : '利用できません') + '\n\n';
      detail += upgrade ? '今回のお支払い額 ' + money(quote.amount_due) + '\n税・割引・残高等を反映した金額です。お支払い完了後に切り替わります。' :
        '切り替え日時 ' + at + '\n今すぐの請求や日割り精算はありません。それまでは現在のプランを継続します。';
      detail += '\n\n既存メンバーやデータは削除しません。人数上限を超える場合は追加・招待を停止します。AI の当月利用回数は引き継ぎます。';
      setBusy(false);
      openDialog(upgrade ? 'お支払い額を確認して変更しますか？' : 'この内容でプラン変更を予約しますか？', detail,
        upgrade ? 'お支払いして変更する' : '変更を予約する', { action: 'change_confirm', token: data.confirmation_token }, opener);
    }).catch(function (failure) { error(failureMessage(failure)); }).finally(function () { setBusy(false); });
  });
  el('cancel-reservation').addEventListener('click', function () {
    if (busy || state.status !== 'reserved' || !state.cancellation_token) return;
    clearError();
    openDialog('プランの変更予約を取り消しますか？', '変更予約を取り消し、現在のプランを継続します。ご契約自体は解約されません。',
      '変更予約を取り消す', { action: 'change_cancel', token: state.cancellation_token });
  });
  el('back').addEventListener('click', function () { if (!busy) closeDialog(); });
  document.addEventListener('keydown', function (event) {
    if (dialog.hidden) return;
    if (event.key === 'Escape') { event.preventDefault(); if (!busy) closeDialog(); return; }
    if (event.key !== 'Tab') return;
    var first = el('back');
    var last = el('confirm');
    if (busy) { event.preventDefault(); return; }
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
  });
  el('confirm').addEventListener('click', function () {
    if (busy || !pending) return;
    var operation = pending;
    setBusy(true);
    post(operation.action, { confirmation_token: operation.token }).then(function (next) {
      setBusy(false);
      closeDialog();
      render(next);
      el('status').focus();
    }).catch(function (failure) {
      setBusy(false);
      closeDialog();
      render({ status: 'requested' });
      error(failureMessage(failure));
      el('status').focus();
    }).finally(function () { setBusy(false); });
  });
  el('refresh').addEventListener('click', function () {
    if (busy) return;
    clearError();
    setBusy(true);
    post('change_refresh', {}).then(function (next) { render(next); el('status').focus(); })
      .catch(function (failure) { error(failureMessage(failure)); el('reload').hidden = false; })
      .finally(function () { setBusy(false); });
  });
  el('reload').addEventListener('click', function () { if (!busy) window.location.reload(); });
  try { render(JSON.parse(el('state').textContent)); }
  catch (_) { render({ status: 'unavailable' }); }
})();
