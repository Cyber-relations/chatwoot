/**
 * ライトの担当者人数。設定の担当者画面に LP どおりの文言を出す。
 * 本体の Vue は触らず、描画後の DOM に足すだけ。投稿画面は開かない。
 */
(function () {
  'use strict';

  if (window.__TOYBACO_AGENT_SEAT_LOADED__) return;
  window.__TOYBACO_AGENT_SEAT_LOADED__ = true;

  var MARK = 'toybaco-agent-seat-banner';
  var TITLE = 'ご契約の利用人数';
  var BODY = '利用人数の上限はご契約内容をご確認ください。';
  var lastKey = '';

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
        el.setAttribute('data-toybaco-agent-seat-locked', '1');
        el.setAttribute('aria-disabled', 'true');
        if ('disabled' in el) el.disabled = true;
      } else if (el.getAttribute('data-toybaco-agent-seat-locked') === '1') {
        el.removeAttribute('data-toybaco-agent-seat-locked');
        el.removeAttribute('aria-disabled');
        if ('disabled' in el) el.disabled = false;
      }
    }
  }

  function placeBanner(payload) {
    if (!payload || !payload.capped) {
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
    disableAddButtons(payload.at_limit === true);
  }

  function loadSeat() {
    if (!onAgentsPage()) {
      removeBanner();
      disableAddButtons(false);
      return;
    }
    var id = currentAccountId();
    if (!id) return;
    fetch('/toybaco/agent_seat_limit?account_id=' + encodeURIComponent(id), {
      method: 'GET',
      credentials: 'same-origin',
      headers: { Accept: 'application/json' }
    })
      .then(function (res) { return res.ok ? res.json() : null; })
      .then(function (payload) {
        if (!payload || typeof payload !== 'object' || currentAccountId() !== id || !onAgentsPage()) return;
        placeBanner(payload);
      })
      .catch(function () { /* 出せなくても担当者画面は壊さない */ });
  }

  var timer = null;
  function schedule() {
    if (timer) window.clearTimeout(timer);
    timer = window.setTimeout(loadSeat, 80);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', schedule);
  } else {
    schedule();
  }
  window.addEventListener('popstate', schedule);
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
