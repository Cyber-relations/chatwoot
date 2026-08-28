/**
 * トイバコ: 受信箱の中で投稿画面を開く(同一アプリ化)
 *
 * 以前は post.toybaco.jp への「リンク」だったが、それでは別サービスへの遷移に
 * 見える。この版では「投稿」をクリックすると、受信箱の画面の中に投稿画面を
 * パネル(iframe)として開く。トイバコのサイドバーは残り、URL のドメインも
 * 変わらない。
 *
 * Rails の標準 HTML 応答経路から自動読込されるため、手動設定は不要。
 *
 * 守っていること:
 *   - 本体の Vue を触らない(描き終わった後に DOM を足すだけ)
 *   - 開く先はサーバーが検証・注入した Toybaco/Postiz origin 固定。外部 URL を
 *     iframe に入れられる形にしない
 *     (hash の path は検証してから使う。検証に落ちたら既定画面を開く)
 *   - 何かあっても受信箱を壊さない(失敗したら黙って何もしない)
 *   - 戻るボタン/ESC で閉じられる。サイドバーで別画面へ移ったら自動で閉じる
 */
(function () {
  'use strict';

  function resolvePostOrigin(value) {
    try {
      if (typeof value !== 'string' || !value || value.trim() !== value) return null;
      var url = new URL(value);
      if (url.username || url.password || url.search || url.hash || url.pathname !== '/') return null;

      var host = url.hostname.toLowerCase();
      var local = host === 'localhost' || host === '127.0.0.1' || host === '[::1]' || /\.localhost$/.test(host);
      var toybaco = /^(?:post|postiz)(?:-[a-z0-9]+)?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*\.toybaco\.jp$/.test(host);
      if (local) {
        if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
      } else if (url.protocol !== 'https:' || url.port || !toybaco) {
        return null;
      }
      return url.origin;
    } catch (e) { return null; }
  }

  var POST_ORIGIN = resolvePostOrigin(window.TOYBACO_POST_URL);
  // 設定が無い・許可外なら入口もiframeも作らない。CSPだけに依存せずfail closed。
  if (!POST_ORIGIN) return;
  if (window.__TOYBACO_POST_ENTRY_LOADED__) return;
  window.__TOYBACO_POST_ENTRY_LOADED__ = true;
  var DEFAULT_PATH = '/launches';
  var LABEL = '投稿';
  var MARK = 'toybaco-post-entry';
  var HASH_PREFIX = '#/toybaco/posting';
  var LOAD_TIMEOUT_MS = 20000;
  // 受信箱(Vue)は起動時の画面遷移で hash を捨てる。転送やメールのリンクで
  // 「どの画面を開きたいか」を持って来ても、そのままでは消えてしまう。
  // 読み込みの一番早い段階で控えておき、画面が落ち着いてから使う。
  var PENDING_KEY = 'toybaco_pending_posting';

  var BILLING_MARK = 'toybaco-billing-entry';
  var postingAllowed = {}; // accountId -> true/false(この画面を開いている間だけ覚える)

  function postizLogoutUrl() {
    return new URL('/auth/logout', POST_ORIGIN).href;
  }

  // Chatwootの標準logout完了後にPostizのhost-only JWTも失効させる。
  // globalConfigは画面初期化の順序で遅れて現れるため、初回とDOM更新時の両方で設定する。
  function installLogoutBridge() {
    try {
      if (!window.globalConfig || typeof window.globalConfig !== 'object') return false;
      window.globalConfig.LOGOUT_REDIRECT_LINK = postizLogoutUrl();
      return window.globalConfig.LOGOUT_REDIRECT_LINK === postizLogoutUrl();
    } catch (e) { return false; }
  }
  installLogoutBridge();

  var panel = null;      // 開いているパネルの DOM
  var poller = null;     // 画面遷移を見張るタイマー(開いている間だけ)
  var loadTimer = null;
  var readyMessageHandler = null;

  function isPostingHash(h) {
    return h === HASH_PREFIX || h.indexOf(HASH_PREFIX + '?') === 0;
  }

  // 受信箱のルーターより先に hash を退避する。
  (function stashPendingPath() {
    try {
      var h = window.location.hash || '';
      if (!isPostingHash(h)) return;
      var q = h.indexOf('?');
      var path = '/launches';
      if (q !== -1) {
        var params = new URLSearchParams(h.slice(q + 1));
        var p = params.get('path');
        // URLSearchParams.get() は既に1回復号している。ここで再度復号すると
        // 二重エンコードされた区切り文字が検査をすり抜けるため、そのまま渡す。
        if (p) path = p;
      }
      sessionStorage.setItem(PENDING_KEY, path);
    } catch (e) { /* 使えない環境では諦める(入口から開ける) */ }
  })();

  function isLoggedInView() {
    return /\/app\/accounts\//.test(window.location.pathname);
  }

  function currentAccountId() {
    var m = window.location.pathname.match(/\/app\/accounts\/(\d+)/);
    return m ? m[1] : null;
  }

  // 投稿画面にどの会社として入るかを伝える(同一サイト内だけで完結する)
  function rememberAccount() {
    try {
      var id = currentAccountId();
      if (!id) return;
      document.cookie =
        'toybaco_post_account=' + id + '; path=/; max-age=3600; samesite=lax; secure';
    } catch (e) { /* cookie が使えなくても開く */ }
  }

  // hash から来た path を、post.toybaco.jp の中のパスとしてだけ受け入れる。
  // 「//evil.example」「https://…」のような値は既定画面に落とす。
  function isOfferedPath(pathname) {
    // 受信箱から開けるのは、トイバコとして提供している4画面だけ。
    // segment境界を要求し、/oauth や /provider などPostiz固有画面へは遷移させない。
    var offered = ['/launches', '/analytics', '/media', '/settings'];
    for (var i = 0; i < offered.length; i += 1) {
      if (pathname === offered[i] || pathname.indexOf(offered[i] + '/') === 0) {
        return true;
      }
    }
    return false;
  }

  function validatePath(p) {
    try {
      if (typeof p !== 'string' || p.length === 0 || p.length > 2000) return DEFAULT_PATH;
      if (p.charAt(0) !== '/' || p.slice(0, 2) === '//') return DEFAULT_PATH;
      // 許可文字を閉じた集合にする。percent escape・backslash・制御文字・
      // Unicode・fragment はすべて拒否し、二重復号やURL解釈差を残さない。
      if (!/^\/[A-Za-z0-9._~/?=&-]*$/.test(p)) return DEFAULT_PATH;
      var rawPathname = p.split('?', 1)[0];
      var rawSegments = rawPathname.split('/');
      // URL constructorが正規化してしまう前にdot segmentを拒否する。
      if (rawSegments.some(function (segment) { return segment === '.' || segment === '..'; })) {
        return DEFAULT_PATH;
      }
      var u = new URL(p, POST_ORIGIN);
      if (u.origin !== POST_ORIGIN) return DEFAULT_PATH;
      var out = u.pathname + u.search;
      // ここが要。「/..//evil.com」は正規化で「//evil.com」になり、
      // それをもう一度 URL にすると別サイトになる(実際に再現した)。
      // 正規化後の姿でもう一度確かめる。
      if (out.slice(0, 2) === '//') return DEFAULT_PATH;
      if (!/^\/[A-Za-z0-9._~/?=&-]*$/.test(out)) return DEFAULT_PATH;
      if (new URL(out, POST_ORIGIN).origin !== POST_ORIGIN) return DEFAULT_PATH;
      if (!isOfferedPath(u.pathname)) return DEFAULT_PATH;
      return out;
    } catch (e) { return DEFAULT_PATH; }
  }

  function buildSrc(path) {
    var destination = new URL(validatePath(path), POST_ORIGIN);
    // OIDC 往復後も iframe 文脈を維持し、同名 query は固定値1個へ正規化する。
    destination.searchParams.set('tb_embed', '1');

    // 既存のPostiz cookieを信用して直接画面を開かない。iframeを作るたびに
    // 専用入口へ入り、Chatwootの現在accountへGENERIC OIDCを再束縛する。
    var entry = new URL('/api/auth/toybaco-entry', POST_ORIGIN);
    entry.searchParams.set(
      'return',
      destination.pathname + destination.search
    );
    // Sec-Fetch-Destを送らない旧UAでも入口自体が埋め込みだと分かる補助印。
    entry.searchParams.set('tb_embed', '1');
    return entry.href;
  }

  // パネルの左端 = サイドバーの右端。取れなければ 0(全面)。
  function computeLeft() {
    try {
      var entry = document.querySelector('[data-' + MARK + ']');
      var nav = entry && entry.closest('nav');
      var host = nav;
      // サイドバーの入れ物(nav の親側)が幅を持っていればそちらを使う
      while (host && host.parentElement &&
             host.parentElement.getBoundingClientRect().width < window.innerWidth * 0.5) {
        host = host.parentElement;
      }
      var r = (host || nav).getBoundingClientRect();
      var left = Math.round(r.right);
      if (left > 0 && left < window.innerWidth * 0.6) return left;
    } catch (e) { /* fall through */ }
    return 0;
  }

  // 退避があるかを見るだけ(消さない)
  function hasPendingPath() {
    try { return !!sessionStorage.getItem(PENDING_KEY); } catch (e) { return false; }
  }

  // 退避しておいた行き先を1回だけ取り出す
  function takePendingPath() {
    try {
      var v = sessionStorage.getItem(PENDING_KEY);
      if (v) sessionStorage.removeItem(PENDING_KEY);
      return v ? validatePath(v) : null;
    } catch (e) { return null; }
  }

  function currentHashPath() {
    var h = window.location.hash || '';
    if (!isPostingHash(h)) return null;
    var q = h.indexOf('?');
    if (q === -1) return DEFAULT_PATH;
    try {
      var params = new URLSearchParams(h.slice(q + 1));
      var p = params.get('path');
      return p ? validatePath(p) : DEFAULT_PATH;
    } catch (e) { return DEFAULT_PATH; }
  }

  function setHash(path) {
    try {
      var h = HASH_PREFIX + '?path=' + encodeURIComponent(path);
      if (window.location.hash !== h) {
        history.pushState({ toybacoPosting: true }, '', h);
      }
    } catch (e) { /* hash が付かなくても動作は続ける */ }
  }

  function stripHash() {
    try {
      if (isPostingHash(window.location.hash || '')) {
        history.replaceState(null, '', window.location.pathname + window.location.search);
      }
    } catch (e) { /* noop */ }
  }

  function onKeydown(e) {
    if (e.key === 'Escape') closePanel();
  }

  function removeReadyMessageHandler() {
    if (!readyMessageHandler) return;
    window.removeEventListener('message', readyMessageHandler);
    readyMessageHandler = null;
  }

  function isTrustedPostizReady(event, frameWindow) {
    return !!(
      event &&
      event.origin === POST_ORIGIN &&
      event.source === frameWindow &&
      event.data &&
      typeof event.data === 'object' &&
      event.data.type === 'TOYBACO_POSTIZ_READY'
    );
  }

  function openPanel(path, fromHash) {
    if (panel) return;
    // 開けない場面(ログイン前など)で hash だけ残ると、以後ずっと
    // 「開いているつもり」の状態になる。消してから戻る。
    if (!isLoggedInView()) { stripHash(); return; }
    rememberAccount();

    var left = computeLeft();
    panel = document.createElement('div');
    panel.setAttribute('data-' + MARK + '-panel', '1');
    panel.style.cssText =
      'position:fixed;top:0;bottom:0;right:0;left:' + left + 'px;' +
      'z-index:40;background:#fff;display:flex;flex-direction:column';

    var spinner = document.createElement('div');
    spinner.style.cssText =
      'position:absolute;inset:0;display:flex;align-items:center;justify-content:center;' +
      'flex-direction:column;gap:12px;background:#fff;color:#6b7684;font-size:14px';
    spinner.innerHTML =
      '<span style="width:28px;height:28px;border:3px solid #e8e2d8;border-top-color:#1f3a5f;' +
      'border-radius:50%;display:inline-block;animation:toybaco-spin 1s linear infinite"></span>' +
      '<span>投稿画面を開いています…</span>';
    var style = document.createElement('style');
    style.textContent = '@keyframes toybaco-spin{to{transform:rotate(360deg)}}';
    spinner.appendChild(style);

    var closeBtn = document.createElement('button');
    closeBtn.type = 'button';
    closeBtn.setAttribute('aria-label', '投稿を閉じる');
    closeBtn.title = '閉じる';
    closeBtn.textContent = '×';
    closeBtn.style.cssText =
      'position:absolute;top:10px;right:14px;z-index:2;width:32px;height:32px;' +
      'border:1px solid #e8e2d8;border-radius:50%;background:#fff;color:#6b7684;' +
      'font-size:18px;line-height:1;cursor:pointer;padding:0';
    closeBtn.addEventListener('click', closePanel);

    var frame = document.createElement('iframe');
    frame.src = buildSrc(path || DEFAULT_PATH);
    frame.title = '投稿';
    frame.style.cssText = 'border:0;width:100%;height:100%;flex:1';
    frame.allow = 'clipboard-write';

    // load はログイン画面・エラーページでも発火するため成功判定には使わない。
    // 子が同一originの受信箱ログインへ遷移した場合だけ、top-levelへ脱出させる。
    frame.addEventListener('load', function () {
      try {
        var childHref = frame.contentWindow && frame.contentWindow.location.href;
        var child = childHref ? new URL(childHref, window.location.href) : null;
        if (
          child &&
          child.origin === window.location.origin &&
          child.pathname === '/app/login'
        ) {
          window.location.assign(child.href);
        }
      } catch (e) { /* cross-origin の通常画面は READY を待つ */ }
    });

    removeReadyMessageHandler();
    readyMessageHandler = function (event) {
      if (!isTrustedPostizReady(event, frame.contentWindow)) return;
      if (loadTimer) { clearTimeout(loadTimer); loadTimer = null; }
      if (spinner.parentNode) spinner.parentNode.removeChild(spinner);
      removeReadyMessageHandler();
    };
    window.addEventListener('message', readyMessageHandler);

    loadTimer = setTimeout(function () {
      if (!panel || !spinner.parentNode) return;
      spinner.innerHTML =
        '<span>投稿画面を開けませんでした。</span>' +
        '<button type="button" style="padding:8px 20px;border:1px solid #ccc;border-radius:8px;' +
        'background:#fff;cursor:pointer">再試行</button>';
      var btn = spinner.querySelector('button');
      if (btn) btn.addEventListener('click', function () {
        var p = currentHashPath() || DEFAULT_PATH;
        closePanel();
        openPanel(p, false);
      });
    }, LOAD_TIMEOUT_MS);

    panel.appendChild(frame);
    panel.appendChild(spinner);
    panel.appendChild(closeBtn);
    document.body.appendChild(panel);

    if (!fromHash) setHash(validatePath(path || DEFAULT_PATH));
    document.addEventListener('keydown', onKeydown, true);

    // サイドバーから別画面へ移ったら閉じる(開いている間だけの軽い見張り)
    var seenPath = window.location.pathname;
    poller = setInterval(function () {
      if (window.location.pathname !== seenPath) closePanel();
      else if (!isPostingHash(window.location.hash || '')) closePanel();
      else if (panel) panel.style.left = computeLeft() + 'px';
    }, 300);
  }

  function closePanel() {
    if (!panel) {
      removeReadyMessageHandler();
      stripHash();
      return;
    }
    try {
      if (poller) { clearInterval(poller); poller = null; }
      if (loadTimer) { clearTimeout(loadTimer); loadTimer = null; }
      removeReadyMessageHandler();
      document.removeEventListener('keydown', onKeydown, true);
      if (panel.parentNode) panel.parentNode.removeChild(panel);
    } catch (e) { /* noop */ }
    panel = null;
    stripHash();
  }

  // 既存メニューの1行を手本にして、同じ見た目の行を作る
  function buildEntry(sampleRow, accountId) {
    var li = document.createElement('li');
    li.className = sampleRow.li.className;
    li.setAttribute('data-' + MARK + '-wrap', '1');

    var a = document.createElement('a');
    a.href = HASH_PREFIX;
    a.className = sampleRow.inner.className;
    a.title = LABEL;
    a.setAttribute('data-' + MARK, '1');
    a.setAttribute('data-account', accountId);

    var iconWrap = document.createElement('div');
    iconWrap.className = 'relative flex items-center gap-2';
    var icon = document.createElement('span');
    icon.className = 'i-lucide-megaphone size-4';
    iconWrap.appendChild(icon);
    a.appendChild(iconWrap);

    var textWrap = document.createElement('div');
    textWrap.className = 'flex items-center min-w-0 flex-grow';
    var text = document.createElement('span');
    text.className = 'truncate';
    text.textContent = LABEL;
    textWrap.appendChild(text);
    a.appendChild(textWrap);

    a.addEventListener('click', function (e) {
      e.preventDefault();
      openPanel(DEFAULT_PATH, false);
    });
    li.appendChild(a);
    return li;
  }

  function findMenu() {
    var navs = document.querySelectorAll('nav');
    for (var i = 0; i < navs.length; i++) {
      var ul = navs[i].querySelector('ul');
      if (!ul) continue;
      var li = ul.querySelector(':scope > li');
      if (!li) continue;
      var inner = li.querySelector('a, [role="button"]');
      if (!inner) continue;
      return { ul: ul, li: li, inner: inner };
    }
    return null;
  }

  // 「投稿」を出してよい会社かをサーバーに確認する(結果は覚えておく)。
  // 確認できなかったときは出さない(契約していない人に見せない側に倒す)
  function checkPosting(accountId, cb) {
    if (accountId in postingAllowed) { cb(postingAllowed[accountId]); return; }
    try {
      fetch('/toybaco/posting_status?account_id=' + encodeURIComponent(accountId), {
        credentials: 'same-origin'
      })
        .then(function (r) { return r.ok ? r.json() : { enabled: false }; })
        .then(function (d) {
          postingAllowed[accountId] = !!(d && d.enabled === true);
          cb(postingAllowed[accountId]);
        })
        .catch(function () { cb(false); });
    } catch (e) { cb(false); }
  }

  function removePostEntry() {
    var el = document.querySelector('[data-' + MARK + ']');
    if (el && el.parentElement) el.parentElement.remove();
  }

  // 「ご契約内容」: プラン変更・カード変更・解約ができるページへの入口。
  // 契約の管理は全員に見えてよいので会社を問わず出す
  function injectBilling(sample) {
    try {
      var url = window.TOYBACO_BILLING_URL;
      if (!url || typeof url !== 'string') return;
      if (url.indexOf('https://billing.stripe.com/') !== 0) return;
      if (document.querySelector('[data-' + BILLING_MARK + ']')) return;
      var li = document.createElement('li');
      li.className = sample.li.className;
      var a = document.createElement('a');
      a.href = url;
      a.target = '_blank';
      a.rel = 'noopener';
      a.className = sample.inner.className;
      a.title = 'ご契約内容';
      a.setAttribute('data-' + BILLING_MARK, '1');
      var iconWrap = document.createElement('div');
      iconWrap.className = 'relative flex items-center gap-2';
      var icon = document.createElement('span');
      icon.className = 'i-lucide-credit-card size-4';
      iconWrap.appendChild(icon);
      a.appendChild(iconWrap);
      var textWrap = document.createElement('div');
      textWrap.className = 'flex items-center min-w-0 flex-grow';
      var text = document.createElement('span');
      text.className = 'truncate';
      text.textContent = 'ご契約内容';
      textWrap.appendChild(text);
      a.appendChild(textWrap);
      li.appendChild(a);
      sample.ul.appendChild(li);
    } catch (e) { /* 出せなくても邪魔はしない */ }
  }

  function inject() {
    try {
      installLogoutBridge();
      if (!isLoggedInView()) return;
      var sample = findMenu();
      if (!sample) return;
      injectBilling(sample);

      var id = currentAccountId();
      if (!id) return;
      var existing = document.querySelector('[data-' + MARK + ']');
      if (existing && existing.getAttribute('data-account') === id) return;
      checkPosting(id, function (ok) {
        try {
          if (currentAccountId() !== id) return; // 確認中に会社が変わっていたら何もしない
          removePostEntry();
          if (!ok) return;
          var now = findMenu();
          if (!now) return;
          if (document.querySelector('[data-' + MARK + ']')) return;
          now.ul.appendChild(buildEntry(now, id));
        } catch (e) { /* 出せなくても邪魔はしない */ }
      });
    } catch (e) { /* 入口が出せなくても受信箱の邪魔はしない */ }
  }

  function onHashMaybeChanged() {
    var p = currentHashPath();
    // hash が受信箱のルーターに捨てられていても、退避してあれば開く。
    // 画面がまだログイン後の状態になっていないうちに取り出すと、
    // 開けないまま退避だけ消えてしまうので、開ける状態か先に見る。
    if (p === null && !panel && hasPendingPath() && isLoggedInView()) {
      var pending = takePendingPath();
      if (pending !== null) { openPanel(pending, false); return; }
    }
    if (p === null) { if (panel) closePanel(); return; }
    if (!panel) { openPanel(p, true); return; }
    // 開いたまま行き先だけ変わった場合(戻る/進む)は中身を差し替える
    try {
      var frame = panel.querySelector('iframe');
      var want = buildSrc(p);
      if (frame && frame.src !== want) frame.src = want;
    } catch (e) { /* 差し替えられなくても開いたままにする */ }
  }

  function start() {
    inject();
    try {
      var pending = null;
      var observer = new MutationObserver(function () {
        if (pending) return;
        pending = setTimeout(function () {
          pending = null;
          inject();
          // 受信箱は画面遷移で hashchange を出さないことがある。
          // 描き替えのたびに「hash はあるのに開いていない」を拾い直す。
          // hash は受信箱のルーターに捨てられることがあるので、
          // 退避が残っている場合も拾い直す
          if (!panel && (currentHashPath() !== null || hasPendingPath())) {
            onHashMaybeChanged();
          }
        }, 250);
      });
      observer.observe(document.body, { childList: true, subtree: true });
    } catch (e) { /* 使えない環境では初回だけ */ }

    window.addEventListener('popstate', onHashMaybeChanged);
    window.addEventListener('hashchange', onHashMaybeChanged);
    // 転送(統合ビュー)から着地した場合はここで開く
    onHashMaybeChanged();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
