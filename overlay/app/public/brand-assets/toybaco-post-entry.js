/**
 * トイバコ: 受信箱の中で投稿画面を開く(同一アプリ化)
 *
 * 以前は post.toybaco.jp への「リンク」だったが、それでは別サービスへの遷移に
 * 見える。この版では「投稿」をクリックすると、受信箱と同じ箱のメイン領域に
 * 投稿画面を iframe として出す。独立パネルや右上の×は出さない。
 *
 * Rails の標準 HTML 応答経路から自動読込されるため、手動設定は不要。
 *
 * 守っていること:
 *   - 本体の Vue を触らない(描き終わった後に DOM を足すだけ)
 *   - 開く先はサーバーが検証・注入した Toybaco/Postiz origin 固定。外部 URL を
 *     iframe に入れられる形にしない
 *     (hash の path は検証してから使う。検証に落ちたら既定画面を開く)
 *   - 受信箱の返信欄で「/」を打った最初のキーで、既存の定型文一覧をすぐ出す
 *     (設定画面へ行かせない。LP の「返信はたった3秒」と同じ操作)
 *   - AI 一次応答は返信欄の横で「全自動」「下書き」だけを選ぶ
 *     (左ナビは会話/投稿/ご契約内容/レポート/設定の正本5項目。Captain は開かない)
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

  function postingHash(path) {
    return HASH_PREFIX + '?path=' + encodeURIComponent(validatePath(path || DEFAULT_PATH));
  }
  var LOAD_TIMEOUT_MS = 20000;
  // 受信箱(Vue)は起動時の画面遷移で hash を捨てる。転送やメールのリンクで
  // 「どの画面を開きたいか」を持って来ても、そのままでは消えてしまう。
  // 読み込みの一番早い段階で控えておき、画面が落ち着いてから使う。
  var PENDING_KEY = 'toybaco_pending_posting';

  var BILLING_MARK = 'toybaco-billing-entry';
  var AI_MARK = 'toybaco-ai-mode-entry';
  var AI_MODE_AUTO = 'auto';
  var AI_MODE_DRAFT = 'draft';
  var AI_MODE_LABELS = {};
  AI_MODE_LABELS[AI_MODE_AUTO] = '全自動';
  AI_MODE_LABELS[AI_MODE_DRAFT] = '下書き';
  var AI_NAV_LABEL = 'AI応答';
  var AI_MODE_TIMEOUT_MS = 10000;
  var aiModeStates = {};
  var aiModeInflight = {};
  var aiModeAccount = null;
  var aiReadinessStates = {};
  var aiReadinessInflight = {};
  var aiUsageStates = {};
  var aiUsageInflight = {};
  var CANNED_NAMES = {
    'access-annai': 'アクセス案内',
    'after-uketsuke': 'アフター受付',
    'akibi-kakunin': '空き日確認',
    'akishitsu-annai': '空室案内',
    'akishitsu-kakunin': '空室確認',
    'amenity-annai': 'アメニティ案内',
    'arerugi-kakunin': 'アレルギー確認',
    'bukken-jokyo': '物件状況',
    'bukken-toiawase': '物件問い合わせ',
    'checkin-annai': 'チェックイン案内',
    'chikoku-henshin': '遅刻の返信',
    'chumon-henkou': '注文変更',
    'course-annai': 'コース案内',
    'daisha-kakunin': '代車確認',
    'dantai-sodan': '団体相談',
    'eigyo-access': '営業・アクセス',
    'eigyo-area': '営業エリア',
    'furikae-kakutei': '振替確定',
    'furikae-uketsuke': '振替受付',
    'genchi-chosa-chosei': '現地調査調整',
    'gessha-annai': '月謝案内',
    'goiken-uketsuke': 'ご意見受付',
    'haisou-kakunin': '配送確認',
    'hajimete-annai': '初めての案内',
    'hassou-yotei': '発送予定',
    'henpin-annai': '返品案内',
    'heya-kibo': '部屋希望',
    'isho-soudan': '衣装相談',
    'junbi-mochimono': '準備・持ち物',
    'kashikiri-soudan': '貸切相談',
    'kesseki-renraku': '欠席連絡',
    'kibou-joken': '希望条件',
    'konzatsu-kakunin': '混雑確認',
    'kouji-junbi': '工事準備',
    'kouji-nittei-henko': '工事日程変更',
    'koukan-uketsuke': '交換受付',
    'kouki-kakunin': '工期確認',
    'kuchikomi-onegai': '口コミのお願い',
    'madoguchi-annai': '窓口案内',
    'mendan-cancel': '面談キャンセル',
    'mendan-henkou': '面談変更',
    'mendan-kakutei': '面談確定',
    'menu-annai': 'メニュー案内',
    'menu-ryoukin': 'メニュー・料金',
    'mitsumori-annai': '見積案内',
    'mitsumori-irai': '見積依頼',
    'mitsumori-uketsuke': '見積受付',
    'mochimono-annai': '持ち物案内',
    'moushikomi-soudan': '申込相談',
    'naiken-henkou': '内見変更',
    'naiken-kakutei': '内見確定',
    'naiken-uketsuke': '内見受付',
    'nouki-goannai': '納期ご案内',
    'nyuuko-kakutei': '入庫確定',
    'raiten-orei': '来店お礼',
    'ryokin-plan': '料金プラン',
    'sainyuka-yotei': '再入荷予定',
    'saishin-yoyaku': '再診予約',
    'seibi-mitsumori': '整備見積',
    'seibi-shinchoku': '整備進捗',
    'seido-toiawase': '制度問い合わせ',
    'shaken-mitsumori': '車検見積',
    'sharyou-toiawase': '車両問い合わせ',
    'shiagari-kakunin': '仕上がり確認',
    'shijou-yoyaku': '試乗予約',
    'shinchoku-kakunin': '進捗確認',
    'shinryou-jikan': '診療時間',
    'shiryo-seikyu': '資料請求',
    'shokai-soudan': '初回相談',
    'shorui-kakunin': '書類確認',
    'shoshin-yoyaku': '初診予約',
    'shouhin-shousai': '商品詳細',
    'shoujou-soudan': '症状相談',
    'soudan-hani': '相談範囲',
    'taiken-kakutei': '体験確定',
    'taiken-moushikomi': '体験申込',
    'uchiawase-chosei': '打ち合わせ調整',
    'yoyaku-cancel': '予約キャンセル',
    'yoyaku-henkou': '予約変更',
    'yoyaku-kakutei': '予約確定',
    'yoyaku-uketsuke': '予約受付',
    'zaiko-kakunin': '在庫確認',
    'zenjitsu-remind': '前日リマインド'
  };
  var POSTING_STATUS_TIMEOUT_MS = 5000;
  // account_id -> true(出す/残す) / false(200かつenabled:falseで外す)
  var postingStatusCache = {};
  var postingStatusInflight = {};
  var panelSpinner = null;

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
      // Chatwoot の定型/契約面。投稿カレンダーにはしない。
      if (u.pathname === '/settings/templates' ||
          u.pathname.indexOf('/settings/templates/') === 0) {
        return DEFAULT_PATH;
      }
      return out;
    } catch (e) { return DEFAULT_PATH; }
  }

  function buildSrc(path) {
    var destination = new URL(validatePath(path), POST_ORIGIN);
    // OIDC 往復後も iframe 文脈を維持し、同名 query は固定値1個へ正規化する。
    destination.searchParams.set('tb_embed', '1');

    // 既存のPostiz cookieを信用して直接画面を開かない。iframeを作るたびに
    // 専用入口へ入り、Chatwootの現在accountへGENERIC OIDCを再束縛する。
    var entry = new URL('/toybaco/entry', POST_ORIGIN);
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

  function isTrustedPostizDenied(event, frameWindow) {
    return !!(
      event &&
      event.origin === POST_ORIGIN &&
      event.source === frameWindow &&
      event.data &&
      typeof event.data === 'object' &&
      event.data.type === 'TOYBACO_POSTIZ_DENIED'
    );
  }

  function postingDeniedFor(accountId) {
    return postingStatusCache[accountId] === false;
  }

  function resolvePostingAllowed(accountId, cb) {
    if (!accountId) { cb(true); return; }
    if (Object.prototype.hasOwnProperty.call(postingStatusCache, accountId)) {
      cb(postingStatusCache[accountId]);
      return;
    }
    if (postingStatusInflight[accountId]) {
      postingStatusInflight[accountId].then(cb, function () { cb(true); });
      return;
    }
    var settled = false;
    var request;
    try {
      request = new Promise(function (resolve) {
        var timer = setTimeout(function () {
          if (settled) return;
          settled = true;
          resolve(true);
        }, POSTING_STATUS_TIMEOUT_MS);
        fetch('/toybaco/posting_status?account_id=' + encodeURIComponent(accountId), {
          credentials: 'same-origin'
        }).then(function (r) {
          if (!r || !r.ok) return true;
          return Promise.resolve(r.json()).then(function (d) {
            return !(d && d.enabled === false);
          }).catch(function () { return true; });
        }).catch(function () { return true; }).then(function (allowed) {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          resolve(allowed);
        }, function () {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          resolve(true);
        });
      }).then(function (allowed) {
        if (!Object.prototype.hasOwnProperty.call(postingStatusCache, accountId)) {
          postingStatusCache[accountId] = allowed;
        }
        delete postingStatusInflight[accountId];
        return postingStatusCache[accountId];
      });
    } catch (e) {
      cb(true);
      return;
    }
    postingStatusInflight[accountId] = request;
    request.then(cb, function () { cb(true); });
  }

  function showContractMissing() {
    if (!panel) return;
    if (loadTimer) { clearTimeout(loadTimer); loadTimer = null; }
    removeReadyMessageHandler();
    try {
      var frame = panel.querySelector('iframe');
      if (frame && frame.parentNode) frame.parentNode.removeChild(frame);
    } catch (e) { /* noop */ }
    if (panelSpinner) {
      panelSpinner.innerHTML = '<span>この会社の契約には投稿が含まれていません。</span>';
    }
  }

  function applyPostingDenied() {
    removePostEntry();
    showContractMissing();
  }

  function reconcilePostingAccess(accountId) {
    resolvePostingAllowed(accountId, function (allowed) {
      try {
        if (currentAccountId() !== accountId) return;
        if (allowed) return;
        applyPostingDenied();
      } catch (e) { /* 入口を外せなくても受信箱の邪魔はしない */ }
    });
  }

  function mountPostFrame(path, spinner) {
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
      if (isTrustedPostizDenied(event, frame.contentWindow)) {
        applyPostingDenied();
        return;
      }
      if (!isTrustedPostizReady(event, frame.contentWindow)) return;
      if (loadTimer) { clearTimeout(loadTimer); loadTimer = null; }
      if (spinner.parentNode) spinner.parentNode.removeChild(spinner);
      removeReadyMessageHandler();
    };
    window.addEventListener('message', readyMessageHandler);

    loadTimer = setTimeout(function () {
      if (!panel || !spinner.parentNode || !panel.querySelector('iframe')) return;
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

    if (panel.firstChild) panel.insertBefore(frame, panel.firstChild);
    else panel.appendChild(frame);
  }

  function isPostPanelNode(node) {
    return !!(node && node.getAttribute && node.getAttribute('data-' + MARK + '-panel'));
  }

  // サイドバーの右、会話一覧と同じメイン領域。body 全面の固定パネルにはしない。
  function findContentHost() {
    try {
      var aside = document.querySelector('aside');
      if (aside && aside.parentElement) {
        var sib = aside.nextElementSibling;
        while (sib && isPostPanelNode(sib)) sib = sib.nextElementSibling;
        if (sib) return sib;
      }
    } catch (e) { /* メイン領域がまだ無い */ }
    return null;
  }

  function mountPanelHost(host) {
    try {
      if (host.style && (!host.style.position || host.style.position === 'static')) {
        host.style.position = 'relative';
      }
      if (host.setAttribute) host.setAttribute('data-toybaco-post-host', '1');
    } catch (e) { /* 位置を変えられなくても中に置く */ }
  }

  var SELECTED_CLASS = 'bg-n-alpha-2';

  function navigationClassName(node) {
    return classNameOf(node).split(/\s+/).filter(function (name) {
      return name && name !== 'router-link-active' && name !== 'router-link-exact-active' && name !== SELECTED_CLASS;
    }).join(' ');
  }

  function syncPostingSelection() {
    try {
      var path = window.location.pathname;
      var selected = billingPanel ? 'billing' : panel ? 'posting' :
        /\/reports(?:\/|$)/.test(path) ? 'reports' :
        /\/settings(?:\/|$)/.test(path) ? 'settings' :
        /\/(dashboard|inbox|inbox-view|conversations)(?:\/|$)/.test(path) ? 'inbox' : '';
      var links = document.querySelectorAll('[data-toybaco-nav-link]');
      for (var i = 0; i < links.length; i += 1) {
        var link = links[i];
        var kind = link.getAttribute('data-toybaco-nav-link');
        var on = kind === selected;
        link.setAttribute('data-toybaco-nav-current', on ? 'true' : 'false');
        // 注入行はVue Routerの選択classを引き継がない。
        if (kind === 'posting' || kind === 'billing') {
          link.className = navigationClassName(link) + (on ? ' ' + SELECTED_CLASS : '');
        }
        if (on) link.setAttribute('aria-current', 'page');
        else link.removeAttribute('aria-current');
      }
    } catch (e) { /* 選択表示が無くても開閉は続ける */ }
  }

  function openPanel(path, fromHash) {
    if (panel) return;
    closeAiModePanel();
    closeBillingPanel();
    // 開けない場面(ログイン前など)で hash だけ残ると、以後ずっと
    // 「開いているつもり」の状態になる。消してから戻る。
    if (!isLoggedInView()) { stripHash(); return; }
    rememberAccount();
    if (!fromHash) setHash(validatePath(path || DEFAULT_PATH));

    var host = findContentHost();
    // メイン領域未準備なら固定パネルへ落とさず、hash を残して再試行に任せる。
    if (!host) return;
    mountPanelHost(host);

    panel = document.createElement('div');
    panel.setAttribute('data-' + MARK + '-panel', '1');
    panel.style.cssText =
      'position:absolute;inset:0;z-index:1;background:#fff;display:flex;flex-direction:column';

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
    panelSpinner = spinner;

    panel.appendChild(spinner);
    host.appendChild(panel);
    document.addEventListener('keydown', onKeydown, true);
    syncPostingSelection();

    // サイドバーから別画面へ移ったら閉じる(開いている間だけの軽い見張り)
    var seenPath = window.location.pathname;
    poller = setInterval(function () {
      if (window.location.pathname !== seenPath) closePanel();
      else if (!isPostingHash(window.location.hash || '')) closePanel();
    }, 300);

    var id = currentAccountId();
    if (postingDeniedFor(id)) {
      showContractMissing();
      return;
    }
    mountPostFrame(path, spinner);
    reconcilePostingAccess(id);
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
    panelSpinner = null;
    syncPostingSelection();
    stripHash();
  }

  // 既存メニューの1行を手本にして、同じ見た目の行を作る
  function buildEntry(sampleRow, accountId) {
    var li = document.createElement('li');
    li.className = sampleRow.li.className;
    li.setAttribute('data-' + MARK + '-wrap', '1');

    var a = document.createElement('a');
    a.href = postingHash(DEFAULT_PATH);
    a.className = navigationClassName(sampleRow.inner);
    a.title = LABEL;
    a.setAttribute('data-' + MARK, '1');
    a.setAttribute('data-account', accountId);
    a.setAttribute('data-toybaco-nav-link', 'posting');

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
      if (e.preventDefault) e.preventDefault();
      if (e.stopPropagation) e.stopPropagation();
      if (e.stopImmediatePropagation) e.stopImmediatePropagation();
    }, true);
    li.appendChild(a);
    return li;
  }

  function placeEntry(menu, entry) {
    if (entry.parentElement !== menu.ul || entry.previousElementSibling !== menu.li) {
      menu.ul.insertBefore(entry, menu.li.nextSibling);
    }
  }

  // Chatwoot v4 一次ナビの在庫グループ。正本は 会話/投稿/ご契約/レポート/設定。
  // レポート・設定の親は残す。設定サブツリーと Captain 在庫は客面から消す。
  var STOCK_TITLES = {
    '連絡先': 1,
    'キャンペーン': 1,
    'ヘルプセンター': 1,
    'ヘルプ': 1,
    '企業': 1,
    '通話': 1,
    'AIアシスタント': 1,
    '会話データ': 1,
    'チーム': 1,
    'すべての会話': 1,
    'メンション': 1,
    '参加中': 1,
    'アカウント設定': 1,
    '担当者': 1,
    'テンプレート': 1,
    'ラベル': 1,
    'カスタム属性': 1,
    '自動化': 1,
    'ボット': 1,
    'マクロ': 1,
    '定型文': 1,
    Contacts: 1,
    Campaigns: 1,
    'Help Center': 1,
    Help: 1,
    Companies: 1,
    Calls: 1,
    Captain: 1,
    'Conversation Data': 1,
    Teams: 1,
    Mentions: 1,
    Participating: 1,
    'Account Settings': 1,
    Agents: 1,
    Inboxes: 1,
    Templates: 1,
    Labels: 1,
    'Custom Attributes': 1,
    Automation: 1,
    Automations: 1,
    Bots: 1,
    Macros: 1,
    'Canned Responses': 1
  };
  var STOCK_ICON_RE = /\b(i-lucide-contact|i-lucide-library-big|i-woot-captain|i-lucide-building-2|i-lucide-phone|i-lucide-sparkles|i-lucide-bot|i-lucide-users|i-lucide-users-round|i-lucide-messages-square)\b/;
  var STOCK_HREF_RE = /\/(contacts|campaigns|portals|captain|companies|calls|notifications|mentions|participating)(\/|\?|#|$)/;
  var INJECT_RETRY_MS = [0, 16, 50, 100, 200, 400, 800, 1600, 3200, 6000, 10000];

  function isToybacoNavRow(row) {
    if (!row) return false;
    try {
      if (row.getAttribute && (
        row.getAttribute('data-' + MARK + '-wrap') === '1' ||
        row.getAttribute('data-' + MARK) ||
        row.getAttribute('data-' + BILLING_MARK)
      )) return true;
      return !!(row.querySelector && row.querySelector(
        '[data-' + MARK + '], [data-' + MARK + '-wrap], [data-' + BILLING_MARK + ']'
      ));
    } catch (e) { return false; }
  }

  function classNameOf(node) {
    var cls = node && node.className;
    if (typeof cls === 'string') return cls;
    if (cls && typeof cls.baseVal === 'string') return cls.baseVal;
    return '';
  }

  function walkNavNodes(row, visit) {
    if (!row) return;
    visit(row);
    var kids = row.children || [];
    for (var i = 0; i < kids.length; i += 1) walkNavNodes(kids[i], visit);
  }

  function walkOwnRow(row, visit) {
    if (!row) return;
    visit(row);
    var kids = row.children || [];
    for (var i = 0; i < kids.length; i += 1) {
      var tag = kids[i].tagName && String(kids[i].tagName).toLowerCase();
      if (tag === 'ul') continue;
      walkOwnRow(kids[i], visit);
    }
  }

  function rowLooksStock(row) {
    if (!row || isToybacoNavRow(row)) return false;
    try {
      var hit = false;
      walkOwnRow(row, function (node) {
        if (hit) return;
        var title = node.getAttribute && node.getAttribute('title');
        if (title && STOCK_TITLES[title]) { hit = true; return; }
        var cls = classNameOf(node);
        if (STOCK_ICON_RE.test(cls)) { hit = true; return; }
        if (/\bi-lucide-megaphone\b/.test(cls) && !isToybacoNavRow(row)) { hit = true; return; }
        var href = (node.getAttribute && node.getAttribute('href')) || node.href || '';
        if (href && STOCK_HREF_RE.test(href)) hit = true;
      });
      return hit;
    } catch (e) { return false; }
  }

  function hideStockRow(row) {
    try {
      if (row.style && row.style.setProperty) {
        row.style.setProperty('display', 'none', 'important');
      } else if (row.style) {
        row.style.display = 'none';
      }
      if (row.setAttribute) row.setAttribute('data-toybaco-stock-hidden', '1');
      if (row.setAttribute) row.setAttribute('aria-hidden', 'true');
    } catch (e) { /* 隠せなくても受信箱の邪魔はしない */ }
  }

  function primaryNavList() {
    try {
      if (typeof document.querySelector === 'function') {
        var preferred = document.querySelector('aside nav > ul') ||
          document.querySelector('aside nav ul');
        if (preferred) return preferred;
      }
    } catch (e) { /* テストfixtureや古いDOMでも落とさない */ }
    try {
      var navs = document.querySelectorAll('nav');
      for (var i = 0; i < navs.length; i += 1) {
        var ul = navs[i].querySelector && navs[i].querySelector('ul');
        if (ul) return ul;
      }
    } catch (e) { /* noop */ }
    return null;
  }

  function hideStockNav() {
    try {
      var ul = primaryNavList();
      if (!ul) return;
      var rows = ul.children || [];
      for (var i = 0; i < rows.length; i += 1) {
        var row = rows[i];
        if (rowLooksStock(row)) hideStockRow(row);
      }
      hideLeftoverTrees();
    } catch (e) { /* 隠せなくても受信箱の邪魔はしない */ }
  }

  function nodeTitleOrLeaf(node) {
    var title = node.getAttribute && node.getAttribute('title');
    if (title && STOCK_TITLES[title]) return title;
    var text = '';
    try { text = (node.textContent || '').replace(/\s+/g, ' ').trim(); } catch (e) { text = ''; }
    if (text && STOCK_TITLES[text]) return text;
    return '';
  }

  function hideLeftoverTrees() {
    try {
      var nav = document.querySelector('aside nav');
      if (!nav || !nav.querySelectorAll) return;
      var nodes = nav.querySelectorAll('li, a, [role="button"], button, div[title], span');
      for (var i = 0; i < nodes.length; i += 1) {
        var node = nodes[i];
        if (isToybacoNavRow(node)) continue;
        if (!nodeTitleOrLeaf(node)) continue;
        var row = node;
        if (node.closest) {
          row = node.closest('li') || node.closest('aside nav > *') || node;
        }
        if (isToybacoNavRow(row)) continue;
        hideStockRow(row);
      }
    } catch (e) { /* 隠せなくても受信箱の邪魔はしない */ }
  }

  function rowInner(row) {
    if (!row) return null;
    try {
      if (row.querySelector) {
        var inner = row.querySelector('a, [role="button"]');
        if (inner) return inner;
      }
      if (row.getAttribute && row.getAttribute('role') === 'button') return row;
      if (row.tagName && String(row.tagName).toLowerCase() === 'a') return row;
    } catch (e) { /* 行の中身が取れなくても次を見る */ }
    return null;
  }

  function hrefOf(node) {
    return ((node && node.getAttribute && node.getAttribute('href')) || (node && node.href) || '') + '';
  }

  function primaryNavKind(row) {
    var kind = '';
    walkOwnRow(row, function (node) {
      var title = node.getAttribute && node.getAttribute('title');
      if (/^(会話|Conversations|Inbox)$/.test(title || '')) kind = 'inbox';
      else if (/^(レポート|Reports)$/.test(title || '')) kind = 'reports';
      else if (/^(設定|Settings)$/.test(title || '')) kind = 'settings';
    });
    return kind;
  }

  function primaryNavDestination(kind, id) {
    var prefix = '/app/accounts/' + id;
    return prefix + (kind === 'reports' ? '/reports/overview' : kind === 'settings' ? '/settings/general' : '/dashboard');
  }

  function ensurePrimaryNavigation(sample) {
    var id = currentAccountId();
    if (!id || !sample) return;
    var rows = sample.ul.children || [];
    for (var i = 0; i < rows.length; i += 1) {
      var row = rows[i];
      if (isToybacoNavRow(row)) continue;
      var kind = primaryNavKind(row);
      if (!kind) continue;
      var link = rowInner(row);
      if (!link) continue;
      row.setAttribute('data-toybaco-primary-nav', kind);
      link.setAttribute('data-toybaco-nav-link', kind);
      if (link.tagName === 'A') {
        var dest = primaryNavDestination(kind, id);
        link.setAttribute('href', dest);
        link.href = dest;
      } else if (!link.getAttribute('data-toybaco-nav-keyboard')) {
        link.setAttribute('tabindex', '0');
        link.setAttribute('data-toybaco-nav-keyboard', '1');
        link.addEventListener('keydown', function (event) {
          if (event.key !== 'Enter' && event.key !== ' ') return;
          event.preventDefault();
          event.stopPropagation();
          if (event.stopImmediatePropagation) event.stopImmediatePropagation();
          navigatePrimaryNav(this.getAttribute('data-toybaco-nav-link'));
        }, true);
      }
    }
  }

  function navigatePrimaryNav(kind) {
    var id = currentAccountId();
    if (!id) return;
    var returnToConversation = kind === 'inbox' && (panel || billingPanel) &&
      /\/(dashboard|inbox|conversations)(?:\/|$)/.test(window.location.pathname);
    closeAiModePanel();
    closeBillingPanel();
    closePanel();
    if (returnToConversation) return;
    var dest = primaryNavDestination(kind, id);
    if (window.location.pathname === dest) { syncPostingSelection(); return; }
    // 既存の子RouterLinkを経由し、Vueの会話・下書きを保ったまま画面を切り替える。
    var nativeLink = null;
    walkNavNodes(primaryNavList(), function (node) {
      if (nativeLink || !node || !node.getAttribute || node.getAttribute('data-toybaco-nav-link')) return;
      if (hrefOf(node) === dest && typeof node.click === 'function') nativeLink = node;
    });
    if (nativeLink) nativeLink.click();
    else window.location.href = dest;
  }

  function isInboxSample(row) {
    if (!row) return false;
    try {
      var hit = false;
      walkNavNodes(row, function (node) {
        if (hit) return;
        var title = node.getAttribute && node.getAttribute('title');
        if (title === '会話' || title === 'Conversations' || title === 'Inbox') { hit = true; return; }
        var cls = classNameOf(node);
        if (/\bi-lucide-inbox\b/.test(cls) || /\bi-lucide-message-circle\b/.test(cls)) { hit = true; return; }
        var href = hrefOf(node);
        if (href && /\/(inbox|inbox-view|conversations)(\/|\?|#|$)/.test(href)) hit = true;
      });
      return hit;
    } catch (e) { return false; }
  }

  function isContractOrSettingsRow(row) {
    if (!row) return false;
    try {
      if (row.getAttribute && (
        row.getAttribute('data-' + BILLING_MARK) ||
        row.getAttribute('data-' + BILLING_MARK) === '' ||
        row.getAttribute('data-' + AI_MARK) ||
        row.getAttribute('data-' + AI_MARK) === ''
      )) return true;
      if (row.querySelector && row.querySelector('[data-' + BILLING_MARK + '], [data-' + AI_MARK + ']')) return true;
      var hit = false;
      walkNavNodes(row, function (node) {
        if (hit) return;
        var href = hrefOf(node);
        if (href && /\/settings(\/|\?|#|$)/.test(href)) hit = true;
      });
      return hit;
    } catch (e) { return false; }
  }

  function firstSampleRow(ul) {
    if (!ul) return null;
    // 再描画時に自分自身を「先頭の標準行」と誤認しない。
    // 会話行を優先する。settings/templates やご契約を手本にしない。
    var kids = ul.children || [];
    var fallback = null;
    var i;
    for (i = 0; i < kids.length; i += 1) {
      var row = kids[i];
      if (!row || isToybacoNavRow(row) || !rowInner(row)) continue;
      if (row.getAttribute && row.getAttribute('data-toybaco-stock-hidden') === '1') continue;
      if (isContractOrSettingsRow(row)) continue;
      if (isInboxSample(row)) return row;
      if (!fallback) fallback = row;
    }
    if (fallback) return fallback;
    var li = null;
    try {
      if (ul.querySelector) {
        li = ul.querySelector(':scope > li:not([data-' + MARK + '-wrap])');
      }
    } catch (e) { li = null; }
    while (li && (
      (li.getAttribute && li.getAttribute('data-toybaco-stock-hidden') === '1') ||
      isToybacoNavRow(li) ||
      isContractOrSettingsRow(li) ||
      !rowInner(li)
    )) {
      li = li.nextElementSibling;
      while (li && li.tagName && li.tagName.toLowerCase() !== 'li') {
        li = li.nextElementSibling;
      }
    }
    return li && rowInner(li) ? li : null;
  }

  function menuFromUl(ul) {
    if (!ul) return null;
    var li = firstSampleRow(ul);
    if (!li) return null;
    var inner = rowInner(li);
    if (!inner) return null;
    return { ul: ul, li: li, inner: inner };
  }

  function findMenu() {
    try {
      if (typeof document.querySelector === 'function') {
        var asideUl = document.querySelector('aside nav > ul') ||
          document.querySelector('aside nav ul');
        var preferred = menuFromUl(asideUl);
        if (preferred) return preferred;
      }
    } catch (e) { /* aside が無い初回描画では通常の nav を探す */ }
    var navs = document.querySelectorAll('nav');
    for (var i = 0; i < navs.length; i += 1) {
      var ul = navs[i].querySelector('ul');
      if (!ul) continue;
      var found = menuFromUl(ul);
      if (found) return found;
    }
    return null;
  }

  function removePostEntry() {
    var el = document.querySelector('[data-' + MARK + ']');
    if (el && el.parentElement) el.parentElement.remove();
  }

  // 「ご契約内容」: プラン変更・カード変更・解約ができるページへの入口。
  // 契約の管理は全員に見えてよいので会社を問わず出す
  function injectBilling(sample) {
    try {
      if (document.querySelector('[data-' + BILLING_MARK + ']')) return;
      var li = document.createElement('li');
      li.className = sample.li.className;
      var a = document.createElement('a');
      a.href = '#';
      a.className = navigationClassName(sample.inner);
      a.title = 'ご契約内容';
      a.setAttribute('data-' + BILLING_MARK, '1');
      a.setAttribute('data-toybaco-nav-link', 'billing');
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
      a.addEventListener('click', function (e) {
        if (e.preventDefault) e.preventDefault();
        if (e.stopPropagation) e.stopPropagation();
        if (e.stopImmediatePropagation) e.stopImmediatePropagation();
      }, true);
      li.appendChild(a);
      sample.ul.appendChild(li);
    } catch (e) { /* 出せなくても邪魔はしない */ }
  }

  function normalizeAiMode(value) {
    var text = (value || '').toString();
    if (text === AI_MODE_DRAFT || text === AI_MODE_LABELS[AI_MODE_DRAFT]) return AI_MODE_DRAFT;
    if (text === AI_MODE_AUTO || text === AI_MODE_LABELS[AI_MODE_AUTO]) return AI_MODE_AUTO;
    return null;
  }

  function aiModeLabel(value) {
    return AI_MODE_LABELS[normalizeAiMode(value)] || '未確認';
  }

  function aiModeState(accountId) {
    var id = accountId || currentAccountId() || '';
    if (!aiModeStates[id]) aiModeStates[id] = { mode: null, phase: 'idle', message: '' };
    return aiModeStates[id];
  }

  function currentAiMode(accountId) {
    return aiModeState(accountId).mode;
  }

  function aiReadinessState(accountId) {
    var id = accountId || currentAccountId() || '';
    if (!aiReadinessStates[id]) aiReadinessStates[id] = { phase: 'idle', data: null };
    return aiReadinessStates[id];
  }

  function aiModeCanEdit() {
    var readiness = aiReadinessState();
    return aiModeState().phase === 'ready' && readiness.phase === 'ready' &&
      readiness.data.connection === 'configured';
  }

  function prefetchAiReadiness(accountId, force) {
    var id = accountId || currentAccountId();
    if (!id || !/^[1-9]\d*$/.test(String(id))) return Promise.resolve(null);
    if (aiReadinessInflight[id]) return aiReadinessInflight[id];
    var state = aiReadinessState(id);
    if (!force && state.phase !== 'idle') return Promise.resolve(null);
    state.data = null;
    state.phase = window.fetch ? 'loading' : 'error';
    if (id === currentAccountId()) paintAiModeControls();
    if (!window.fetch) return Promise.resolve(null);
    aiReadinessInflight[id] = requestAiJson('/toybaco/ai_readiness?account_id=' + encodeURIComponent(id), {
      credentials: 'same-origin', cache: 'no-store', headers: { Accept: 'application/json' }
    }, function (body) {
      function count(value) { return typeof value === 'number' && isFinite(value) && value >= 0 && Math.floor(value) === value; }
      if (!body || ['configured', 'unconnected', 'unknown'].indexOf(body.connection) < 0 ||
        !count(body.configured_inboxes) || !count(body.total_inboxes) ||
        body.configured_inboxes > body.total_inboxes || body.live_verification !== 'unverified' ||
        (body.connection === 'configured' && body.configured_inboxes === 0) ||
        (body.connection === 'unconnected' && body.configured_inboxes !== 0)) throw new Error('invalid connection');
      return body;
    }).then(function (body) {
      delete aiReadinessInflight[id];
      state.phase = 'ready';
      state.data = body;
      if (id === currentAccountId()) paintAiModeControls();
      return body;
    }).catch(function () {
      delete aiReadinessInflight[id];
      state.phase = 'error';
      state.data = null;
      if (id === currentAccountId()) paintAiModeControls();
      return null;
    });
    return aiReadinessInflight[id];
  }

  function aiModeUrl(accountId) {
    if (!accountId || !/^\d+$/.test(String(accountId))) return '';
    return '/toybaco/ai_reply_mode?account_id=' + encodeURIComponent(accountId);
  }

  function applyAiMode(accountId, mode) {
    var next = normalizeAiMode(mode);
    var state = aiModeState(accountId);
    state.mode = next;
    state.phase = next ? 'ready' : 'error';
    state.message = '';
    // 他店舗の遅れて届いた応答で、今開いている店舗の選択を変えない。
    if (accountId === currentAccountId()) paintAiModeControls();
    return next;
  }

  function paintAiModeControls() {
    var state = aiModeState();
    var readiness = aiReadinessState();
    var connection = readiness.phase === 'ready' ? readiness.data.connection : 'unknown';
    var selected = state.mode;
    var busy = state.phase === 'loading' || state.phase === 'saving' || readiness.phase === 'loading';
    var text = state.message;
    if (!text) {
      if (state.phase === 'error') text = '設定を確認できませんでした。再確認してください。';
      else if (state.phase !== 'ready') text = '店舗全体の設定を確認しています…';
      else text = '保存された設定：' + aiModeLabel(selected);
    }
    var connectionText = 'AI応答の接続状態を確認できません。再確認してください。';
    if (readiness.phase === 'loading' || readiness.phase === 'idle') connectionText = 'AI応答の接続設定を確認しています…';
    else if (connection === 'unconnected') connectionText = 'AI応答は未接続です。担当者が返信してください。';
    else if (connection === 'configured') connectionText = '接続設定あり（受信箱 ' + readiness.data.configured_inboxes +
      ' / ' + readiness.data.total_inboxes + ' 件）。外部への応答動作は未確認です。利用可否・残り枠はご契約の利用状況をご確認ください。';
    try {
      var buttons = document.querySelectorAll('[data-toybaco-ai-mode]');
      var i;
      for (i = 0; i < buttons.length; i += 1) {
        var btn = buttons[i];
        var value = btn.getAttribute && btn.getAttribute('data-toybaco-ai-mode');
        if (btn.setAttribute) {
          btn.setAttribute('aria-pressed', value === selected ? 'true' : 'false');
          btn.setAttribute('data-toybaco-ai-on', value === selected ? '1' : '0');
          btn.setAttribute('aria-disabled', aiModeCanEdit() ? 'false' : 'true');
          btn.disabled = !aiModeCanEdit();
        }
      }
      var groups = document.querySelectorAll('[data-toybaco-ai-mode-bar], [data-toybaco-ai-mode-panel]');
      for (i = 0; i < groups.length; i += 1) {
        groups[i].setAttribute('data-toybaco-ai-current', selected || 'unknown');
        groups[i].setAttribute('data-toybaco-ai-state', state.phase);
        groups[i].setAttribute('data-toybaco-ai-connection', readiness.phase === 'ready' ? connection : readiness.phase);
        groups[i].setAttribute('aria-busy', busy ? 'true' : 'false');
      }
      var statuses = document.querySelectorAll('[data-toybaco-ai-status]');
      for (i = 0; i < statuses.length; i += 1) {
        // 同じ文面を書き直してMutationObserverを再起動しない。
        if (statuses[i].textContent !== text) statuses[i].textContent = text;
      }
      var connections = document.querySelectorAll('[data-toybaco-ai-readiness]');
      for (i = 0; i < connections.length; i += 1) {
        if (connections[i].textContent !== connectionText) connections[i].textContent = connectionText;
      }
      var retries = document.querySelectorAll('[data-toybaco-ai-retry]');
      for (i = 0; i < retries.length; i += 1) retries[i].hidden = state.phase !== 'error' &&
        readiness.phase !== 'error' && (readiness.phase !== 'ready' || connection === 'configured');
    } catch (e) { /* 選べなくても受信箱は壊さない */ }
  }

  function requestAiJson(url, options, validate) {
    return new Promise(function (resolve, reject) {
      var settled = false;
      var timer = setTimeout(function () { finish(new Error('timeout')); }, AI_MODE_TIMEOUT_MS);
      function finish(error, body) {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (error) reject(error);
        else resolve(body);
      }
      try {
        Promise.resolve(fetch(url, options)).then(function (res) {
          if (!res || !res.ok) throw new Error('request failed');
          return res.json();
        }).then(function (body) {
          finish(null, validate(body));
        }).catch(function (error) { finish(error); });
      } catch (error) { finish(error); }
    });
  }

  function requestAiMode(url, options) {
    return requestAiJson(url, options, function (body) {
      if (!body || !normalizeAiMode(body.mode)) throw new Error('invalid mode');
      return body;
    });
  }

  function aiUsageState(accountId) {
    var id = accountId || currentAccountId() || '';
    if (!aiUsageStates[id]) aiUsageStates[id] = { phase: 'idle', data: null };
    return aiUsageStates[id];
  }

  function validateAiUsage(body) {
    function count(value) {
      return typeof value === 'number' && isFinite(value) && value >= 0 &&
        Math.floor(value) === value && value <= 9007199254740991;
    }
    var reasons = [null, 'unknown_contract', 'account_inactive', 'disabled', 'limit_reached'];
    if (!body || typeof body.enabled !== 'boolean' || !count(body.used) || !count(body.reserved) ||
      !/^\d{4}-(0[1-9]|1[0-2])$/.test(body.period) ||
      typeof body.resets_at !== 'string' ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(body.resets_at) ||
      !isFinite(Date.parse(body.resets_at)) ||
      reasons.indexOf(body.reason) < 0 ||
      (body.limit === null ? body.remaining !== null :
        (!count(body.limit) || !count(body.remaining) || body.remaining > body.limit)) ||
      (body.enabled ? (body.reason !== null && body.reason !== 'limit_reached') :
        (body.reason === null || body.reason === 'limit_reached')) ||
      (body.reason === 'limit_reached' && body.remaining !== 0)) {
      throw new Error('invalid usage');
    }
    return body;
  }

  function aiUsageResetLabel(value) {
    var japan = new Date(Date.parse(value) + 9 * 60 * 60 * 1000);
    var minutes = ('0' + japan.getUTCMinutes()).slice(-2);
    return japan.getUTCFullYear() + '年' + (japan.getUTCMonth() + 1) + '月' + japan.getUTCDate() +
      '日 ' + japan.getUTCHours() + ':' + minutes + '（日本時間）に更新';
  }

  function paintAiUsage() {
    var card = document.querySelector('[data-toybaco-ai-usage]');
    if (!card || card.getAttribute('data-account') !== currentAccountId()) return;
    var state = aiUsageState();
    var data = state.phase === 'ready' ? state.data : null;
    var active = data && data.enabled;
    var busy = state.phase === 'loading' || state.phase === 'idle';
    var message = busy ? '利用状況を確認しています…' : '利用状況を取得できませんでした。再確認してください。';
    if (data) {
      if (data.reason === 'unknown_contract') message = 'AI応答の利用条件を確認できません。ご契約内容をご確認ください。';
      else if (data.reason === 'account_inactive') message = '現在、この店舗のAI応答はご利用いただけません。ご契約内容をご確認ください。';
      else if (data.reason === 'disabled') message = '現在のご契約にはAI応答が含まれていません。';
      else if (data.remaining === 0) message = '現在、利用できる残り枠がありません。';
      else message = '全自動・下書きで共通の利用枠です。';
    }
    card.setAttribute('aria-busy', busy ? 'true' : 'false');
    card.setAttribute('data-toybaco-ai-usage-state', state.phase === 'error' ? 'error' :
      (data && (!active || data.remaining === 0) ? 'limited' : state.phase));
    var heading = card.querySelector('[data-toybaco-ai-usage-heading]');
    heading.textContent = active ? data.period.slice(0, 4) + '年' + Number(data.period.slice(5)) + '月のAI応答' : 'AI応答の利用状況';
    var value = card.querySelector('[data-toybaco-ai-usage-value]');
    value.textContent = active ? data.used.toLocaleString('ja-JP') +
      (data.limit === null ? ' 件利用済み' : ' / ' + data.limit.toLocaleString('ja-JP') + ' 件') : '';
    value.hidden = !active;
    var details = card.querySelector('[data-toybaco-ai-usage-details]');
    details.textContent = active ? (data.remaining === null ? '利用上限なし' :
      '残り ' + data.remaining.toLocaleString('ja-JP') + ' 件') +
      (data.reserved ? ' · 処理中 ' + data.reserved.toLocaleString('ja-JP') + ' 件' : '') : '';
    details.hidden = !active;
    var reset = card.querySelector('[data-toybaco-ai-usage-reset]');
    reset.textContent = active ? aiUsageResetLabel(data.resets_at) : '';
    reset.hidden = !active;
    card.querySelector('[data-toybaco-ai-usage-status]').textContent = message;
    var refresh = card.querySelector('[data-toybaco-ai-usage-refresh]');
    refresh.textContent = state.phase === 'error' ? '再確認' : '更新';
    refresh.disabled = busy;
    var meter = card.querySelector('[data-toybaco-ai-usage-meter]');
    meter.hidden = !active || data.limit === null || data.limit === 0;
    if (!meter.hidden) {
      var used = Math.min(data.used, data.limit);
      meter.setAttribute('aria-valuemin', '0');
      meter.setAttribute('aria-valuemax', String(data.limit));
      meter.setAttribute('aria-valuenow', String(used));
      meter.setAttribute('aria-valuetext', value.textContent + '利用済み、' + details.textContent);
      meter.querySelector('[data-toybaco-ai-usage-used]').style.width = (used / data.limit * 100) + '%';
      meter.querySelector('[data-toybaco-ai-usage-reserved]').style.width =
        (Math.min(data.reserved, data.limit - used) / data.limit * 100) + '%';
    } else {
      meter.removeAttribute('aria-valuenow');
      meter.removeAttribute('aria-valuemax');
      meter.removeAttribute('aria-valuetext');
    }
  }

  function prefetchAiUsage(accountId) {
    var id = accountId || currentAccountId();
    if (!id || !/^[1-9]\d*$/.test(String(id))) return Promise.resolve(null);
    if (aiUsageInflight[id]) {
      if (id === currentAccountId()) paintAiUsage();
      return aiUsageInflight[id];
    }
    var state = aiUsageState(id);
    state.data = null;
    state.phase = window.fetch ? 'loading' : 'error';
    if (id === currentAccountId()) paintAiUsage();
    if (!window.fetch) return Promise.resolve(null);
    aiUsageInflight[id] = requestAiJson('/toybaco/ai_usage?account_id=' + encodeURIComponent(id), {
      credentials: 'same-origin', cache: 'no-store', headers: { Accept: 'application/json' }
    }, validateAiUsage).then(function (body) {
      delete aiUsageInflight[id];
      state.data = body;
      state.phase = 'ready';
      if (id === currentAccountId()) paintAiUsage();
      return body;
    }).catch(function () {
      delete aiUsageInflight[id];
      state.data = null;
      state.phase = 'error';
      if (id === currentAccountId()) paintAiUsage();
      return null;
    });
    return aiUsageInflight[id];
  }

  function appendAiUsage(host) {
    var card = document.createElement('section');
    card.setAttribute('data-toybaco-ai-usage', '1');
    card.setAttribute('data-account', currentAccountId());
    card.setAttribute('aria-label', 'AI応答の利用状況');
    var head = document.createElement('div');
    head.setAttribute('data-toybaco-ai-usage-head', '1');
    var title = document.createElement('strong');
    title.setAttribute('data-toybaco-ai-usage-heading', '1');
    head.appendChild(title);
    var refresh = document.createElement('button');
    refresh.type = 'button';
    refresh.setAttribute('data-toybaco-ai-usage-refresh', '1');
    refresh.setAttribute('aria-label', 'AI応答の利用状況を更新');
    refresh.addEventListener('click', function () { prefetchAiUsage(currentAccountId()); });
    head.appendChild(refresh);
    card.appendChild(head);
    ['value', 'details', 'reset', 'status'].forEach(function (name) {
      var node = document.createElement(name === 'value' ? 'strong' : 'div');
      node.setAttribute('data-toybaco-ai-usage-' + name, '1');
      if (name === 'status') { node.setAttribute('role', 'status'); node.setAttribute('aria-live', 'polite'); }
      card.appendChild(node);
    });
    var meter = document.createElement('div');
    meter.setAttribute('data-toybaco-ai-usage-meter', '1');
    meter.setAttribute('role', 'progressbar');
    meter.setAttribute('aria-label', 'AI応答の利用枠');
    ['used', 'reserved'].forEach(function (name) {
      var fill = document.createElement('span');
      fill.setAttribute('data-toybaco-ai-usage-' + name, '1');
      meter.appendChild(fill);
    });
    card.insertBefore(meter, card.querySelector('[data-toybaco-ai-usage-details]'));
    host.appendChild(card);
  }

  function prefetchAiMode(accountId, force, recoveredMessage) {
    var id = accountId || currentAccountId();
    var url = aiModeUrl(id);
    if (!url) return Promise.resolve(null);
    if (id === currentAccountId() && aiModeAccount !== id) {
      aiModeAccount = id;
      closeAiModePanel();
      force = true;
    }
    prefetchAiReadiness(id, force);
    if (aiModeInflight[id]) return aiModeInflight[id];
    var state = aiModeState(id);
    // DOMの描画ごとにGETを繰り返さず、店舗切替・設定を開く・再確認で更新する。
    if (!force && state.phase !== 'idle') return Promise.resolve(null);
    state.mode = null;
    state.phase = window.fetch ? 'loading' : 'error';
    state.message = recoveredMessage ? '保存結果を確認しています…' : '';
    if (id === currentAccountId()) paintAiModeControls();
    if (!window.fetch) return Promise.resolve(null);
    aiModeInflight[id] = requestAiMode(url, {
      credentials: 'same-origin',
      cache: 'no-store',
      headers: { Accept: 'application/json' }
    }).then(function (body) {
      delete aiModeInflight[id];
      applyAiMode(id, body.mode);
      state.message = recoveredMessage ? '変更の応答を確認できませんでした。現在の設定：' + aiModeLabel(body.mode) : '';
      if (id === currentAccountId()) paintAiModeControls();
      return body;
    }).catch(function () {
      delete aiModeInflight[id];
      state.phase = 'error';
      state.mode = null;
      state.message = recoveredMessage ? '保存結果を確認できませんでした。再確認してください。' : '';
      if (id === currentAccountId()) paintAiModeControls();
      return null;
    });
    return aiModeInflight[id];
  }

  function saveAiMode(mode) {
    var id = currentAccountId();
    var next = normalizeAiMode(mode);
    var url = aiModeUrl(id);
    var state = aiModeState(id);
    if (!url || !next || !window.fetch) return Promise.resolve(null);
    if (aiModeAccount !== id) return prefetchAiMode(id, true);
    // 取得中・保存中の連打や、古い店舗のボタン操作から二重PUTを作らない。
    if (!aiModeCanEdit() || next === state.mode) return aiModeInflight[id] || Promise.resolve(null);
    state.phase = 'saving';
    state.message = aiModeLabel(next) + 'へ変更しています…';
    paintAiModeControls();
    aiModeInflight[id] = requestAiMode(url, {
      method: 'PUT',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ mode: next })
    }).then(function (body) {
      delete aiModeInflight[id];
      applyAiMode(id, body.mode);
      return body;
    }).catch(function () {
      delete aiModeInflight[id];
      // 通信が途切れてもサーバー側は保存済みの可能性がある。推測で戻さず読戻す。
      return prefetchAiMode(id, true, true);
    });
    return aiModeInflight[id];
  }

  function appendAiModeStatus(host) {
    var status = document.createElement('span');
    status.setAttribute('data-toybaco-ai-status', '1');
    status.setAttribute('role', 'status');
    status.setAttribute('aria-live', 'polite');
    host.appendChild(status);
    var connection = document.createElement('span');
    connection.setAttribute('data-toybaco-ai-readiness', '1');
    connection.setAttribute('role', 'status');
    connection.setAttribute('aria-live', 'polite');
    host.appendChild(connection);
    var retry = document.createElement('button');
    retry.type = 'button';
    retry.setAttribute('data-toybaco-ai-retry', '1');
    retry.textContent = '再確認';
    retry.hidden = true;
    retry.addEventListener('click', function () { prefetchAiMode(currentAccountId(), true); });
    host.appendChild(retry);
  }

  function buildAiModeButton(mode, kind) {
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.setAttribute('data-toybaco-ai-mode', mode);
    btn.setAttribute('data-toybaco-ai-kind', kind || 'chip');
    btn.textContent = aiModeLabel(mode);
    btn.setAttribute('aria-pressed', currentAiMode() === mode ? 'true' : 'false');
    btn.setAttribute('data-toybaco-ai-on', currentAiMode() === mode ? '1' : '0');
    btn.disabled = !aiModeCanEdit();
    return btn;
  }

  function findReplyBoxes() {
    var found = [];
    function walk(node) {
      if (!node) return;
      if (/\breply-box\b/.test(classNameOf(node))) found.push(node);
      var kids = node.children || [];
      var i;
      for (i = 0; i < kids.length; i += 1) walk(kids[i]);
    }
    try { walk(document.body); } catch (e) { /* noop */ }
    return found;
  }

  function ensureComposerAiBar() {
    try {
      var boxes = findReplyBoxes();
      var i;
      for (i = 0; i < boxes.length; i += 1) {
        var box = boxes[i];
        if (!box || !box.parentElement) continue;
        if (box.previousElementSibling && box.previousElementSibling.getAttribute &&
          box.previousElementSibling.getAttribute('data-toybaco-ai-mode-bar') === '1') {
          continue;
        }
        var bar = document.createElement('div');
        bar.setAttribute('data-toybaco-ai-mode-bar', '1');
        var title = document.createElement('button');
        title.type = 'button';
        title.setAttribute('data-toybaco-ai-mode-h', '1');
        title.setAttribute('data-' + AI_MARK, '1');
        title.textContent = AI_NAV_LABEL;
        bar.appendChild(title);
        var scope = document.createElement('span');
        scope.setAttribute('data-toybaco-ai-scope', '1');
        scope.textContent = '店舗全体';
        bar.appendChild(scope);
        bar.appendChild(buildAiModeButton(AI_MODE_AUTO, 'chip'));
        bar.appendChild(buildAiModeButton(AI_MODE_DRAFT, 'chip'));
        appendAiModeStatus(bar);
        box.parentElement.insertBefore(bar, box);
      }
      paintAiModeControls();
    } catch (e) { /* 返信欄の横に出せなくても受信箱は壊さない */ }
  }

  var aiPanel = null;
  var aiPanelReturnFocus = null;

  function openAiModePanel() {
    try {
      if (aiPanel) { closeAiModePanel(); return; }
      closeBillingPanel();
      prefetchAiMode(currentAccountId(), true);
      aiPanelReturnFocus = document.activeElement;
      var wrapEl = document.createElement('div');
      wrapEl.setAttribute('data-toybaco-ai-mode-panel', '1');
      wrapEl.setAttribute('role', 'dialog');
      wrapEl.setAttribute('aria-label', '店舗全体のAI応答設定');
      var head = document.createElement('div');
      head.setAttribute('data-toybaco-ai-mode-head', '1');
      var title = document.createElement('strong');
      title.textContent = AI_NAV_LABEL;
      head.appendChild(title);
      var close = document.createElement('button');
      close.type = 'button';
      close.textContent = '閉じる';
      close.addEventListener('click', closeAiModePanel);
      head.appendChild(close);
      wrapEl.appendChild(head);
      var lead = document.createElement('p');
      lead.textContent = 'この店舗全体で使う、AI応答の送り方の保存設定です。接続設定と利用条件は別に確認します。';
      wrapEl.appendChild(lead);
      var autoBtn = buildAiModeButton(AI_MODE_AUTO, 'card');
      var autoHelp = document.createElement('small');
      autoHelp.textContent = '一次応答を自動送信する設定';
      autoBtn.appendChild(autoHelp);
      wrapEl.appendChild(autoBtn);
      var draftBtn = buildAiModeButton(AI_MODE_DRAFT, 'card');
      var draftHelp = document.createElement('small');
      draftHelp.textContent = 'AI は下書き・送信は人';
      draftBtn.appendChild(draftHelp);
      wrapEl.appendChild(draftBtn);
      appendAiModeStatus(wrapEl);
      appendAiUsage(wrapEl);
      var host = document.querySelector('main') || document.body;
      if (host && host.appendChild) host.appendChild(wrapEl);
      else document.body.appendChild(wrapEl);
      aiPanel = wrapEl;
      paintAiModeControls();
      prefetchAiUsage(currentAccountId());
      if (close.focus) close.focus();
      document.addEventListener('keydown', escCloseAiMode);
    } catch (e) { /* 開けなくても邪魔はしない */ }
  }

  function closeAiModePanel() {
    if (!aiPanel) return;
    try { aiPanel.remove(); } catch (e) { /* noop */ }
    aiPanel = null;
    document.removeEventListener('keydown', escCloseAiMode);
    if (aiPanelReturnFocus && aiPanelReturnFocus.isConnected !== false && aiPanelReturnFocus.focus) {
      aiPanelReturnFocus.focus();
    }
    aiPanelReturnFocus = null;
  }

  function escCloseAiMode(e) {
    if (e.key === 'Escape') closeAiModePanel();
  }

  var billingPanel = null;
  var billingPath = null;

  // ご契約内容: 同じアプリの中の画面(/toybaco/billing)をパネルで開く。
  // 決済情報に触れる操作だけ、その画面の中から Stripe の安全なページを新しいタブで開く
  function openBillingPanel() {
    try {
      if (billingPanel) { closeBillingPanel(); return; }
      var id = currentAccountId();
      if (!id) return;
      closePanel();
      var wrapEl = document.createElement('div');
      wrapEl.setAttribute('data-toybaco-billing-panel', '1');
      wrapEl.style.cssText = 'position:fixed;top:0;right:0;bottom:0;left:' + computeLeft() +
        'px;z-index:9998;background:#FAF7F2;box-shadow:-8px 0 24px rgba(0,0,0,.12);display:flex;flex-direction:column;';
      var bar = document.createElement('div');
      bar.style.cssText = 'display:flex;justify-content:flex-end;padding:8px 12px;';
      var close = document.createElement('button');
      close.textContent = '× 閉じる';
      close.style.cssText = 'border:none;background:none;cursor:pointer;font-size:14px;color:#6B7684;padding:6px 10px;';
      close.addEventListener('click', closeBillingPanel);
      bar.appendChild(close);
      var frame = document.createElement('iframe');
      frame.src = '/toybaco/billing?account_id=' + encodeURIComponent(id);
      frame.title = 'ご契約内容';
      frame.style.cssText = 'flex:1;border:none;width:100%;';
      wrapEl.appendChild(bar);
      wrapEl.appendChild(frame);
      document.body.appendChild(wrapEl);
      billingPanel = wrapEl;
      billingPath = window.location.pathname;
      syncPostingSelection();
      document.addEventListener('keydown', escCloseBilling);
    } catch (e) { /* 開けなくても邪魔はしない */ }
  }

  function closeBillingPanel() {
    if (!billingPanel) return;
    try { billingPanel.remove(); } catch (e) { /* noop */ }
    billingPanel = null;
    billingPath = null;
    document.removeEventListener('keydown', escCloseBilling);
    syncPostingSelection();
  }

  function escCloseBilling(e) {
    if (e.key === 'Escape') closeBillingPanel();
  }

  function closestMarked(node, mark) {
    var cur = node;
    while (cur) {
      try {
        if (cur.getAttribute && (
          cur.getAttribute('data-' + mark) ||
          cur.getAttribute('data-' + mark + '-wrap') === '1'
        )) return cur;
      } catch (e) { /* next */ }
      cur = cur.parentElement;
    }
    return null;
  }

  function onDocumentClickCapture(e) {
    onComposeSlashClick(e);
    onNavClickCapture(e);
  }

  function onNavClickCapture(e) {
    try {
      var t = e.target || e.srcElement;
      var navLink = closestAttr(t, 'data-toybaco-nav-link');
      var navKind = navLink && navLink.getAttribute('data-toybaco-nav-link');
      if (navKind === 'inbox' || navKind === 'reports' || navKind === 'settings') {
        if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
        if (e.preventDefault) e.preventDefault();
        if (e.stopPropagation) e.stopPropagation();
        if (e.stopImmediatePropagation) e.stopImmediatePropagation();
        navigatePrimaryNav(navKind);
        return;
      }
      if (closestMarked(t, MARK)) {
        if (e.preventDefault) e.preventDefault();
        if (e.stopPropagation) e.stopPropagation();
        if (e.stopImmediatePropagation) e.stopImmediatePropagation();
        openPanel(DEFAULT_PATH, false);
        return;
      }
      if (closestMarked(t, BILLING_MARK)) {
        if (e.preventDefault) e.preventDefault();
        if (e.stopPropagation) e.stopPropagation();
        if (e.stopImmediatePropagation) e.stopImmediatePropagation();
        closeAiModePanel();
        openBillingPanel();
        return;
      }
      if (closestMarked(t, AI_MARK)) {
        if (e.preventDefault) e.preventDefault();
        if (e.stopPropagation) e.stopPropagation();
        if (e.stopImmediatePropagation) e.stopImmediatePropagation();
        openAiModePanel();
        return;
      }
      var modeBtn = closestAttr(t, 'data-toybaco-ai-mode');
      if (modeBtn) {
        if (e.preventDefault) e.preventDefault();
        if (e.stopPropagation) e.stopPropagation();
        if (e.stopImmediatePropagation) e.stopImmediatePropagation();
        saveAiMode(modeBtn.getAttribute('data-toybaco-ai-mode'));
      }
    } catch (err) { /* 受信箱は壊さない */ }
  }

  function ensurePostingContract() {
    try {
      var entry = document.querySelector('[data-' + MARK + ']');
      if (!entry) return;
      var want = postingHash(DEFAULT_PATH);
      if ((entry.getAttribute && entry.getAttribute('href')) !== want) {
        if (entry.setAttribute) entry.setAttribute('href', want);
        entry.href = want;
      }
      if (entry.getAttribute && entry.getAttribute('data-' + BILLING_MARK)) {
        if (entry.removeAttribute) entry.removeAttribute('data-' + BILLING_MARK);
      }
    } catch (e) { /* href を直せなくても click キャプチャでカレンダーへ */ }
  }

  function cannedCodeFromLabel(text) {
    if (typeof text !== 'string') return '';
    var t = text.replace(/\s+/g, ' ').trim();
    var m = t.match(/^\/?([a-z0-9-]+)$/);
    return m && CANNED_NAMES[m[1]] ? m[1] : '';
  }

  function annotateCannedLabels() {
    try {
      var nodes = document.querySelectorAll('b, strong, td, th, span, a, button, [role="option"], [role="menuitem"]');
      var i;
      for (i = 0; i < nodes.length; i += 1) {
        var el = nodes[i];
        if (el.querySelector && el.querySelector('[data-toybaco-canned-name]')) continue;
        if (el.getAttribute && el.getAttribute('data-toybaco-canned-name')) continue;
        var kids = el.childNodes || [];
        if (kids.length !== 1 || kids[0].nodeType !== 3) continue;
        var code = cannedCodeFromLabel(el.textContent || '');
        if (!code) continue;
        var tag = document.createElement('span');
        tag.setAttribute('data-toybaco-canned-name', '1');
        tag.textContent = CANNED_NAMES[code];
        el.appendChild(tag);
      }
    } catch (e) { /* 併記できなくても受信箱の邪魔はしない */ }
  }

  function isCaptainWord(text) {
    return (
      text === 'Captain' ||
      text === 'CAPTAIN' ||
      text === 'Copilot' ||
      text === 'COPILOT' ||
      text === 'コパイロット' ||
      text === '副操縦士'
    );
  }

  function hideCaptainWord() {
    try {
      var nodes = document.querySelectorAll('h1, h2, h3, span, a, button, [title], [aria-label]');
      var i;
      for (i = 0; i < nodes.length; i += 1) {
        var el = nodes[i];
        var title = el.getAttribute && el.getAttribute('title');
        if (isCaptainWord(title)) el.setAttribute('title', 'AI');
        var aria = el.getAttribute && el.getAttribute('aria-label');
        if (isCaptainWord(aria)) el.setAttribute('aria-label', 'AI');
        var kids = el.childNodes || [];
        if (kids.length !== 1 || kids[0].nodeType !== 3) continue;
        var text = (el.textContent || '').trim();
        if (isCaptainWord(text)) el.textContent = 'AI';
      }
    } catch (e) { /* 字面を直せなくても受信箱の邪魔はしない */ }
  }

  var SLASH_MARK = 'toybaco-slash-canned';
  var AUTH_COOKIE_NAME = 'cw_d_session_info';
  var cannedPrefetch = { accountId: '', items: null, error: false, inflight: null };
  var slashState = { open: false, query: '', index: 0, editor: null };

  function classNameOf(el) {
    var cls = el && el.className;
    if (!cls) return '';
    if (typeof cls === 'string') return cls;
    if (typeof cls.baseVal === 'string') return cls.baseVal;
    return String(cls);
  }

  function hasClass(el, name) {
    return (' ' + classNameOf(el) + ' ').indexOf(' ' + name + ' ') !== -1;
  }

  function closestClass(el, name) {
    var node = el && el.nodeType === 3 ? el.parentElement : el;
    while (node && node !== document.documentElement && node !== document) {
      if (hasClass(node, name)) return node;
      node = node.parentElement;
    }
    return null;
  }

  function closestAttr(el, name) {
    var node = el && el.nodeType === 3 ? el.parentElement : el;
    while (node && node !== document.documentElement && node !== document) {
      try {
        if (node.getAttribute && node.getAttribute(name) !== null) return node;
      } catch (e) { /* next */ }
      node = node.parentElement;
    }
    return null;
  }

  function isComposeTarget(el) {
    if (!el) return false;
    var node = el.nodeType === 3 ? el.parentElement : el;
    var editable = null;
    while (node && node !== document.documentElement && node !== document) {
      var ce = node.getAttribute && node.getAttribute('contenteditable');
      if (ce === 'true' || ce === '' || hasClass(node, 'ProseMirror')) {
        editable = node;
        break;
      }
      node = node.parentElement;
    }
    if (!editable) return false;
    var box = closestClass(editable, 'reply-box');
    if (!box || hasClass(box, 'is-private')) return false;
    return true;
  }

  function cannedQueryFromText(text) {
    if (typeof text !== 'string') return null;
    var m = text.replace(/\u00a0/g, ' ').match(/(?:^|[\s])\/([^\s/]*)$/);
    return m ? m[1] : null;
  }

  function filterCannedItems(items, query) {
    var list = Array.isArray(items) ? items : [];
    var q = String(query || '').toLowerCase();
    if (!q) return list.slice();
    var out = [];
    var i;
    for (i = 0; i < list.length; i += 1) {
      var item = list[i];
      if (!item) continue;
      var code = String(item.short_code || '').toLowerCase();
      var name = String(item.name || '').toLowerCase();
      var content = String(item.content || '').toLowerCase();
      if (code.indexOf(q) !== -1 || name.indexOf(q) !== -1 || content.indexOf(q) !== -1) {
        out.push(item);
      }
    }
    return out;
  }

  function cannedResponsesUrl(accountId) {
    if (!accountId || !/^\d+$/.test(String(accountId))) return '';
    return '/api/v1/accounts/' + accountId + '/canned_responses';
  }

  function readSessionHeaders() {
    try {
      var parts = String(document.cookie || '').split(';');
      var i;
      for (i = 0; i < parts.length; i += 1) {
        var part = parts[i].replace(/^\s+/, '');
        if (part.indexOf(AUTH_COOKIE_NAME) !== 0 || part.charAt(AUTH_COOKIE_NAME.length) !== '=') continue;
        var info = JSON.parse(decodeURIComponent(part.slice(AUTH_COOKIE_NAME.length + 1)));
        if (!info || typeof info !== 'object') return null;
        var token = info['access-token'];
        var client = info.client;
        var uid = info.uid;
        if (!token || !client || !uid) return null;
        return {
          token: String(token),
          client: String(client),
          uid: String(uid)
        };
      }
      return null;
    } catch (e) { return null; }
  }

  function cannedFetchHeaders() {
    var headers = { Accept: 'application/json' };
    var auth = readSessionHeaders();
    if (!auth) return headers;
    headers['access-token'] = auth.token;
    headers.client = auth.client;
    headers.uid = auth.uid;
    headers['token-type'] = 'Bearer';
    return headers;
  }

  function normalizeCannedRecords(payload) {
    var list = [];
    if (Array.isArray(payload)) list = payload;
    else if (payload && Array.isArray(payload.payload)) list = payload.payload;
    var out = [];
    var i;
    for (i = 0; i < list.length; i += 1) {
      var row = list[i];
      if (!row || typeof row !== 'object') continue;
      var code = String(row.short_code || row.shortCode || '').trim();
      var content = String(row.content || '');
      if (!/^[a-z0-9-]+$/.test(code) || !content) continue;
      out.push({
        short_code: code,
        content: content,
        name: CANNED_NAMES[code] || ''
      });
    }
    return out;
  }

  function previewCanned(content) {
    var text = String(content || '').replace(/\s+/g, ' ').trim();
    if (text.length > 42) text = text.slice(0, 41) + '…';
    return text;
  }

  function visibleCannedItems() {
    return filterCannedItems(cannedPrefetch.items || [], slashState.query);
  }

  function closeCannedSlash() {
    slashState.open = false;
    slashState.query = '';
    slashState.index = 0;
    slashState.editor = null;
    try {
      var existing = document.querySelector('[data-' + SLASH_MARK + ']');
      if (existing && existing.parentElement) existing.parentElement.removeChild(existing);
    } catch (e) { /* 閉じられなくても次の描画で上書きする */ }
  }

  function renderCannedSlash() {
    try {
      if (!slashState.open) return;
      var host = document.body;
      if (!host || !host.appendChild) return;
      var panel = document.querySelector('[data-' + SLASH_MARK + ']');
      if (!panel) {
        panel = document.createElement('div');
        panel.setAttribute('data-' + SLASH_MARK, '1');
        panel.setAttribute('role', 'listbox');
        panel.setAttribute('aria-label', '定型文');
        host.appendChild(panel);
      }
      while (panel.firstChild) panel.removeChild(panel.firstChild);
      var heading = document.createElement('div');
      heading.setAttribute('data-toybaco-slash-h', '1');
      heading.textContent = '定型文';
      panel.appendChild(heading);
      if (!cannedPrefetch.items && !cannedPrefetch.error) {
        var loading = document.createElement('div');
        loading.setAttribute('data-toybaco-slash-empty', '1');
        loading.textContent = '定型文を読み込み中…';
        panel.appendChild(loading);
      } else if (cannedPrefetch.error && !(cannedPrefetch.items && cannedPrefetch.items.length)) {
        var failed = document.createElement('div');
        failed.setAttribute('data-toybaco-slash-empty', '1');
        failed.textContent = '定型文を読み込めませんでした';
        panel.appendChild(failed);
      } else {
        var items = visibleCannedItems();
        if (!items.length) {
          var empty = document.createElement('div');
          empty.setAttribute('data-toybaco-slash-empty', '1');
          empty.textContent = cannedPrefetch.items && cannedPrefetch.items.length
            ? '一致する定型文はありません'
            : '定型文がまだありません';
          panel.appendChild(empty);
        } else {
          if (slashState.index < 0 || slashState.index >= items.length) slashState.index = 0;
          var i;
          for (i = 0; i < items.length; i += 1) {
            var item = items[i];
            var row = document.createElement('div');
            row.setAttribute('role', 'option');
            row.setAttribute('data-toybaco-slash-item', item.short_code);
            if (i === slashState.index) row.setAttribute('data-toybaco-slash-hl', '1');
            var code = document.createElement('b');
            code.textContent = '/' + item.short_code;
            row.appendChild(code);
            if (item.name) {
              var name = document.createElement('span');
              name.setAttribute('data-toybaco-canned-name', '1');
              name.textContent = item.name;
              row.appendChild(name);
            }
            var preview = document.createElement('small');
            preview.textContent = previewCanned(item.content);
            row.appendChild(preview);
            panel.appendChild(row);
          }
        }
      }
      var editor = slashState.editor;
      var rect = editor && editor.getBoundingClientRect ? editor.getBoundingClientRect() : null;
      var top = rect && typeof rect.top === 'number' ? Math.max(8, rect.top - 8) : 120;
      var left = rect && typeof rect.left === 'number' ? Math.max(8, rect.left) : 16;
      if (panel.style) {
        panel.style.cssText = 'position:fixed;left:' + left + 'px;bottom:auto;top:' +
          Math.max(8, top - 220) + 'px;z-index:40;';
      }
    } catch (e) { /* 一覧が出せなくても返信欄は壊さない */ }
  }

  function openCannedSlash(editor, query) {
    slashState.open = true;
    slashState.editor = editor || slashState.editor;
    slashState.query = typeof query === 'string' ? query : '';
    slashState.index = 0;
    renderCannedSlash();
  }

  function prefetchCannedResponses(accountId) {
    var url = cannedResponsesUrl(accountId);
    if (!url) return;
    var fetchFn = window && window.fetch;
    if (typeof fetchFn !== 'function') return;
    if (cannedPrefetch.accountId === accountId && (cannedPrefetch.items || cannedPrefetch.inflight)) {
      return;
    }
    cannedPrefetch = { accountId: String(accountId), items: null, error: false, inflight: null };
    cannedPrefetch.inflight = fetchFn(url, {
      credentials: 'same-origin',
      headers: cannedFetchHeaders()
    }).then(function (res) {
      if (!res || !res.ok) throw new Error('canned');
      return res.json();
    }).then(function (data) {
      if (cannedPrefetch.accountId !== String(accountId)) return;
      cannedPrefetch.items = normalizeCannedRecords(data);
      cannedPrefetch.inflight = null;
      if (slashState.open) renderCannedSlash();
    }).catch(function () {
      if (cannedPrefetch.accountId !== String(accountId)) return;
      cannedPrefetch.error = true;
      cannedPrefetch.inflight = null;
      if (slashState.open) renderCannedSlash();
    });
  }

  function insertCannedIntoComposer(editor, content) {
    if (!editor || typeof content !== 'string' || !content) return false;
    try {
      if (editor.focus) editor.focus();
      var sel = window.getSelection && window.getSelection();
      var node = sel && sel.anchorNode;
      var offset = sel && typeof sel.anchorOffset === 'number' ? sel.anchorOffset : 0;
      if (sel && node && node.nodeType === 3) {
        var value = String(node.textContent || '');
        var slice = value.slice(0, offset);
        var at = slice.lastIndexOf('/');
        if (at >= 0 && document.createRange) {
          var range = document.createRange();
          range.setStart(node, at);
          range.setEnd(node, offset);
          sel.removeAllRanges();
          sel.addRange(range);
        }
      }
      if (typeof document.execCommand === 'function' && document.execCommand('insertText', false, content)) {
        return true;
      }
      var text = String(editor.textContent || '');
      if (/(^|[\s\u00a0])\/[^\s/]*$/.test(text)) {
        editor.textContent = text.replace(/(^|[\s\u00a0])\/[^\s/]*$/, '$1' + content);
      } else {
        editor.textContent = content;
      }
      return true;
    } catch (e) { return false; }
  }

  function pickCannedItem(code) {
    var items = visibleCannedItems();
    var chosen = null;
    var i;
    if (code) {
      for (i = 0; i < items.length; i += 1) {
        if (items[i].short_code === code) { chosen = items[i]; break; }
      }
    } else {
      chosen = items[slashState.index] || items[0] || null;
    }
    if (!chosen) return false;
    var ok = insertCannedIntoComposer(slashState.editor, chosen.content);
    closeCannedSlash();
    return ok;
  }

  function onComposeSlashKeydown(e) {
    try {
      if (!e) return;
      if (slashState.open) {
        if (e.key === 'Escape') {
          closeCannedSlash();
          if (e.preventDefault) e.preventDefault();
          if (e.stopPropagation) e.stopPropagation();
          return;
        }
        if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
          var items = visibleCannedItems();
          if (items.length) {
            slashState.index = e.key === 'ArrowDown'
              ? (slashState.index + 1) % items.length
              : (slashState.index - 1 + items.length) % items.length;
            renderCannedSlash();
          }
          if (e.preventDefault) e.preventDefault();
          if (e.stopPropagation) e.stopPropagation();
          return;
        }
        if (e.key === 'Enter' && !e.shiftKey) {
          pickCannedItem();
          if (e.preventDefault) e.preventDefault();
          if (e.stopPropagation) e.stopPropagation();
          if (e.stopImmediatePropagation) e.stopImmediatePropagation();
          return;
        }
      }
      if (e.key === '/' && isComposeTarget(e.target || e.srcElement)) {
        prefetchCannedResponses(currentAccountId());
        openCannedSlash(e.target || e.srcElement, '');
      }
    } catch (err) { /* 定型文が出せなくても返信欄は壊さない */ }
  }

  function onComposeSlashInput(e) {
    try {
      var target = e && (e.target || e.srcElement);
      if (!isComposeTarget(target)) {
        if (slashState.open) closeCannedSlash();
        return;
      }
      var query = cannedQueryFromText(target.textContent || '');
      if (query === null) {
        if (slashState.open) closeCannedSlash();
        return;
      }
      prefetchCannedResponses(currentAccountId());
      openCannedSlash(target, query);
    } catch (err) { /* 入力追従に失敗しても返信は続ける */ }
  }

  function onComposeSlashClick(e) {
    try {
      if (!slashState.open) return;
      var t = e.target || e.srcElement;
      var option = closestAttr(t, 'data-toybaco-slash-item');
      if (option) {
        pickCannedItem(option.getAttribute('data-toybaco-slash-item'));
        if (e.preventDefault) e.preventDefault();
        if (e.stopPropagation) e.stopPropagation();
        return;
      }
      if (closestAttr(t, 'data-' + SLASH_MARK) || isComposeTarget(t)) return;
      closeCannedSlash();
    } catch (err) { /* 閉じられなくても次の / で描き直す */ }
  }

  function inject() {
    try {
      installLogoutBridge();
      if (!isLoggedInView()) return;
      hideStockNav();
      annotateCannedLabels();
      hideCaptainWord();
      prefetchCannedResponses(currentAccountId());
      prefetchAiMode(currentAccountId());
      ensureComposerAiBar();
      var sample = findMenu();
      if (!sample) return;
      ensurePrimaryNavigation(sample);
      injectBilling(sample);
      syncPostingSelection();

      var id = currentAccountId();
      if (!id) return;
      var existing = document.querySelector('[data-' + MARK + ']');
      if (existing && existing.getAttribute('data-account') === id) {
        var existingWrap = existing.parentElement;
        if (existingWrap && existingWrap.getAttribute('data-' + MARK + '-wrap') === '1') {
          // Vueがナビ項目を差し替えても、主機能の位置を受信トレイ直後へ戻す。
          placeEntry(sample, existingWrap);
          ensurePostingContract();
          syncPostingSelection();
          return;
        }
      }
      // 入口はログイン後の会社画面に先に出す(#28)。契約の裏取りは
      // posting_status で行うが、通信完了は待たない。最終ゲートは
      // OIDC authorize。200 かつ enabled:false のときだけ後から外す。
      if (postingDeniedFor(id)) {
        removePostEntry();
        return;
      }
      removePostEntry();
      var now = findMenu();
      if (!now) return;
      if (document.querySelector('[data-' + MARK + ']')) return;
      // 投稿は受信箱と並ぶ主機能。設定・請求項目の下へ埋もれないよう、
      // 最初のtop-level行（私の受信トレイ）の直後へ置く。
      placeEntry(now, buildEntry(now, id));
      reconcilePostingAccess(id);
      hideStockNav();
      ensurePostingContract();
      syncPostingSelection();
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

  function afterNavChange() {
    if (billingPanel && window.location.pathname !== billingPath) closeBillingPanel();
    inject();
    ensurePostingContract();
    if (!panel && (currentHashPath() !== null || hasPendingPath())) {
      onHashMaybeChanged();
    }
  }

  function hookHistory() {
    try {
      var hist = window.history;
      if (!hist) return;
      ['pushState', 'replaceState'].forEach(function (type) {
        var orig = hist[type];
        if (typeof orig !== 'function' || orig.__toybacoNavHooked) return;
        var wrapped = function () {
          var ret = orig.apply(this, arguments);
          setTimeout(afterNavChange, 0);
          return ret;
        };
        wrapped.__toybacoNavHooked = true;
        hist[type] = wrapped;
      });
    } catch (e) { /* history を包めなくても observer と再試行で拾う */ }
  }

  function start() {
    inject();
    ensurePostingContract();
    hookHistory();
    try {
      var pending = null;
      var observer = new MutationObserver(function () {
        // 入口が無い会社画面では debounce せずすぐ挿す。
        // Vue の一回きりの差し替えを 250ms/rAF が取りこぼさないようにする。
        try {
          if (isLoggedInView() && !document.querySelector('[data-' + MARK + ']')) {
            afterNavChange();
            return;
          }
        } catch (e) { /* 判定できなければ通常の追従へ */ }
        if (pending) return;
        pending = (window.requestAnimationFrame || function (cb) {
          return setTimeout(cb, 16);
        })(function () {
          pending = null;
          afterNavChange();
        });
      });
      var root = document.documentElement || document.body;
      if (root) observer.observe(root, { childList: true, subtree: true });
    } catch (e) { /* 使えない環境では再試行だけ */ }

    var r = 0;
    for (r = 0; r < INJECT_RETRY_MS.length; r += 1) {
      setTimeout(afterNavChange, INJECT_RETRY_MS[r]);
    }

    window.addEventListener('popstate', function () {
      afterNavChange();
    });
    window.addEventListener('hashchange', onHashMaybeChanged);
    // 転送(統合ビュー)から着地した場合はここで開く
    onHashMaybeChanged();
  }

  try {
    document.addEventListener('keydown', onComposeSlashKeydown, true);
    document.addEventListener('input', onComposeSlashInput, true);
    document.addEventListener('click', onDocumentClickCapture, true);
  } catch (e) { /* start 後の再試行で入口は出す */ }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
