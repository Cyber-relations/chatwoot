/**
 * ライトの担当者人数。設定の担当者画面に LP どおりの文言を出す。
 * 本体の Vue は触らず、描画後の DOM に足すだけ。投稿画面は開かない。
 */
(function () {
  'use strict';

  if (window.__TOYBACO_AGENT_SEAT_LOADED__) return;
  window.__TOYBACO_AGENT_SEAT_LOADED__ = true;

  var MARK = 'toybaco-agent-seat-banner';
  var TITLE = '利用人数';
  var BODY = '利用人数の変更が必要な場合は、契約者にご確認ください。';
  var lastKey = '';
  var lastListKey = null;
  var generation = 0;
  var request = null;
  var lockedButtons = new WeakMap();
  var shouldLock = false;

  function currentAccountId() {
    var m = window.location.pathname.match(/\/app\/accounts\/(\d+)/);
    return m ? m[1] : null;
  }

  function onAgentsPage() {
    return /\/settings\/agents(?:\/|$)/.test(window.location.pathname);
  }

  function removeBanner() {
    var existing = document.querySelector('[data-' + MARK + ']');
    if (existing && existing.parentNode) existing.parentNode.removeChild(existing);
    lastKey = '';
  }

  function disableAddButtons(atLimit) {
    var nodes = document.querySelectorAll('button, a');
    var i;
    for (i = 0; i < nodes.length; i += 1) {
      var el = nodes[i];
      var text = String(el.textContent || '').replace(/\s+/g, '');
      if (text.indexOf('担当者を追加') === -1) continue;
      if (atLimit) {
        if (!lockedButtons.has(el)) {
          lockedButtons.set(el, { disabled: el.disabled, ariaDisabled: el.getAttribute('aria-disabled') });
        }
        if (el.getAttribute('data-toybaco-agent-seat-locked') !== '1') el.setAttribute('data-toybaco-agent-seat-locked', '1');
        if (el.getAttribute('aria-disabled') !== 'true') el.setAttribute('aria-disabled', 'true');
        if ('disabled' in el && !el.disabled) el.disabled = true;
      } else if (el.getAttribute('data-toybaco-agent-seat-locked') === '1') {
        var previous = lockedButtons.get(el);
        el.removeAttribute('data-toybaco-agent-seat-locked');
        if (previous) {
          if (el.getAttribute('aria-disabled') === 'true') {
            if (previous.ariaDisabled === null) el.removeAttribute('aria-disabled');
            else el.setAttribute('aria-disabled', previous.ariaDisabled);
          }
          if ('disabled' in el && el.disabled) el.disabled = previous.disabled;
          lockedButtons.delete(el);
        }
      }
    }
  }

  function placeBanner(payload) {
    if (!payload || !payload.capped) {
      shouldLock = false;
      removeBanner();
      disableAddButtons(false);
      return;
    }

    var title = typeof payload.title === 'string' && payload.title ? payload.title : TITLE;
    var message = typeof payload.message === 'string' && payload.message ? payload.message : (TITLE + '。' + BODY);
    var key = [currentAccountId(), title, message, payload.at_limit ? '1' : '0'].join('|');
    var host = document.querySelector('main') || document.body;
    if (!host) return;

    var box = document.querySelector('[data-' + MARK + ']');
    if (!box) {
      box = document.createElement('aside');
      box.setAttribute('data-' + MARK, '1');
      if (host.firstChild) host.insertBefore(box, host.firstChild);
      else host.appendChild(box);
    }
    if (key !== lastKey) {
      box.textContent = '';
      var heading = document.createElement('p');
      heading.setAttribute('data-' + MARK + '-title', '1');
      heading.textContent = title;
      var line = document.createElement('p');
      line.setAttribute('data-' + MARK + '-body', '1');
      line.textContent = message.indexOf(BODY) !== -1 ? BODY : message;
      box.appendChild(heading);
      box.appendChild(line);
      lastKey = key;
    }
    shouldLock = payload.at_limit === true;
    disableAddButtons(shouldLock);
  }

  function loadSeat() {
    if (!onAgentsPage()) {
      removeBanner();
      disableAddButtons(false);
      return;
    }
    var id = currentAccountId();
    if (!id) return;
    if (request && request.id === id && !request.done) {
      request.again = true;
      return;
    }
    var current = { id: id, version: generation, done: false, again: false };
    request = current;
    function isCurrent() {
      return !current.done && current.version === generation && currentAccountId() === id && onAgentsPage();
    }
    function finish() {
      if (current.done) return;
      current.done = true;
      window.clearTimeout(timeout);
      if (request === current) request = null;
      if (current.again && currentAccountId() === id && onAgentsPage()) schedule();
    }
    var timeout = window.setTimeout(function () {
      if (isCurrent()) showChecking(true);
      finish();
    }, 10000);
    fetch('/toybaco/agent_seat_limit?account_id=' + encodeURIComponent(id), {
      method: 'GET',
      credentials: 'same-origin',
      headers: { Accept: 'application/json' }
    })
      .then(function (res) { return res.ok ? res.json() : null; })
      .then(function (payload) {
        if (!isCurrent()) return;
        if (!payload || typeof payload.capped !== 'boolean' || typeof payload.at_limit !== 'boolean') {
          showChecking(true);
          return;
        }
        placeBanner(payload);
      })
      .catch(function () { if (isCurrent()) showChecking(true); })
      .then(finish);
  }

  function showChecking(failed) {
    placeBanner({
      capped: true,
      title: TITLE,
      message: failed ? '利用人数を確認できませんでした。この画面に戻るか、再読み込みして確認してください。' : '利用人数を確認しています。',
      at_limit: true
    });
  }

  function agentListKey() {
    if (!onAgentsPage()) return null;
    var buttons = document.querySelectorAll('button');
    for (var i = 0; i < buttons.length; i += 1) {
      if (String(buttons[i].textContent || '').replace(/\s+/g, '') !== '担当者を追加') continue;
      // 固定上流の header count slot は検索後の行数ではなく、保存済み agentList.length。
      var siblings = buttons[i].parentElement && buttons[i].parentElement.children;
      for (var j = 0; siblings && j < siblings.length; j += 1) {
        var node = siblings[j];
        var text = String(node.textContent || '').trim();
        if (node.tagName === 'SPAN' && /^\d+\s+エージェント$/.test(text)) return currentAccountId() + '|' + text;
      }
    }
    return null;
  }

  function observeList() {
    if (onAgentsPage()) disableAddButtons(shouldLock);
    var key = agentListKey();
    if (key === lastListKey) return;
    lastListKey = key;
    if (onAgentsPage()) schedule();
  }

  var timer = null;
  function schedule() {
    generation += 1;
    lastListKey = agentListKey();
    if (timer) window.clearTimeout(timer);
    if (!onAgentsPage()) {
      shouldLock = false;
      removeBanner();
      disableAddButtons(false);
      return;
    }
    // 以前の人数は新しい保存結果として表示せず、確認中は追加操作を一時停止する。
    showChecking(false);
    timer = window.setTimeout(function () { timer = null; loadSeat(); }, 80);
  }

  function start() {
    schedule();
    if (document.body) {
      new MutationObserver(observeList).observe(document.body, { childList: true, subtree: true, characterData: true });
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
  window.addEventListener('popstate', schedule);
  window.addEventListener('focus', function () { if (!document.hidden) schedule(); });
  document.addEventListener('visibilitychange', function () { if (!document.hidden) schedule(); });
  ['pushState', 'replaceState'].forEach(function (name) {
    var orig = history[name];
    if (typeof orig !== 'function') return;
    history[name] = function () {
      var result = orig.apply(this, arguments);
      schedule();
      return result;
    };
  });
})();
