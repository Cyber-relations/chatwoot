(function () {
  'use strict';
  var main = document.querySelector('main[data-account-id]');
  if (!main) return;
  var endpoint = '/toybaco/growth/automatic-replies?account_id=' + encodeURIComponent(main.dataset.accountId);
  var state = null;
  var busy = false;
  var pending = null;
  var names = {unconnected: '未接続', draft: '準備済み・下書き', auto: '全自動', stopping: '停止処理中', stopped: '停止済み'};
  function paint() {
    document.getElementById('status').textContent = state ? (state.state === 'auto' && !state.enabled ? '自動応答の受付停止中' : names[state.state]) + (state.pending ? '（確認が必要な応答があります）' : '') : '状態を確認しています。';
    document.getElementById('register').disabled = busy || !state || state.state !== 'unconnected' || !state.enabled;
    document.getElementById('enable').disabled = busy || !state || !['draft', 'stopped'].includes(state.state) || state.pending || !state.enabled;
    document.getElementById('stop').disabled = busy || !state || !['auto', 'draft'].includes(state.state);
    document.getElementById('inbox').disabled = busy || !state || state.state !== 'unconnected';
    document.getElementById('refresh').disabled = busy;
  }
  async function call(method, body) {
    busy = true; paint();
    document.getElementById('error').textContent = '';
    var controller = new AbortController();
    var timer = setTimeout(function () {controller.abort();}, 10000);
    try {
      var response = await fetch(endpoint, {method: method, signal: controller.signal, credentials: 'same-origin', cache: 'no-store', headers: {'Accept': 'application/json', 'Content-Type': 'application/json'}, body: body ? JSON.stringify(body) : undefined});
      var data = await response.json();
      if (!response.ok) throw new Error(data.error || '状態を確認できません。');
      if (!Object.prototype.hasOwnProperty.call(names, data.state)) throw new Error('状態を確認できません。');
      state = Object.assign({}, state, data);
      if (method !== 'GET') pending = null;
    } catch (error) {
      document.getElementById('error').textContent = error.message || '状態を確認できません。同じ操作で再確認できます。';
    } finally {clearTimeout(timer); busy = false; paint();}
  }
  function change(mode) {
    if (!state || busy) return;
    var body = {mode: mode, generation: state.generation, epoch: state.epoch};
    if (!pending || pending.kind !== mode) pending = {kind: mode, body: Object.assign(body, {request_id: crypto.randomUUID()})};
    call('PUT', pending.body);
  }
  document.getElementById('register').addEventListener('click', function () {
    var id = Number(document.getElementById('inbox').value);
    if (!Number.isSafeInteger(id) || id < 1 || busy) return;
    if (!pending || pending.kind !== 'register' || pending.body.inbox_id !== id) pending = {kind: 'register', body: {inbox_id: id, request_id: crypto.randomUUID()}};
    call('POST', pending.body);
  });
  document.getElementById('enable').addEventListener('click', function () {change('auto');});
  document.getElementById('stop').addEventListener('click', function () {change('stopped');});
  document.getElementById('refresh').addEventListener('click', function () {call('GET');});
  paint(); call('GET');
}());
