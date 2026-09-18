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
 *   - AI アシスタントを主ナビで案内し、返信欄の横で「全自動」「下書き」を選ぶ
 *     (主ナビは会話/投稿/AIアシスタント/レポート/設定。Captain は開かない)
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
  var postingStatusAccount = null;
  var postingStatusGeneration = 0;
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
  var panelPath = null;
  var panelRouteBase = null;
  var postRouteSequence = 0;
  var poller = null;     // 画面遷移を見張るタイマー(開いている間だけ)
  var loadTimer = null;
  var readyMessageHandler = null;
  var panelLayout = null;
  var postFrameReady = false;
  var postCloseRequest = null;
  var postCloseNotice = null;
  var postCloseSequence = 0;
  var postCloseApproved = false;
  var postRenewal = null;

  function clearPostRenewal() {
    var request = postRenewal;
    postRenewal = null;
    if (!request) return;
    if (request.timer) clearTimeout(request.timer);
    if (request.frame.parentNode) request.frame.parentNode.removeChild(request.frame);
  }

  function reconcilePostRenewal() {
    if (postRenewal && !postRenewal.isCurrent()) clearPostRenewal();
  }

  // Compare the existing parent session identity locally; no token is retained
  // or copied into a frame URL/message. The server independently binds the grant.
  function postingActor() {
    var auth = readSessionHeaders();
    return auth ? { uid: auth.uid, client: auth.client } : null;
  }

  function samePostingActor(actor) {
    var current = postingActor();
    return !!(actor && current && actor.uid === current.uid && actor.client === current.client);
  }

  window.addEventListener('pagehide', clearPostRenewal);

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
    return /\/app\/accounts\//.test(window.location.pathname) &&
      !/\/app\/accounts\/\d+\/suspended\/?$/.test(window.location.pathname);
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

  // Native Chatwoot resolves light/dark/system. Share its rendered state, never
  // the preference cookie, account identity, or permission data.
  function postingDisplayTheme() {
    function dark(node) {
      return !!(node && node.classList && node.classList.contains('dark'));
    }
    return dark(document.body) || dark(document.documentElement) ? 'dark' : 'light';
  }

  var postThemeSequence = 0;

  function revealPostFrame(frame) {
    if (!panel || panel.querySelector('iframe') !== frame || !postFrameReady ||
        frame.toybacoExpectedAccountId !== currentAccountId()) return;
    frame.style.visibility = 'visible';
    if (loadTimer) { clearTimeout(loadTimer); loadTimer = null; }
    if (panelSpinner && panelSpinner.parentNode) panelSpinner.parentNode.removeChild(panelSpinner);
  }

  function syncPostFrameTheme() {
    if (!panel || !postFrameReady) return;
    var frame = panel.querySelector('iframe');
    if (!frame || !frame.contentWindow || !frame.toybacoThemeSupported) return;
    var theme = postingDisplayTheme();
    var pending = frame.toybacoThemeRequest;
    if (!pending && frame.toybacoDisplayTheme === theme) { revealPostFrame(frame); return; }
    if (pending && pending.theme === theme) return;
    // Initial mount remains hidden until acknowledgement; later updates keep
    // the already usable frame visible even if a theme response is lost.
    var request = { requestId: ++postThemeSequence, theme: theme };
    frame.toybacoThemeRequest = request;
    frame.contentWindow.postMessage({ type: 'TOYBACO_POSTIZ_THEME', theme: theme, requestId: request.requestId }, POST_ORIGIN);
  }

  function watchPostingTheme() {
    try {
      var observer = new MutationObserver(function () { syncPostFrameTheme(); });
      [document.documentElement, document.body].forEach(function (node) {
        if (node) observer.observe(node, { attributes: true, attributeFilter: ['class'] });
      });
    } catch (e) { /* READY still sends the current theme without an observer */ }
  }

  function buildSrc(path, aiIntent) {
    var destination = new URL(validatePath(path), POST_ORIGIN);
    // OIDC 往復後も iframe 文脈を維持し、同名 query は固定値1個へ正規化する。
    destination.searchParams.set('tb_embed', '1');
    destination.searchParams.set('tb_theme', postingDisplayTheme());
    if (aiIntent === 'compose') destination.searchParams.set('tb_ai', 'compose');

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

  // 退避があるかを見るだけ(消さない)
  function hasPendingPath() {
    try { return !!sessionStorage.getItem(PENDING_KEY); } catch (e) { return false; }
  }

  // 実際に表示できるまでは退避先を保持する。
  function readPendingPath() {
    try {
      var v = sessionStorage.getItem(PENDING_KEY);
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

  function currentHistoryLocation() {
    return window.location.pathname + window.location.search + window.location.hash;
  }

  function isAssistantHash(hash) {
    return hash === '#/toybaco/assistant';
  }

  function postingHistoryState(location) {
    // createWebHistory also consumes entries added by this overlay on popstate.
    // Preserve its state (and other callers' data), including a real current URL
    // and position; a marker-only entry makes its next navigation use undefined.
    var state = Object.assign({}, history.state || {});
    state.current = location;
    if (typeof state.back !== 'string') state.back = null;
    if (typeof state.forward !== 'string') state.forward = null;
    if (typeof state.position !== 'number' || !isFinite(state.position)) {
      state.position = Math.max(0, (history.length || 1) - 1);
    }
    if (typeof state.replaced !== 'boolean') state.replaced = true;
    if (!Object.prototype.hasOwnProperty.call(state, 'scroll')) state.scroll = null;
    return state;
  }

  function writePostingHistory(hash, replace) {
    var request = { hash: hash, replace: replace, handled: false };
    window.dispatchEvent(new CustomEvent('toybaco:posting-history', { detail: request }));
    if (request.handled) return;
    // Before the router module loads, seed a complete entry for its startup.
    // After startup its synchronous bridge owns every write and cache update.
    var location = window.location.pathname + window.location.search + hash;
    var previous = currentHistoryLocation();
    var state = postingHistoryState(previous);
    if (!replace) {
      // Match createWebHistory's two-entry push contract, rather than copying
      // the previous current/back/forward/position into a new browser entry.
      state.forward = location;
      history.replaceState(state, '', previous);
      state = Object.assign({}, state, {
        back: previous, current: location, forward: null,
        position: state.position + 1, replaced: false, scroll: null
      });
    } else {
      state.current = location;
      state.replaced = true;
    }
    if (isPostingHash(hash)) state.toybacoPosting = true;
    else delete state.toybacoPosting;
    history[replace ? 'replaceState' : 'pushState'](state, '', location);
  }

  function setHash(path) {
    try {
      var h = postingHash(path);
      if (window.location.hash !== h) {
        writePostingHistory(h, false);
      }
    } catch (e) { /* hash が付かなくても動作は続ける */ }
  }

  function stripHash() {
    try {
      if (isPostingHash(window.location.hash || '')) {
        writePostingHistory('', true);
      }
    } catch (e) { /* noop */ }
  }

  function hasPostingRouteGuard() {
    var request = { handled: false };
    window.dispatchEvent(new CustomEvent('toybaco:posting-route-owner', { detail: request }));
    return request.handled;
  }

  function isVisibleNativeOverlay(node) {
    if (!node || !node.getClientRects || !node.getClientRects().length) return false;
    if (node.closest('[inert], [aria-hidden="true"]')) return false;
    var style = window.getComputedStyle(node);
    return style.display !== 'none' && style.visibility !== 'hidden' &&
      style.visibility !== 'collapse' && style.opacity !== '0';
  }

  function hasNativeEscapeOverlay() {
    var overlays = document.querySelectorAll('.n-dropdown-body, [data-dropdown-menu], [data-toybaco-sidebar-popover], [data-toybaco-mobile-sidebar-open="true"], ' +
      '[role="menu"], [role="listbox"], [role="dialog"], [aria-modal="true"], dialog[open], .modal-container');
    for (var i = 0; i < overlays.length; i++) {
      if (isVisibleNativeOverlay(overlays[i])) return true;
    }
    // ninja-keys renders its visible modal in an open shadow root. The host
    // itself stays mounted when closed and is not evidence of an open palette.
    var palettes = document.querySelectorAll('ninja-keys');
    for (var j = 0; j < palettes.length; j++) {
      var modal = palettes[j].shadowRoot && palettes[j].shadowRoot.querySelector('.modal.visible');
      if (modal && isVisibleNativeOverlay(modal)) return true;
    }
    return false;
  }

  function onKeydown(e) {
    if (e.key !== 'Escape' || e.isComposing || e.keyCode === 229 || e.defaultPrevented || !panel) return;
    if (hasNativeEscapeOverlay()) return;
    var escapePanel = panel;
    var escapeFrame = panel.querySelector('iframe');
    // Let native target/bubble handlers finish first. A microtask can run
    // between capture and bubble on real key input, so use the next task.
    setTimeout(function () {
      if (panel !== escapePanel || panel.querySelector('iframe') !== escapeFrame ||
          e.defaultPrevented || hasNativeEscapeOverlay()) return;
      if (!requestPanelClose(closePanel)) closePanel();
    }, 0);
  }

  function removeReadyMessageHandler() {
    clearPostRenewal();
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

  function isTrustedPostizClose(event, frameWindow) {
    return !!(
      event &&
      event.origin === POST_ORIGIN &&
      event.source === frameWindow &&
      event.data &&
      typeof event.data === 'object' &&
      event.data.type === 'TOYBACO_POSTIZ_CLOSE'
    );
  }

  // 同じiframeの既存composer確認が返るまで、native操作と本文を保持する。
  function requestPanelClose(proceed, cancel) {
    if (!panel || !postFrameReady || postCloseApproved) return false;
    if (postCloseRequest) return true;
    var frame = panel.querySelector('iframe');
    if (!frame || !frame.contentWindow) return false;
    clearPostCloseRequest();
    var request = { id: ++postCloseSequence, proceed: proceed, cancel: cancel, timer: null };
    postCloseRequest = request;
    // 応答のない旧画面や通信断では本文を残し、次の操作で再試行できるようにする。
    // 子が確認を表示した後は、人が決めるまで期限を設けない。
    request.timer = setTimeout(function () {
      if (postCloseRequest !== request || !panel) return;
      clearPostCloseRequest();
      if (request.cancel) request.cancel();
      postCloseNotice = document.createElement('div');
      postCloseNotice.setAttribute('role', 'status');
      postCloseNotice.textContent = '投稿画面の確認ができませんでした。入力は残しています。もう一度、移動先を選んでください。';
      postCloseNotice.style.cssText = 'flex-shrink:0;padding:10px 16px;background:#FFF4DF;color:#714F0F;font-size:14px';
      panel.appendChild(postCloseNotice);
    }, 5000);
    try {
      frame.contentWindow.postMessage({ type: 'TOYBACO_POSTIZ_REQUEST_CLOSE', requestId: request.id }, POST_ORIGIN);
    } catch (e) { /* 応答待ちの期限で再試行の案内を出す */ }
    return true;
  }

  function clearPostCloseRequest(cancelPending) {
    var request = postCloseRequest;
    if (postCloseRequest && postCloseRequest.timer) clearTimeout(postCloseRequest.timer);
    postCloseRequest = null;
    if (postCloseNotice) { postCloseNotice.remove(); postCloseNotice = null; }
    if (cancelPending && request && request.cancel) request.cancel();
  }

  function postingDeniedFor(accountId) {
    return postingStatusCache[accountId] === false;
  }

  function syncPostingStatusScope() {
    var id = currentAccountId();
    if (id === postingStatusAccount) return;
    postingStatusAccount = id;
    postingStatusGeneration += 1;
    postingStatusInflight = {};
    if (!id) postingStatusCache = {};
  }

  function resolvePostingAllowed(accountId, cb, refresh) {
    if (!accountId) { cb(true); return; }
    syncPostingStatusScope();
    if (refresh) {
      // 契約画面から戻る1回だけ再確認し、以前の応答には表示を上書きさせない。
      postingStatusGeneration += 1;
      delete postingStatusInflight[accountId];
    }
    var generation = postingStatusGeneration;
    function isCurrent() {
      return generation === postingStatusGeneration && currentAccountId() === accountId && isLoggedInView();
    }
    function deliver(allowed) { if (isCurrent()) cb(allowed); }
    var hasCached = Object.prototype.hasOwnProperty.call(postingStatusCache, accountId);
    if (hasCached && !refresh) {
      deliver(postingStatusCache[accountId]);
      return;
    }
    var fallback = refresh ? (hasCached && postingStatusCache[accountId]) : true;
    if (postingStatusInflight[accountId]) {
      postingStatusInflight[accountId].then(deliver, function () { deliver(fallback); });
      return;
    }
    var settled = false;
    var request;
    try {
      request = new Promise(function (resolve) {
        var timer = setTimeout(function () {
          if (settled) return;
          settled = true;
          resolve(fallback);
        }, POSTING_STATUS_TIMEOUT_MS);
        fetch('/toybaco/posting_status?account_id=' + encodeURIComponent(accountId), {
          credentials: 'same-origin'
        }).then(function (r) {
          if (refresh && r && (r.status === 401 || r.status === 403)) return false;
          if (!r || !r.ok) return fallback;
          return Promise.resolve(r.json()).then(function (d) {
            if (refresh) return d && typeof d.enabled === 'boolean' ? d.enabled : fallback;
            return !(d && d.enabled === false);
          }).catch(function () { return fallback; });
        }).catch(function () { return fallback; }).then(function (allowed) {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          resolve(allowed);
        }, function () {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          resolve(fallback);
        });
      }).then(function (allowed) {
        if (!isCurrent()) return allowed;
        if (refresh || !Object.prototype.hasOwnProperty.call(postingStatusCache, accountId)) {
          postingStatusCache[accountId] = allowed;
        }
        delete postingStatusInflight[accountId];
        return postingStatusCache[accountId];
      });
    } catch (e) {
      deliver(fallback);
      return;
    }
    postingStatusInflight[accountId] = request;
    request.then(deliver, function () { deliver(fallback); });
  }

  function showContractMissing() {
    if (!panel) return;
    clearPostCloseRequest(true);
    if (loadTimer) { clearTimeout(loadTimer); loadTimer = null; }
    removeReadyMessageHandler();
    try {
      var frame = panel.querySelector('iframe');
      if (frame && frame.parentNode) frame.parentNode.removeChild(frame);
      var nav = panel.querySelector('[data-toybaco-post-subnav]');
      if (nav) nav.remove();
    } catch (e) { /* noop */ }
    if (panelSpinner) {
      panelSpinner.innerHTML = '<span>この店舗では投稿機能をご利用いただけません。利用をご希望の場合は契約者にご確認ください。</span>';
      if (!panelSpinner.parentNode) panel.appendChild(panelSpinner);
    }
  }

  function applyPostingDenied() {
    removePostEntry();
    showContractMissing();
  }

  function reconcilePostingAccess(accountId, refresh) {
    resolvePostingAllowed(accountId, function (allowed) {
      try {
        if (currentAccountId() !== accountId) return;
        if (allowed) {
          if (refresh) inject();
          return;
        }
        applyPostingDenied();
      } catch (e) { /* 入口を外せなくても受信箱の邪魔はしない */ }
    }, refresh);
  }

  function mountPostFrame(path, spinner, aiIntent) {
    // The visible parent route is the intent for this frame, not a shared cookie.
    var expectedAccountId = currentAccountId();
    var pendingAiIntent = aiIntent === 'compose' ? 'compose' : null;
    var context = null;
    var seenDocuments = Object.create(null);
    var contextRejected = false;
    var renewalOwner = null;
    var renewalActor = null;
    var lastRenewalSequence = 0;
    var loadingMarkup = spinner.innerHTML;
    var frame = document.createElement('iframe');
    frame.toybacoExpectedAccountId = expectedAccountId;
    frame.src = buildSrc(path || DEFAULT_PATH, aiIntent);
    var requestedRoute = new URL(new URL(frame.src).searchParams.get('return'), POST_ORIGIN);
    var initialRoute = {
      pathname: requestedRoute.pathname,
      aiIntent: requestedRoute.searchParams.get('tb_ai') === 'compose' ? 'compose' : null
    };
    // Only the first business document belongs to this launch intent. Later
    // in-frame navigation still rebinds identity, without rewinding its route.
    var firstBusinessReady = false;
    frame.title = '投稿';
    frame.style.cssText = 'border:0;width:100%;height:100%;min-height:0;flex:1';
    // 認証途中の別レイアウトを見せず、投稿shellのREADY後にだけ描画する。
    // visibilityならサイズを保ち、子の初期化・READY検出を止めない。
    frame.style.visibility = 'hidden';
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

    function showFrameError(message, canRetry) {
      if (!panel || panel.querySelector('iframe') !== frame || !spinner.parentNode) return;
      if (loadTimer) { clearTimeout(loadTimer); loadTimer = null; }
      spinner.innerHTML = '';
      var text = document.createElement('span');
      text.textContent = message;
      spinner.appendChild(text);
      function addRecoveryButton(label, action) {
        var button = document.createElement('button');
        button.type = 'button';
        button.textContent = label;
        button.style.cssText = 'min-height:44px;padding:8px 20px;border:1px solid #B5A99B;border-radius:8px;background:#FFFDF9;color:#1F3A5F;cursor:pointer';
        button.addEventListener('click', function () {
          if (!panel || panel.querySelector('iframe') !== frame || currentAccountId() !== expectedAccountId) return;
          action();
        });
        spinner.appendChild(button);
      }
      if (canRetry !== false) addRecoveryButton('再試行', function () {
        var nextPath = currentHashPath() || DEFAULT_PATH;
        closePanel();
        openPanel(nextPath, false, pendingAiIntent);
      });
      // Re-fetch the current trusted parent route, including its posting hash.
      // A same-URL anchor can be fragment-only and keep an old parent script.
      addRecoveryButton('トイバコを開き直す', function () { window.location.reload(); });
    }

    function armFrameTimeout() {
      if (loadTimer) clearTimeout(loadTimer);
      loadTimer = setTimeout(function () {
        showFrameError('投稿画面を開けませんでした。店舗を確認してから再試行してください。');
      }, LOAD_TIMEOUT_MS);
    }

    function validContextId(value) {
      return typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
    }

    function newContextId() {
      var crypto = window.crypto;
      if (!crypto) return null;
      try {
        if (typeof crypto.randomUUID === 'function') {
          var id = crypto.randomUUID();
          if (validContextId(id)) return id;
        }
      } catch (e) { /* try the secure byte API below */ }
      try {
        var bytes = new Uint8Array(16);
        crypto.getRandomValues(bytes);
        bytes[6] = (bytes[6] & 15) | 64;
        bytes[8] = (bytes[8] & 63) | 128;
        var hex = '';
        for (var i = 0; i < bytes.length; i += 1) hex += ('0' + bytes[i].toString(16)).slice(-2);
        return hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' + hex.slice(16, 20) + '-' + hex.slice(20);
      } catch (e) { return null; }
    }

    function matchesContext(data) {
      return !!(context && data && data.documentId === context.documentId &&
        data.frameId === context.frameId && data.accountId === expectedAccountId &&
        currentAccountId() === expectedAccountId);
    }

    function validRenewalOwner(owner, organizationId) {
      var uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
      return !!(owner && typeof owner === 'object' && typeof owner.id === 'string' && uuid.test(owner.id) &&
        typeof owner.orgId === 'string' && uuid.test(owner.orgId) && owner.orgId === organizationId &&
        (owner.role === 'ADMIN' || owner.role === 'USER') && owner.providerName === 'GENERIC');
    }

    function matchesRenewalOwner(owner) {
      return !!(renewalOwner && validRenewalOwner(owner, renewalOwner.orgId) &&
        owner.id === renewalOwner.id && owner.role === renewalOwner.role);
    }

    function sendRenewalResult(data, ok) {
      frame.contentWindow.postMessage({ type: 'TOYBACO_POSTIZ_RENEW_RESULT',
        documentId: data.documentId, frameId: data.frameId, accountId: data.accountId,
        requestId: data.requestId, requestSequence: data.requestSequence, ok: ok }, POST_ORIGIN);
    }

    function beginRenewal(data) {
      if (!postFrameReady || contextRejected || !matchesContext(data) || !validContextId(data.requestId) ||
          !matchesRenewalOwner(data.owner) || !samePostingActor(renewalActor) || !isLoggedInView() ||
          !isPostingHash(window.location.hash || '')) return;
      if (!Number.isSafeInteger(data.requestSequence) || data.requestSequence <= lastRenewalSequence) return;
      // One monotonic counter prevents replay without limiting an all-day editor.
      lastRenewalSequence = data.requestSequence;
      reconcilePostRenewal();
      if (postRenewal) { sendRenewalResult(data, false); return; }
      var hidden = document.createElement('iframe');
      hidden.setAttribute('data-toybaco-post-renewal', '1');
      hidden.setAttribute('aria-hidden', 'true');
      hidden.tabIndex = -1;
      hidden.hidden = true;
      hidden.style.display = 'none';
      hidden.title = '投稿の接続更新';
      var entry = new URL('/toybaco/entry', POST_ORIGIN);
      entry.searchParams.set('purpose', 'renew');
      entry.searchParams.set('return', '/launches?tb_embed=1');
      entry.searchParams.set('tb_embed', '1');
      entry.searchParams.set('request_id', data.requestId);
      entry.searchParams.set('document_id', data.documentId);
      entry.searchParams.set('frame_id', data.frameId);
      entry.searchParams.set('account_id', data.accountId);
      entry.searchParams.set('user_id', renewalOwner.id);
      entry.searchParams.set('organization_id', renewalOwner.orgId);
      entry.searchParams.set('role', renewalOwner.role);
      var ownedPanel = panel, ownedContext = context;
      var ownedLocation = auxiliaryLocation();
      var request = {
        frame: hidden, source: frame.contentWindow, requestId: data.requestId, requestSequence: data.requestSequence,
        documentId: data.documentId, frameId: data.frameId, accountId: data.accountId,
        timer: null,
        isCurrent: function () {
          return panel === ownedPanel && !!panel && panel.parentNode && panel.querySelector('iframe') === frame &&
            frame.contentWindow === request.source && context === ownedContext && postFrameReady &&
            !contextRejected && currentAccountId() === expectedAccountId && isLoggedInView() &&
            auxiliaryLocation() === ownedLocation && samePostingActor(renewalActor);
        },
        finish: function (ok) {
          if (postRenewal !== request) return;
          var current = request.isCurrent();
          clearPostRenewal();
          if (current) sendRenewalResult(request, ok);
        }
      };
      postRenewal = request;
      request.timer = setTimeout(function () { request.finish(false); }, 20000);
      hidden.addEventListener('error', function () { request.finish(false); });
      hidden.src = entry.href;
      // A sibling outside the panel never replaces its business iframe or focus.
      try { document.body.appendChild(hidden); } catch (e) { request.finish(false); }
    }

    removeReadyMessageHandler();
    readyMessageHandler = function (event) {
      reconcilePostRenewal();
      if (!panel || panel.querySelector('iframe') !== frame || currentAccountId() !== expectedAccountId) return;
      if (event.origin === POST_ORIGIN && event.data && typeof event.data === 'object' &&
          event.data.type === 'TOYBACO_POSTIZ_RENEW_COMPLETE') {
        var renewal = postRenewal;
        if (!renewal || event.source !== renewal.frame.contentWindow ||
            event.data.requestId !== renewal.requestId || event.data.documentId !== renewal.documentId ||
            event.data.frameId !== renewal.frameId || event.data.accountId !== renewal.accountId ||
            typeof event.data.ok !== 'boolean') return;
        renewal.finish(event.data.ok);
        return;
      }
      if (event.origin === POST_ORIGIN && event.source === frame.contentWindow && event.data &&
          (event.data.type === 'TOYBACO_POSTIZ_RENEW_REQUEST' || event.data.type === 'TOYBACO_POSTIZ_RENEW_CANCEL')) {
        if (event.data.type === 'TOYBACO_POSTIZ_RENEW_REQUEST') beginRenewal(event.data);
        else if (postRenewal && matchesContext(event.data) && event.data.requestId === postRenewal.requestId &&
            event.data.requestSequence === postRenewal.requestSequence) clearPostRenewal();
        return;
      }
      if (event.origin === POST_ORIGIN && event.source === frame.contentWindow &&
          event.data && typeof event.data === 'object' && event.data.type === 'TOYBACO_POSTIZ_CONTEXT_REQUEST') {
        if (!validContextId(event.data.documentId) ||
            !/^[1-9][0-9]{0,18}$/.test(expectedAccountId || '') || currentAccountId() !== expectedAccountId) return;
        if (!context || context.documentId !== event.data.documentId) {
          // WindowProxy survives document navigation. A queued request from an
          // already-seen document must not roll back the current binding.
          if (seenDocuments[event.data.documentId]) return;
          var frameId = newContextId();
          if (!validContextId(frameId)) {
            showFrameError('安全な接続確認に対応していません。ブラウザーを更新してからトイバコを開き直してください。', false);
            return;
          }
          clearPostRenewal();
          renewalOwner = null;
          renewalActor = null;
          lastRenewalSequence = 0;
          seenDocuments[event.data.documentId] = true;
          context = { documentId: event.data.documentId, frameId: frameId, accountId: expectedAccountId };
          contextRejected = false;
          postFrameReady = false;
          frame.toybacoThemeRequest = null;
          frame.toybacoThemeSupported = false;
          frame.style.visibility = 'hidden';
          // A new document in the same iframe must pass the gate again.
          if (!spinner.parentNode) panel.insertBefore(spinner, frame);
          spinner.innerHTML = loadingMarkup;
          armFrameTimeout();
        }
        frame.contentWindow.postMessage({ type: 'TOYBACO_POSTIZ_INIT',
          documentId: context.documentId, frameId: context.frameId, accountId: context.accountId,
          initialRoute: firstBusinessReady ? null : initialRoute }, POST_ORIGIN);
        return;
      }
      if (event.origin === POST_ORIGIN && event.source === frame.contentWindow &&
          event.data && event.data.type === 'TOYBACO_POSTIZ_CONTEXT_DENIED') {
        if (!matchesContext(event.data) ||
            ['account-mismatch', 'context-unavailable', 'session-changed', 'path-mismatch'].indexOf(event.data.reason) < 0) return;
        // A mounted editor owns later reconnect UI; never discard its local draft.
        if (!postFrameReady) {
          contextRejected = true;
          showFrameError(event.data.reason === 'path-mismatch'
            ? '選択した投稿画面を開けませんでした。再試行してください。'
            : '別の店舗で接続されているか、接続を確認できません。元の店舗を選び直してから再試行してください。');
        }
        return;
      }
      if (event.origin === POST_ORIGIN && event.source === frame.contentWindow &&
          event.data && event.data.type === 'TOYBACO_POSTIZ_THEME_APPLIED') {
        var pendingTheme = frame.toybacoThemeRequest;
        if (!pendingTheme || event.data.requestId !== pendingTheme.requestId ||
            event.data.theme !== pendingTheme.theme) return;
        frame.toybacoDisplayTheme = event.data.theme;
        frame.toybacoThemeRequest = null;
        // A native theme change may precede its MutationObserver callback.
        // Recheck it before revealing, including dark -> light -> dark races.
        syncPostFrameTheme();
        return;
      }
      if (isTrustedPostizDenied(event, frame.contentWindow)) {
        applyPostingDenied();
        return;
      }
      if (isTrustedPostizClose(event, frame.contentWindow)) {
        closePanel();
        return;
      }
      if (event.origin === POST_ORIGIN && event.source === frame.contentWindow &&
          event.data && typeof event.data === 'object' &&
          (event.data.type === 'TOYBACO_POSTIZ_CLOSE_PENDING' || event.data.type === 'TOYBACO_POSTIZ_CLOSE_RESULT')) {
        var request = postCloseRequest;
        if (!request || event.data.requestId !== request.id) return;
        if (event.data.type === 'TOYBACO_POSTIZ_CLOSE_PENDING') {
          window.dispatchEvent(new Event('toybaco:posting-close-pending'));
          if (request.timer) { clearTimeout(request.timer); request.timer = null; }
          return;
        }
        if (typeof event.data.allowed !== 'boolean') return;
        clearPostCloseRequest();
        if (!event.data.allowed) {
          if (request.cancel) request.cancel();
          return;
        }
        postCloseApproved = true;
        try { request.proceed(); } finally { postCloseApproved = false; }
        return;
      }
      if (!isTrustedPostizReady(event, frame.contentWindow) || contextRejected || !matchesContext(event.data) ||
          typeof event.data.organizationId !== 'string' ||
          !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(event.data.organizationId)) return;
      if (!firstBusinessReady && (!event.data.initialRoute ||
          event.data.initialRoute.pathname !== initialRoute.pathname ||
          event.data.initialRoute.aiIntent !== initialRoute.aiIntent)) {
        contextRejected = true;
        showFrameError('選択した投稿画面を確認できません。トイバコを開き直してください。', false);
        return;
      }
      // Renewal is available only to the owner from this document's first READY.
      // Legacy READY remains usable but cannot request a renewal without its owner.
      if (!postFrameReady) {
        if (validRenewalOwner(event.data.owner, event.data.organizationId)) {
          renewalOwner = { id: event.data.owner.id, orgId: event.data.owner.orgId,
            role: event.data.owner.role, providerName: 'GENERIC' };
          renewalActor = postingActor();
        }
      }
      firstBusinessReady = true;
      postFrameReady = true;
      pendingAiIntent = null;
      frame.toybacoThemeSupported = event.data.theme === 'light' || event.data.theme === 'dark';
      if (frame.toybacoThemeSupported) {
        frame.toybacoDisplayTheme = event.data.theme;
        syncPostFrameTheme();
      } else {
        // Identity is mandatory; only the independent theme protocol is optional.
        revealPostFrame(frame);
      }
      // iframe内のEscapeは親documentへ伝播しないため、READY後も閉じる通知を受ける。
    };
    window.addEventListener('message', readyMessageHandler);

    armFrameTimeout();

    panel.appendChild(frame);
  }

  var POST_SECTIONS = [
    { path: '/launches', label: 'カレンダー' },
    { path: '/analytics', label: '分析' },
    { path: '/media', label: 'メディア' },
    { path: '/settings', label: '投稿設定' }
  ];

  function syncPostSections() {
    if (!panel) return;
    var pathname = (panelPath || DEFAULT_PATH).split('?', 1)[0];
    var buttons = panel.querySelectorAll('[data-toybaco-post-path]');
    for (var i = 0; i < buttons.length; i += 1) {
      var path = buttons[i].getAttribute('data-toybaco-post-path');
      if (pathname === path || pathname.indexOf(path + '/') === 0) {
        buttons[i].setAttribute('aria-current', 'page');
      } else {
        buttons[i].removeAttribute('aria-current');
      }
    }
  }

  function buildPostSections() {
    var nav = document.createElement('nav');
    nav.setAttribute('data-toybaco-post-subnav', '1');
    nav.setAttribute('aria-label', '投稿メニュー');
    POST_SECTIONS.forEach(function (section) {
      var button = document.createElement('button');
      button.type = 'button';
      button.textContent = section.label;
      button.setAttribute('data-toybaco-post-path', section.path);
      button.addEventListener('click', function () { navigatePostPath(section.path, false); });
      nav.appendChild(button);
    });
    return nav;
  }

  // 投稿内の移動も既存composerの保存確認を通す。許可されるまでiframeと入力を残す。
  function navigatePostPath(path, fromHistory) {
    var destination = validatePath(path);
    if (!panel || (destination === panelPath && postFrameReady) || postingDeniedFor(currentAccountId())) return;
    var current = panel;
    function restoreHash() {
      if (!fromHistory || panel !== current) return;
      try { writePostingHistory(postingHash(panelPath), true); } catch (e) { /* noop */ }
    }
    if (requestPanelClose(function () { navigatePostPath(destination, fromHistory); }, restoreHash)) return;
    var frame = panel.querySelector('iframe');
    if (frame) frame.remove();
    if (panelSpinner && panelSpinner.parentNode) panelSpinner.remove();
    if (loadTimer) { clearTimeout(loadTimer); loadTimer = null; }
    postFrameReady = false;
    panelPath = destination;
    if (!fromHistory) setHash(destination);
    panelSpinner = createPostSpinner();
    panel.appendChild(panelSpinner);
    syncPostSections();
    // 新しい画面も現在店舗の認証入口を通り、旧画面のREADYは受け取らない。
    mountPostFrame(destination, panelSpinner);
  }

  function createPostSpinner() {
    var spinner = document.createElement('div');
    spinner.setAttribute('data-toybaco-post-loading', '1');
    spinner.setAttribute('role', 'status');
    spinner.setAttribute('aria-live', 'polite');
    spinner.style.cssText =
      'position:absolute;inset:0;display:flex;align-items:center;justify-content:center;' +
      'flex-direction:column;gap:12px;background:var(--toybaco-offwhite,#faf7f2);color:var(--toybaco-muted,#66758a);font-size:14px';
    spinner.innerHTML =
      '<span data-toybaco-post-ring="" aria-hidden="true" style="width:28px;height:28px;min-width:28px;max-width:28px;box-sizing:border-box;flex-shrink:0;border:3px solid var(--toybaco-hairline,#dce2e8);border-top-color:var(--toybaco-muted,#66758a);' +
      'border-radius:50%;display:inline-block;animation:toybaco-spin 1s linear infinite"></span>' +
      '<span>投稿画面を開いています…</span>';
    var style = document.createElement('style');
    style.textContent = '@keyframes toybaco-spin{to{transform:rotate(360deg)}}@media(prefers-reduced-motion:reduce){[data-toybaco-post-ring]{animation:none!important}}';
    spinner.appendChild(style);
    return spinner;
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

  // iframe 外の native メニューは移動せず、その可視領域だけ投稿の下に空ける。
  // 幅変更でも iframe の再生成や認証をせず、編集中の内容を保持する。
  function watchPostPanelLayout() {
    var currentPanel = panel;
    var launcher = null;
    var observer = null;
    var stopped = false;
    function update() {
      if (stopped || panel !== currentPanel) return;
      var space = 0;
      try {
        var next = document.querySelector('[id="mobile-sidebar-launcher"]');
        if (next !== launcher) {
          if (launcher) {
            launcher.removeEventListener('transitionend', update);
            if (observer) observer.unobserve(launcher);
          }
          launcher = next;
          if (launcher) {
            launcher.addEventListener('transitionend', update);
            if (observer) observer.observe(launcher);
          }
        }
        var button = launcher && launcher.querySelector('button');
        if (button && button.getClientRects().length) {
          var style = window.getComputedStyle(button);
          var wrapperStyle = window.getComputedStyle(launcher);
          var rect = button.getBoundingClientRect();
          var bounds = currentPanel.getBoundingClientRect();
          if (style.visibility !== 'hidden' && wrapperStyle.visibility !== 'hidden' &&
              Number(style.opacity) !== 0 && Number(wrapperStyle.opacity) !== 0 &&
              rect.width > 0 && rect.height > 0 && rect.right > bounds.left &&
              rect.left < bounds.right && rect.bottom > bounds.top && rect.top < bounds.bottom) {
            space = Math.ceil(Math.min(bounds.height, bounds.bottom - Math.max(bounds.top, rect.top) + 8));
          }
        }
      } catch (e) { /* native メニュー未描画なら通常の投稿領域を使う */ }
      var padding = space + 'px';
      if (currentPanel.style.paddingBottom !== padding) currentPanel.style.paddingBottom = padding;
    }
    if (window.ResizeObserver) {
      observer = new window.ResizeObserver(update);
      observer.observe(currentPanel);
    }
    window.addEventListener('resize', update);
    panelLayout = {
      update: update,
      stop: function () {
        stopped = true;
        window.removeEventListener('resize', update);
        if (launcher) launcher.removeEventListener('transitionend', update);
        if (observer) observer.disconnect();
      }
    };
    update();
  }

  var SELECTED_CLASS = 'bg-n-alpha-2';

  function navigationClassName(node) {
    return classNameOf(node).split(/\s+/).filter(function (name) {
      return name && name !== 'router-link-active' && name !== 'router-link-exact-active' && name !== SELECTED_CLASS;
    }).join(' ');
  }

  function primaryEntryClassName() {
    // A native row may currently be its 40px collapsed button. Keep the
    // expanded structure stable and let the shared sidebar state size the rail.
    return 'flex items-center gap-2 px-1.5 py-1 rounded-lg h-8 min-w-0 text-n-slate-11 hover:bg-n-alpha-2';
  }

  // router-view の状態は保ち、埋め込み表示中だけ背景と native 子メニューを隠す。
  // Dashboard の共通ダイアログ・mobile launcher はこの所有範囲に含めない。
  var embeddedBackground = [];
  var embeddedReturnFocus = null;
  var embeddedFocusOwner = null;
  var embeddedAttributes = ['data-toybaco-embedded-background', 'inert', 'aria-hidden'];

  function nodeWithin(node, ancestor) {
    while (node) {
      if (node === ancestor) return true;
      node = node.parentElement;
    }
    return false;
  }

  function setEmbeddedAttribute(node, name, value) {
    if (node.getAttribute(name) === value) return;
    if (value === null) node.removeAttribute(name);
    else node.setAttribute(name, value);
  }

  function syncEmbeddedWorkspace() {
    var foreground = panel || auxiliaryView;
    var targets = [];
    if (foreground) {
      var host = findContentHost();
      // Assistance owns its content background; both workspaces suppress the
      // unrelated native submenus through this shared navigation owner.
      var routes = panel && host ? host.querySelectorAll('[data-toybaco-native-route]') : [];
      for (var r = 0; r < routes.length; r += 1) targets.push({ node: routes[r], kind: 'route' });
      var rows = document.querySelectorAll('[data-toybaco-primary-nav]');
      for (var n = 0; n < rows.length; n += 1) {
        var kind = rows[n].getAttribute('data-toybaco-primary-nav');
        if (kind !== 'settings' && kind !== 'reports' && kind !== 'inbox' && kind !== 'contacts') continue;
        var children = rows[n].children;
        for (var c = 0; c < children.length; c += 1) {
          if (children[c].tagName === 'UL') targets.push({
            node: children[c], kind: 'nav', control: rows[n].querySelector('[data-toybaco-nav-link]')
          });
        }
      }
    }
    embeddedBackground = embeddedBackground.filter(function (saved) {
      if (targets.some(function (target) { return target.node === saved.node; })) return true;
      embeddedAttributes.forEach(function (name, index) {
        setEmbeddedAttribute(saved.node, name, saved.values[index]);
      });
      if (saved.control) {
        // Vue can have expanded the destination before this history observer
        // runs. Restore its current state rather than the pre-navigation value.
        var nativeExpanded = saved.control.getAttribute('data-toybaco-native-expanded');
        setEmbeddedAttribute(saved.control, 'aria-expanded',
          nativeExpanded === 'true' || nativeExpanded === 'false' ? nativeExpanded : saved.expanded);
      }
      return false;
    });
    if (!foreground && embeddedReturnFocus) {
      var active = document.activeElement;
      if ((!active || active === document.body || nodeWithin(active, embeddedFocusOwner)) &&
          nodeWithin(embeddedReturnFocus, document.body) && embeddedReturnFocus.focus) {
        embeddedReturnFocus.focus();
      }
      embeddedReturnFocus = null;
      embeddedFocusOwner = null;
    }
    targets.forEach(function (target) {
      if (nodeWithin(document.activeElement, target.node)) {
        embeddedReturnFocus = document.activeElement;
        embeddedFocusOwner = foreground;
        setEmbeddedAttribute(foreground, 'tabindex', '-1');
        if (foreground.focus) foreground.focus();
      }
      if (!embeddedBackground.some(function (saved) { return saved.node === target.node; })) {
        embeddedBackground.push({ node: target.node, control: target.control,
          expanded: target.control && target.control.getAttribute('aria-expanded'), values: embeddedAttributes.map(function (name) {
          return target.node.getAttribute(name);
        }) });
      }
      if (target.control) setEmbeddedAttribute(target.control, 'aria-expanded', 'false');
      [target.kind, '', 'true'].forEach(function (value, index) {
        setEmbeddedAttribute(target.node, embeddedAttributes[index], value);
      });
    });
  }

  function syncPostingSelection() {
    syncEmbeddedWorkspace();
    try {
      var path = window.location.pathname;
      var selected = auxiliaryView ? auxiliaryView.getAttribute('data-toybaco-aux-view') : panel ? 'posting' :
        /\/reports(?:\/|$)/.test(path) ? 'reports' :
        /\/settings(?:\/|$)/.test(path) ? 'settings' :
        /\/contacts(?:\/|$)/.test(path) ? 'contacts' :
        /\/(dashboard|inbox|inbox-view|conversations)(?:\/|$)/.test(path) ? 'inbox' : '';
      var links = document.querySelectorAll('[data-toybaco-nav-link]');
      for (var i = 0; i < links.length; i += 1) {
        var link = links[i];
        var kind = link.getAttribute('data-toybaco-nav-link');
        var on = kind === selected && !closestAttr(link, 'data-toybaco-nav-duplicate');
        link.setAttribute('data-toybaco-nav-current', on ? 'true' : 'false');
        // 注入行はVue Routerの選択classを引き継がない。
        if (kind === 'posting' || kind === 'ai') {
          link.className = navigationClassName(link) + (on ? ' ' + SELECTED_CLASS : '');
        }
        if (on) link.setAttribute('aria-current', 'page');
        else link.removeAttribute('aria-current');
      }
    } catch (e) { /* 選択表示が無くても開閉は続ける */ }
  }

  function openPanel(path, fromHash, aiIntent) {
    if (panel) return;
    closeAuxiliaryView();
    closeAiModePanel();
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
    panelPath = validatePath(path || DEFAULT_PATH);
    panelRouteBase = window.location.pathname + window.location.search;
    panel.setAttribute('data-' + MARK + '-panel', '1');
    panel.style.cssText =
      'position:absolute;inset:0;z-index:1;background:#fff;display:flex;flex-direction:column;box-sizing:border-box';

    var spinner = createPostSpinner();
    panelSpinner = spinner;

    panel.appendChild(buildPostSections());
    panel.appendChild(spinner);
    syncPostSections();
    host.appendChild(panel);
    // reloadでhashが残った場合も、表示済みの退避先を再び開かない。
    try { sessionStorage.removeItem(PENDING_KEY); } catch (e) { /* storage不可でも表示を続ける */ }
    watchPostPanelLayout();
    document.addEventListener('keydown', onKeydown, true);
    syncPostingSelection();

    // サイドバーから別画面へ移ったら閉じる(開いている間だけの軽い見張り)
    var seenPath = window.location.pathname;
    poller = setInterval(function () {
      reconcilePostRenewal();
      if (hasPostingRouteGuard()) return;
      if (window.location.pathname !== seenPath) {
        if (!requestPanelClose(closePanel)) closePanel();
      } else if (!isPostingHash(window.location.hash || '')) onHashMaybeChanged();
    }, 300);

    var id = currentAccountId();
    if (postingDeniedFor(id)) {
      showContractMissing();
      return;
    }
    mountPostFrame(path, spinner, aiIntent);
    reconcilePostingAccess(id);
  }

  function closePanel(preserveHistory) {
    clearPostCloseRequest(true);
    postFrameReady = false;
    if (panelLayout) { panelLayout.stop(); panelLayout = null; }
    if (!panel) {
      removeReadyMessageHandler();
      if (preserveHistory !== true) stripHash();
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
    panelPath = null;
    panelRouteBase = null;
    panelSpinner = null;
    syncPostingSelection();
    if (preserveHistory !== true) stripHash();
  }

  // Returning to the underlying page is a destination, so Back retains posting.
  function closePanelToBase() {
    if (isPostingHash(window.location.hash || '') || isAssistantHash(window.location.hash || '')) writePostingHistory('', false);
    closePanel(true);
  }

  // 既存メニューの1行を手本にして、同じ見た目の行を作る
  function buildEntry(sampleRow, accountId) {
    var li = document.createElement('li');
    li.className = sampleRow.li.className;
    li.setAttribute('data-' + MARK + '-wrap', '1');

    var a = document.createElement('a');
    a.href = postingHash(DEFAULT_PATH);
    a.className = primaryEntryClassName();
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
      if ((e.button != null && e.button !== 0) || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
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

  // 会話・連絡先・レポート・設定の子導線は native の権限と展開状態に任せる。
  // トイバコで提供しない独立した在庫グループだけを一次ナビから外す。
  var STOCK_TITLES = {
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
  var STOCK_ICON_RE = /\b(i-lucide-library-big|i-woot-captain|i-lucide-building-2|i-lucide-phone|i-lucide-sparkles|i-lucide-bot|i-lucide-users|i-lucide-users-round|i-lucide-messages-square)\b/;
  var STOCK_HREF_RE = /\/(campaigns|portals|captain|companies|calls|notifications|mentions|participating)(\/|\?|#|$)/;
  var INJECT_RETRY_MS = [0, 16, 50, 100, 200, 400, 800, 1600, 3200, 6000, 10000];

  function isToybacoNavRow(row) {
    if (!row) return false;
    try {
      if (row.getAttribute && (row.getAttribute('data-toybaco-aux-nav') || row.getAttribute('data-toybaco-ai-nav'))) return true;
      if (row.getAttribute && (
        row.getAttribute('data-' + MARK + '-wrap') === '1' ||
        row.getAttribute('data-' + MARK)
      )) return true;
      return !!(row.querySelector && row.querySelector(
        '[data-' + MARK + '], [data-' + MARK + '-wrap]'
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

  function isNativePrimaryChild(node, list) {
    var row = node;
    while (row && row.parentElement !== list) row = row.parentElement;
    if (!row || row === node) return false;
    var kind = primaryNavKind(row);
    return kind === 'settings' || kind === 'reports' || kind === 'inbox' || kind === 'contacts';
  }

  function hideLeftoverTrees() {
    try {
      var nav = document.querySelector('aside nav');
      if (!nav || !nav.querySelectorAll) return;
      var list = primaryNavList();
      var nodes = nav.querySelectorAll('li, a, [role="button"], button, div[title], span');
      for (var i = 0; i < nodes.length; i += 1) {
        var node = nodes[i];
        // 会話・連絡先・設定・レポートの子は、元のPolicyとSidebarGroupが表示・権限を管理する。
        if (isNativePrimaryChild(node, list)) continue;
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
        var inner = row.querySelector('a, [role="button"], button');
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
      else if (/^(連絡先|Contacts)$/.test(title || '')) kind = 'contacts';
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
      // 通知用Inboxと会話グループが共存する。子のルーターリンクは残して親だけ1件にする。
      if (kind === 'inbox' && row !== sample.li) {
        row.setAttribute('data-toybaco-nav-duplicate', '1');
        row.removeAttribute('data-toybaco-primary-nav');
      } else {
        row.removeAttribute('data-toybaco-nav-duplicate');
        row.setAttribute('data-toybaco-primary-nav', kind);
      }
      link.setAttribute('data-toybaco-nav-link', kind);
      if (link.tagName === 'A' && kind === 'inbox') {
        var dest = primaryNavDestination(kind, id);
        link.setAttribute('href', dest);
        link.href = dest;
      } else if (link.tagName !== 'A' && !link.getAttribute('data-toybaco-nav-keyboard')) {
        link.setAttribute('tabindex', '0');
        link.setAttribute('data-toybaco-nav-keyboard', '1');
        link.addEventListener('keydown', function (event) {
          if (event.key !== 'Enter' && event.key !== ' ') return;
          event.preventDefault();
          event.stopPropagation();
          if (event.stopImmediatePropagation) event.stopImmediatePropagation();
          this.click();
        }, true);
      }
    }
  }

  function navigatePrimaryNav(kind) {
    var auxiliaryPosting = auxiliaryPostingDestination();
    var assistant = isAssistantHash(window.location.hash || '');
    closeAuxiliaryView();
    if (requestPanelClose(function () { navigatePrimaryNav(kind); })) return;
    var id = currentAccountId();
    if (!id) return;
    var returnToConversation = kind === 'inbox' && (panel || auxiliaryPosting || assistant) &&
      /\/(dashboard|inbox|conversations)(?:\/|$)/.test(window.location.pathname);
    closeAiModePanel();
    closePanel(auxiliaryPosting ? true : undefined);
    if (returnToConversation) {
      if (auxiliaryPosting || assistant) closePanelToBase();
      return;
    }
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
        row.getAttribute('data-' + AI_MARK) ||
        row.getAttribute('data-' + AI_MARK) === ''
      )) return true;
      if (row.querySelector && row.querySelector('[data-' + AI_MARK + ']')) return true;
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
    var inboxRow = null;
    var fallback = null;
    var i;
    for (i = 0; i < kids.length; i += 1) {
      var row = kids[i];
      if (!row || isToybacoNavRow(row) || !rowInner(row)) continue;
      if (row.getAttribute && row.getAttribute('data-toybaco-stock-hidden') === '1') continue;
      if (isContractOrSettingsRow(row)) continue;
      if (isInboxSample(row)) {
        // 会話ツリーの親を通知用リンクより優先。再描画で親が消えたら残った入口へ戻す。
        if (!inboxRow || (primaryNavKind(row) === 'inbox' && rowInner(row).tagName !== 'A')) inboxRow = row;
      }
      if (!fallback) fallback = row;
    }
    if (inboxRow) return inboxRow;
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

  // Shared product assistance: these are read-only entry points, never AI activation.
  var auxiliaryView = null;
  var auxiliaryAccount = null;
  var auxiliaryRoute = null;
  var auxiliaryPostingReturn = null;
  var auxiliaryReturnFocus = null;
  var auxiliaryBackground = [];

  function auxiliaryText(tag, text, attribute) {
    var node = document.createElement(tag);
    node.textContent = text;
    if (attribute) node.setAttribute(attribute, '1');
    return node;
  }

  function auxiliaryButton(text, action, primary) {
    var button = auxiliaryText('button', text, 'data-toybaco-aux-action');
    button.type = 'button';
    if (primary) button.setAttribute('data-toybaco-aux-primary', '1');
    button.addEventListener('click', action);
    return button;
  }

  function auxiliaryLocation() {
    return window.location.pathname + (window.location.search || '') + (window.location.hash || '');
  }

  function auxiliaryPostingDestination() {
    var destination = auxiliaryPostingReturn;
    return destination && destination.account === currentAccountId() &&
      destination.route === auxiliaryLocation() && destination.path === currentHashPath() &&
      destination.path === validatePath(destination.path) ? destination : null;
  }

  function closeAuxiliaryView(restorePosting) {
    if (!auxiliaryView) return;
    var destination = auxiliaryPostingDestination();
    var selected = document.querySelector('[data-toybaco-aux-entry][aria-current="page"]');
    if (selected) selected.removeAttribute('aria-current');
    auxiliaryView.remove();
    auxiliaryView = null;
    auxiliaryAccount = null;
    auxiliaryRoute = null;
    auxiliaryPostingReturn = null;
    auxiliaryBackground.forEach(function (saved) {
      if (saved.inert === null) saved.node.removeAttribute('inert');
      else saved.node.setAttribute('inert', saved.inert);
      if (saved.hidden === null) saved.node.removeAttribute('aria-hidden');
      else saved.node.setAttribute('aria-hidden', saved.hidden);
    });
    auxiliaryBackground = [];
    document.removeEventListener('keydown', auxiliaryKeydown, true);
    if (auxiliaryReturnFocus && auxiliaryReturnFocus.isConnected !== false && auxiliaryReturnFocus.focus) auxiliaryReturnFocus.focus();
    auxiliaryReturnFocus = null;
    syncPostingSelection();
    // Only the explicit Close/Escape returns to the previous surface. A fresh
    // iframe rechecks identity; discarded composer state and AI intent stay gone.
    if (restorePosting === true && destination) openPanel(destination.path, true);
    else if (restorePosting === true && isAssistantHash(window.location.hash || '')) openAuxiliaryView('ai', null, true);
  }

  function auxiliaryKeydown(event) {
    if (event.key !== 'Escape' || event.isComposing || event.defaultPrevented || !auxiliaryView || aiPanel ||
        auxiliaryView.getAttribute('data-toybaco-aux-view') !== 'about' || hasNativeEscapeOverlay()) return;
    event.preventDefault(); event.stopPropagation();
    closeAuxiliaryView(true);
  }

  function visitAiSettings() {
    var id = currentAccountId();
    if (!id || id !== auxiliaryAccount) return;
    var destination = '/app/accounts/' + id + '/settings/inboxes/list';
    var nativeLink = null;
    walkNavNodes(primaryNavList(), function (node) {
      if (!nativeLink && hrefOf(node) === destination && typeof node.click === 'function') nativeLink = node;
    });
    if (!nativeLink) return;
    closeAuxiliaryView();
    nativeLink.click();
  }

  function hasAiSettingsLink() {
    var destination = '/app/accounts/' + currentAccountId() + '/settings/inboxes/list';
    var found = false;
    walkNavNodes(primaryNavList(), function (node) { if (hrefOf(node) === destination) found = true; });
    return found;
  }

  function auxiliarySteps(items) {
    var details = document.createElement('details');
    details.setAttribute('data-toybaco-ai-guide', '1');
    details.appendChild(auxiliaryText('summary', '使い方'));
    var steps = document.createElement('ol');
    items.forEach(function (text) { steps.appendChild(auxiliaryText('li', text)); });
    details.appendChild(steps);
    return details;
  }

  function appendReplyAiGuide(host) {
    host.appendChild(auxiliaryText('h2', '問い合わせ返信'));
    host.appendChild(auxiliaryText('p', '問い合わせへの返信を、下書き・自動応答で支援します。'));
    var actions = document.createElement('div');
    actions.setAttribute('data-toybaco-aux-actions', '1');
    actions.appendChild(auxiliaryButton('返信AIの設定を確認', function () { openAiModePanel(); }, true));
    if (hasAiSettingsLink()) actions.appendChild(auxiliaryButton('AIを使う受信トレイを設定', visitAiSettings));
    actions.appendChild(auxiliaryButton('会話を開く', function () { navigatePrimaryNav('inbox'); }));
    host.appendChild(actions);
    var status = document.createElement('div');
    status.setAttribute('data-toybaco-ai-hub-status', '1');
    appendAiModeStatus(status); host.appendChild(status);
    appendAiUsage(host);
    var guide = auxiliarySteps([
      'AIを割り当てた受信箱に、新しい問い合わせが届くと開始します。AI対応中の会話が対象で、担当者が対応を始めた会話では作成しません。',
      '下書きモードでは内部メモに文案が届き、全自動モードではAIがお客さまへ返信します。「返信AIの設定を確認」で、現在のモードを確認できます。',
      '下書きを使う場合は、会話内の「AI下書きを使う」で返信欄へ取り込み、内容と宛先を確認して送信します。'
    ]);
    if (hasAiSettingsLink()) host.appendChild(auxiliaryText('p', '受信トレイを選び、「ボット設定」で「トイバコAI」を割り当てると利用を開始できます。', 'data-toybaco-aux-note'));
    else host.appendChild(auxiliaryText('p', 'AIを使う受信トレイの設定は管理者が行います。「受信トレイ → ボット設定」で「トイバコAI」の割り当てを確認してもらってください。', 'data-toybaco-aux-note'));
    host.appendChild(guide);
  }

  function appendPostingAiGuide(host) {
    host.appendChild(auxiliaryText('h2', '投稿文作成'));
    host.appendChild(auxiliaryText('p', '商品の紹介やお知らせを、伝わる投稿文に。'));
    var accountId = currentAccountId();
    var availability = auxiliaryText('p', '', 'data-toybaco-posting-ai-availability');
    availability.setAttribute('role', 'status');
    var start = auxiliaryButton('投稿画面で文案を作る', function () { if (currentAccountId() !== accountId || postingDeniedFor(accountId)) return; closeAuxiliaryView(); openPanel(DEFAULT_PATH, false, 'compose'); }, true);
    var actions = document.createElement('div'); actions.setAttribute('data-toybaco-aux-actions', '1');
    actions.appendChild(start); host.appendChild(actions); host.appendChild(availability);
    function paintAvailability() {
      if (currentAccountId() !== accountId) return;
      var denied = postingDeniedFor(accountId);
      start.disabled = denied;
      start.textContent = denied ? '投稿機能は利用できません' : postingStatusCache[accountId] === true ? '投稿画面で文案を作る' : '投稿画面で利用条件を確認';
      availability.textContent = denied ? 'このワークスペースでは投稿機能をご利用いただけません。利用をご希望の場合は契約者にご確認ください。' : 'AIの利用可否は、開いた投稿画面でご案内します。';
    }
    paintAvailability(); resolvePostingAllowed(accountId, paintAvailability);
    host.appendChild(auxiliaryText('p', '問い合わせ返信とは別の文章支援です。返信AIの月間利用枠は使いません。', 'data-toybaco-aux-note'));
    var guide = auxiliarySteps([
      '「投稿画面で文案を作る」から投稿先を選びます。未接続なら、先に「チャンネルを追加」で連携してください。',
      '作りたい文案・雰囲気・文字数をAIに伝えます。画像・動画のAI生成は提供していません。',
      '文案を編集して下書き保存。公開・予約は、内容と投稿先を確認してから操作します。'
    ]);
    var support = document.createElement('a');
    support.href = 'mailto:support@toybaco.jp?subject=' + encodeURIComponent('投稿文AIの接続設定について');
    support.textContent = '接続設定について相談する';
    support.setAttribute('data-toybaco-aux-link', '1'); guide.appendChild(support);
    host.appendChild(guide);
  }

  function appendAboutGuide(host) {
    var support = document.createElement('a');
    support.href = 'mailto:support@toybaco.jp';
    support.textContent = 'サポートに問い合わせる';
    support.setAttribute('data-toybaco-aux-link', '1');
    host.appendChild(support);
    var details = document.createElement('details');
    details.setAttribute('data-toybaco-about-licenses', '1');
    details.appendChild(auxiliaryText('summary', 'ライセンス情報'));
    details.appendChild(auxiliaryText('p', 'トイバコは以下のオープンソースソフトウェアを利用しています。追加の機能・依存ソフトウェアの個別条件は、各ライセンス本文を参照してください。'));
    [
      ['問い合わせ対応', 'Chatwoot / MIT', 'https://github.com/chatwoot/chatwoot/blob/b354a9550e1fb59fa537a9c384232cb076213e72/LICENSE', new URL('/toybaco/source', window.location.origin).href],
      ['投稿管理', 'Postiz / AGPL-3.0', 'https://www.gnu.org/licenses/agpl-3.0.html', new URL('/api/toybaco/source', POST_ORIGIN).href]
    ].forEach(function (item) {
      var section = document.createElement('section');
      section.appendChild(auxiliaryText('h2', item[0]));
      section.appendChild(auxiliaryText('p', item[1]));
      [['ライセンス本文', item[2]], ['対応するソース', item[3]]].forEach(function (link) {
        var a = document.createElement('a'); a.textContent = link[0]; a.href = link[1];
        a.target = '_blank'; a.rel = 'noopener noreferrer'; a.setAttribute('data-toybaco-aux-link', '1');
        section.appendChild(a);
      });
      details.appendChild(section);
    });
    host.appendChild(details);
  }

  function openAuxiliaryView(kind, purpose, fromHash) {
    if (kind !== 'ai' && kind !== 'about') return;
    if (!purpose && auxiliaryView && auxiliaryView.getAttribute('data-toybaco-aux-view') === kind &&
        auxiliaryAccount === currentAccountId() && auxiliaryRoute === auxiliaryLocation()) return;
    if (requestPanelClose(function () { openAuxiliaryView(kind, purpose, fromHash); })) return;
    if (!isLoggedInView()) return;
    var host = findContentHost();
    if (!host) return;
    var returnPosting = auxiliaryPostingReturn;
    if (panel) {
      returnPosting = { account: currentAccountId(), path: panelPath, route: auxiliaryLocation() };
      closePanel(true);
    }
    closeAiModePanel();
    closeAuxiliaryView();
    if (kind === 'ai') {
      if (!fromHash && !isAssistantHash(window.location.hash || '')) writePostingHistory('#/toybaco/assistant', false);
      try { sessionStorage.removeItem(PENDING_KEY); } catch (e) { /* optional pending return */ }
    }
    mountPanelHost(host);
    auxiliaryReturnFocus = document.activeElement;
    auxiliaryAccount = currentAccountId();
    auxiliaryRoute = auxiliaryLocation();
    auxiliaryPostingReturn = returnPosting && returnPosting.account === auxiliaryAccount &&
      returnPosting.route === auxiliaryRoute ? returnPosting : null;
    var view = document.createElement('section');
    view.setAttribute('data-toybaco-aux-view', kind);
    view.setAttribute('data-account', auxiliaryAccount);
    view.setAttribute('role', 'region');
    view.setAttribute('aria-label', kind === 'ai' ? 'AIアシスタント' : 'トイバコについて');
    var head = document.createElement('header');
    var title = auxiliaryText('h1', kind === 'ai' ? 'AIアシスタント' : 'トイバコについて');
    title.setAttribute('tabindex', '-1');
    head.appendChild(title);
    if (kind === 'about') head.appendChild(auxiliaryButton('閉じる', function () { closeAuxiliaryView(true); }));
    view.appendChild(head);
    view.appendChild(auxiliaryText('p', kind === 'ai' ? '返信と投稿。それぞれの作業に合ったAIを選んでください。' : '問い合わせ対応と投稿管理を、ひとつのワークスペースで。', 'data-toybaco-aux-lead'));
    if (kind === 'ai') {
      var grid = document.createElement('div');
      grid.setAttribute('data-toybaco-ai-cards', '1');
      var reply = document.createElement('article'); reply.setAttribute('data-toybaco-ai-purpose', 'reply'); reply.setAttribute('tabindex', '-1');
      var posting = document.createElement('article'); posting.setAttribute('data-toybaco-ai-purpose', 'posting'); posting.setAttribute('tabindex', '-1');
      appendReplyAiGuide(reply); appendPostingAiGuide(posting);
      grid.appendChild(reply); grid.appendChild(posting); view.appendChild(grid);
    } else appendAboutGuide(view);
    auxiliaryBackground = Array.prototype.slice.call(host.children || []).filter(function (node) {
      return kind !== 'ai' || node.getAttribute('id') !== 'mobile-sidebar-launcher';
    }).map(function (node) {
      var saved = { node: node, inert: node.getAttribute('inert'), hidden: node.getAttribute('aria-hidden') };
      node.setAttribute('inert', ''); node.setAttribute('aria-hidden', 'true');
      return saved;
    });
    host.appendChild(view);
    auxiliaryView = view;
    syncPostingSelection();
    document.addEventListener('keydown', auxiliaryKeydown, true);
    if (kind === 'ai') { prefetchAiMode(auxiliaryAccount, true); paintAiModeControls(); paintAiUsage(); }
    var selected = document.querySelector('[data-toybaco-aux-entry="' + kind + '"]');
    if (selected) selected.setAttribute('aria-current', 'page');
    var destination = purpose === 'reply' ? reply : purpose === 'posting' ? posting : title;
    if (destination && destination.focus) destination.focus();
    if (purpose && destination && destination.scrollIntoView) destination.scrollIntoView({ block: 'nearest' });
  }

  function ensureAuxiliaryNavigation(sample) {
    var id = currentAccountId();
    if (!id || !sample) return;
    [['ai', 'AIアシスタント', 'i-lucide-sparkles', 'data-toybaco-ai-nav'], ['about', 'トイバコについて', 'i-lucide-info', 'data-toybaco-aux-nav']].forEach(function (item) {
      var row = document.querySelector('[' + item[3] + ']');
      if (row && row.getAttribute('data-account') !== id) { row.remove(); row = null; }
      if (!row) {
        row = document.createElement('li'); row.setAttribute(item[3], '1'); row.setAttribute('data-account', id);
        if (item[0] === 'ai') row.setAttribute('data-toybaco-primary-nav', 'ai');
        var button = document.createElement(item[0] === 'ai' ? 'a' : 'button');
        if (item[0] === 'ai') { button.href = '#/toybaco/assistant'; button.className = primaryEntryClassName(); }
        else button.type = 'button';
        button.title = item[1];
        button.setAttribute('data-toybaco-aux-entry', item[0]); button.setAttribute('aria-label', item[1]);
        if (item[0] === 'ai') button.setAttribute('data-toybaco-nav-link', 'ai');
        var icon = document.createElement('span'); icon.className = item[2]; icon.setAttribute('aria-hidden', 'true');
        if (item[0] === 'ai') {
          row.className = sample.li.className;
          var iconWrap = document.createElement('div'); iconWrap.className = 'relative flex items-center gap-2';
          icon.className += ' size-4'; iconWrap.appendChild(icon); button.appendChild(iconWrap);
          var textWrap = document.createElement('div'); textWrap.className = 'flex items-center min-w-0 flex-grow';
          var label = auxiliaryText('span', item[1]); label.className = 'truncate';
          textWrap.appendChild(label); button.appendChild(textWrap);
        } else { button.appendChild(icon); button.appendChild(auxiliaryText('span', item[1])); }
        row.appendChild(button);
      }
      if (item[0] === 'ai') {
        var anchor = sample.li;
        var posting = document.querySelector('[data-' + MARK + ']');
        var postingWrap = posting && posting.parentElement;
        if (posting && posting.getAttribute('data-account') === id && postingWrap &&
            postingWrap.getAttribute('data-' + MARK + '-wrap') === '1' && postingWrap.parentElement === sample.ul) {
          // Vue 再描画後も既存の投稿位置を先に整え、表示順と DOM 順を揃える。
          placeEntry(sample, postingWrap);
          anchor = postingWrap;
        }
        if (row.parentElement !== sample.ul || row.previousElementSibling !== anchor) {
          sample.ul.insertBefore(row, anchor.nextSibling);
        }
      } else if (row.parentElement !== sample.ul) sample.ul.appendChild(row);
    });
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

  function aiModeCanEdit(mode) {
    if (aiModeState().phase !== 'ready') return false;
    // 下書きは送信を人に戻す保存設定。生成権限や接続の確認とは分ける。
    if (normalizeAiMode(mode) === AI_MODE_DRAFT) return true;
    if (normalizeAiMode(mode) !== AI_MODE_AUTO) return false;
    var readiness = aiReadinessState();
    var usage = aiUsageState();
    return readiness.phase === 'ready' &&
      readiness.data.connection === 'configured' && usage.phase === 'ready' && usage.data.enabled;
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

  function aiModeCompactStatus(state, readiness, usage) {
    var access = usage.phase === 'ready' ? usage.data : null;
    var connection = readiness.phase === 'ready' ? readiness.data.connection : null;
    // 保存済みのモードより、現在わかっている利用不可・未確認を優先する。
    if (access && !access.enabled) {
      if (access.reason === 'disabled') return { state: 'unavailable', text: 'AI：利用できません' };
      if (access.reason === 'account_inactive') return { state: 'unavailable', text: 'AI：利用停止中' };
      return { state: 'unconfirmed', text: 'AI：利用条件を確認' };
    }
    if (connection === 'unconnected') return { state: 'unconnected', text: 'AI：未接続' };
    if (access && access.remaining === 0) return { state: 'limited', text: 'AI：残り枠なし' };
    if (usage.phase === 'error') return { state: 'unconfirmed', text: 'AI：利用条件を確認' };
    if (readiness.phase === 'error' || connection === 'unknown') {
      return { state: 'unconfirmed', text: 'AI：接続を確認' };
    }
    if (state.phase === 'error' || (state.phase === 'ready' && !normalizeAiMode(state.mode))) {
      return { state: 'unconfirmed', text: 'AI：設定を確認' };
    }
    if (state.phase === 'saving') return { state: 'saving', text: 'AI：変更中' };
    if (state.phase !== 'ready' || readiness.phase !== 'ready' || usage.phase !== 'ready') {
      return { state: 'checking', text: 'AI：確認中' };
    }
    return { state: 'configured', text: 'AI：' + aiModeLabel(state.mode) };
  }

  function paintAiModeControls() {
    var state = aiModeState();
    var readiness = aiReadinessState();
    var usage = aiUsageState();
    var connection = readiness.phase === 'ready' ? readiness.data.connection : 'unknown';
    var selected = state.mode;
    var busy = state.phase === 'loading' || state.phase === 'saving' || readiness.phase === 'loading' ||
      usage.phase === 'loading' || usage.phase === 'idle';
    var text = state.message;
    if (!text) {
      if (state.phase === 'error') text = '設定を確認できませんでした。再確認してください。';
      else if (state.phase !== 'ready') text = '店舗全体の設定を確認しています…';
      else text = '保存された設定：' + aiModeLabel(selected);
      if (state.phase === 'ready' && usage.phase === 'ready' && usage.data.reason === 'disabled') {
        text += '（この店舗では利用できません）';
      }
    }
    var connectionText = 'AI応答の接続状態を確認できません。再確認してください。';
    if (readiness.phase === 'loading' || readiness.phase === 'idle') connectionText = 'AI応答の接続設定を確認しています…';
    else if (connection === 'unconnected') connectionText = 'AI応答は未接続です。担当者が返信してください。';
    else if (connection === 'configured') connectionText = '接続設定あり（受信箱 ' + readiness.data.configured_inboxes +
      ' / ' + readiness.data.total_inboxes + ' 件）。利用可否・残り枠は「AI応答」の設定で確認できます。';
    if (usage.phase === 'loading' || usage.phase === 'idle') connectionText = 'AI応答の利用条件を確認しています…';
    else if (usage.phase === 'error') connectionText = 'AI応答の利用条件を取得できませんでした。再確認してください。';
    else if (!usage.data.enabled) connectionText = aiUsageAccessMessage(usage.data);
    else if (usage.data.remaining === 0) connectionText = aiUsageAccessMessage(usage.data) + ' ' + connectionText;
    var compactStatus = aiModeCompactStatus(state, readiness, usage);
    try {
      var buttons = document.querySelectorAll('[data-toybaco-ai-mode]');
      var i;
      for (i = 0; i < buttons.length; i += 1) {
        var btn = buttons[i];
        var value = btn.getAttribute && btn.getAttribute('data-toybaco-ai-mode');
        if (btn.setAttribute) {
          btn.setAttribute('aria-pressed', value === selected ? 'true' : 'false');
          btn.setAttribute('data-toybaco-ai-on', value === selected ? '1' : '0');
          btn.setAttribute('aria-disabled', aiModeCanEdit(value) ? 'false' : 'true');
          btn.disabled = !aiModeCanEdit(value);
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
        var displayedConnection = connections[i].parentElement && connections[i].parentElement.getAttribute('data-toybaco-ai-hub-status') === '1' && connection === 'configured' && usage.phase === 'ready' && usage.data.enabled && usage.data.remaining !== 0 ? 'AIを割り当てた受信箱：' + readiness.data.configured_inboxes + ' / ' + readiness.data.total_inboxes + ' 件' : connectionText;
        if (connections[i].textContent !== displayedConnection) connections[i].textContent = displayedConnection;
      }
      var summaries = document.querySelectorAll('[data-toybaco-ai-compact-status]');
      for (i = 0; i < summaries.length; i += 1) {
        if (summaries[i].textContent !== compactStatus.text) summaries[i].textContent = compactStatus.text;
        if (summaries[i].getAttribute('data-toybaco-ai-compact-state') !== compactStatus.state) {
          summaries[i].setAttribute('data-toybaco-ai-compact-state', compactStatus.state);
        }
      }
      var retries = document.querySelectorAll('[data-toybaco-ai-retry]');
      for (i = 0; i < retries.length; i += 1) retries[i].hidden = state.phase !== 'error' &&
        usage.phase !== 'error' && readiness.phase !== 'error' &&
        (usage.phase !== 'ready' || usage.data.reason !== 'unknown_contract') &&
        (readiness.phase !== 'ready' || connection === 'configured' ||
          (usage.phase === 'ready' && !usage.data.enabled));
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

  function aiUsageAccessMessage(data) {
    if (data.reason === 'unknown_contract') return 'AI応答の利用条件を確認できません。契約者またはトイバコサポートにご確認ください。';
    if (data.reason === 'account_inactive') return '現在、この店舗のAI応答はご利用いただけません。契約者またはトイバコサポートにご確認ください。';
    if (data.reason === 'disabled') return 'この店舗ではAI応答をご利用いただけません。契約者またはトイバコサポートにご確認ください。';
    if (data.remaining === 0) return '現在、利用できる残り枠がありません。';
    return '';
  }

  function paintAiUsage() {
    var cards = document.querySelectorAll('[data-toybaco-ai-usage]');
    var account = currentAccountId();
    var state = aiUsageState(account);
    for (var i = 0; i < cards.length; i += 1) {
      if (cards[i].getAttribute('data-account') === account) paintAiUsageCard(cards[i], state);
    }
  }

  function paintAiUsageCard(card, state) {
    var data = state.phase === 'ready' ? state.data : null;
    var active = data && data.enabled;
    var busy = state.phase === 'loading' || state.phase === 'idle';
    var message = busy ? '利用状況を確認しています…' : '利用状況を取得できませんでした。再確認してください。';
    if (data) {
      message = aiUsageAccessMessage(data) || '全自動・下書きで共通の利用枠です。';
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
    refresh.textContent = busy ? '更新中…' : (state.phase === 'error' ? '再確認' : '更新');
    // Native disabled drops the focused button to BODY in Chrome. Keep its
    // place in the Tab order while the guarded handler prevents another read.
    refresh.setAttribute('aria-disabled', busy ? 'true' : 'false');
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

  function prefetchAiUsage(accountId, force) {
    var id = accountId || currentAccountId();
    if (!id || !/^[1-9]\d*$/.test(String(id))) return Promise.resolve(null);
    if (aiUsageInflight[id]) return aiUsageInflight[id];
    var state = aiUsageState(id);
    if (!force && state.phase !== 'idle') return Promise.resolve(null);
    state.data = null;
    state.phase = window.fetch ? 'loading' : 'error';
    if (id === currentAccountId()) { paintAiUsage(); paintAiModeControls(); }
    if (!window.fetch) return Promise.resolve(null);
    aiUsageInflight[id] = requestAiJson('/toybaco/ai_usage?account_id=' + encodeURIComponent(id), {
      credentials: 'same-origin', cache: 'no-store', headers: { Accept: 'application/json' }
    }, validateAiUsage).then(function (body) {
      delete aiUsageInflight[id];
      state.data = body;
      state.phase = 'ready';
      if (id === currentAccountId()) { paintAiUsage(); paintAiModeControls(); }
      return body;
    }).catch(function () {
      delete aiUsageInflight[id];
      state.data = null;
      state.phase = 'error';
      if (id === currentAccountId()) { paintAiUsage(); paintAiModeControls(); }
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
    refresh.addEventListener('click', function () {
      if (refresh.getAttribute('aria-disabled') === 'true') return;
      prefetchAiUsage(currentAccountId(), true);
    });
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
    if (aiModeInflight[id]) { prefetchAiUsage(id, force); return aiModeInflight[id]; }
    var state = aiModeState(id);
    // DOMの描画ごとにGETを繰り返さず、店舗切替・設定を開く・再確認で更新する。
    if (!force && state.phase !== 'idle') { prefetchAiUsage(id); return Promise.resolve(null); }
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
    prefetchAiUsage(id, force);
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
    if (!aiModeCanEdit(next) || next === state.mode) return aiModeInflight[id] || Promise.resolve(null);
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
        var guide = document.createElement('button'); guide.type = 'button';
        guide.setAttribute('data-toybaco-aux-entry', 'ai'); guide.setAttribute('data-toybaco-aux-purpose', 'reply');
        guide.setAttribute('data-toybaco-ai-guide', '1'); guide.textContent = '返信AIの使い方';
        bar.appendChild(guide);
        var scope = document.createElement('span');
        scope.setAttribute('data-toybaco-ai-scope', '1');
        scope.textContent = '店舗全体';
        bar.appendChild(scope);
        bar.appendChild(buildAiModeButton(AI_MODE_AUTO, 'chip'));
        bar.appendChild(buildAiModeButton(AI_MODE_DRAFT, 'chip'));
        appendAiModeStatus(bar);
        var compact = document.createElement('div');
        compact.setAttribute('data-toybaco-ai-compact', '1');
        var summary = document.createElement('span');
        summary.setAttribute('data-toybaco-ai-compact-status', '1');
        summary.setAttribute('role', 'status');
        summary.setAttribute('aria-live', 'polite');
        compact.appendChild(summary);
        var settings = document.createElement('button');
        settings.type = 'button';
        settings.setAttribute('data-toybaco-ai-compact-settings', '1');
        settings.setAttribute('data-' + AI_MARK, '1');
        settings.setAttribute('aria-haspopup', 'dialog');
        settings.setAttribute('aria-label', '店舗全体のAI応答設定を開く');
        settings.textContent = '設定';
        compact.appendChild(settings);
        var compactGuide = document.createElement('button'); compactGuide.type = 'button'; compactGuide.textContent = '使い方';
        compactGuide.setAttribute('data-toybaco-aux-entry', 'ai'); compactGuide.setAttribute('data-toybaco-aux-purpose', 'reply');
        compactGuide.setAttribute('data-toybaco-ai-guide', '1'); compact.appendChild(compactGuide);
        bar.appendChild(compact);
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
      if (!auxiliaryView || auxiliaryView.getAttribute('data-toybaco-aux-view') !== 'ai') closeAuxiliaryView();
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
      lead.textContent = 'この店舗全体で使う、AI応答の送り方の保存設定です。未接続でも下書き設定を保存できます。AIの生成には接続設定と利用条件の確認が必要です。';
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
      paintAiUsage();
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
    if (!aiPanel || e.defaultPrevented || e.isComposing) return;
    if (e.key === 'Escape') {
      e.preventDefault(); e.stopPropagation();
      closeAiModePanel();
      return;
    }
    if (e.key !== 'Tab' || e.ctrlKey || e.metaKey || e.altKey) return;
    var controls = Array.prototype.filter.call(aiPanel.querySelectorAll('button'), function (button) {
      return !button.disabled && !button.hidden && !button.closest('[hidden], [inert]') &&
        (!button.getClientRects || button.getClientRects().length > 0);
    });
    if (!controls.length) return;
    var current = controls.indexOf(document.activeElement);
    if (current === -1 || (e.shiftKey ? current === 0 : current === controls.length - 1)) {
      e.preventDefault(); e.stopPropagation();
      controls[e.shiftKey ? controls.length - 1 : 0].focus();
    }
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

  function returnsToExpandedNativeGroup(link, kind) {
    if (!panel) return false;
    var matchingRoute = kind === 'inbox'
      ? /\/(dashboard|inbox|inbox-view|conversations)(?:\/|$)/.test(window.location.pathname)
      : new RegExp('/' + kind + '(?:/|$)').test(window.location.pathname);
    if (!matchingRoute) return false;
    var row = closestAttr(link, 'data-toybaco-primary-nav');
    if (!row || row.getAttribute('data-toybaco-primary-nav') !== kind) return false;
    var expanded = false;
    walkOwnRow(row, function (node) {
      // Native SidebarGroupHeader owns this v-show state. Embedded CSS only
      // hides the indicator visually; its inline display still tracks expansion.
      if (/\bi-lucide-chevron-up\b/.test(classNameOf(node)) && node.style && node.style.display !== 'none') {
        expanded = true;
      }
    });
    return expanded;
  }

  function onNavClickCapture(e) {
    try {
      if (e.defaultPrevented || (e.button != null && e.button !== 0)) return;
      var t = e.target || e.srcElement;
      var navLink = closestAttr(t, 'data-toybaco-nav-link');
      var navKind = navLink && navLink.getAttribute('data-toybaco-nav-link');
      if (navKind === 'reports' || navKind === 'settings' || navKind === 'contacts' || (navKind === 'inbox' && navLink.tagName !== 'A')) {
        if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
        // The native group classifies navigation versus a toggle. Its route
        // guard or explicit base return owns confirmation and history once.
        if (hasPostingRouteGuard()) { closeAiModePanel(); return; }
        if (requestPanelClose(function () { navLink.click(); })) {
          if (e.preventDefault) e.preventDefault();
          if (e.stopPropagation) e.stopPropagation();
          if (e.stopImmediatePropagation) e.stopImmediatePropagation();
          return;
        }
        var preserveExpanded = returnsToExpandedNativeGroup(navLink, navKind);
        closeAiModePanel();
        closeAuxiliaryView();
        closePanel();
        if (preserveExpanded) {
          if (e.preventDefault) e.preventDefault();
          if (e.stopPropagation) e.stopPropagation();
          if (e.stopImmediatePropagation) e.stopImmediatePropagation();
        }
        // native clickが権限内の初期ページと子メニューの開閉を決める。
        return;
      }
      if (navKind === 'inbox') {
        if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
        if (e.preventDefault) e.preventDefault();
        if (e.stopPropagation) e.stopPropagation();
        if (e.stopImmediatePropagation) e.stopImmediatePropagation();
        navigatePrimaryNav(navKind);
        return;
      }
      if (closestMarked(t, MARK)) {
        if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
        if (e.preventDefault) e.preventDefault();
        if (e.stopPropagation) e.stopPropagation();
        if (e.stopImmediatePropagation) e.stopImmediatePropagation();
        openPanel(DEFAULT_PATH, false);
        return;
      }
      var auxiliaryEntry = closestAttr(t, 'data-toybaco-aux-entry');
      if (auxiliaryEntry) {
        if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
        e.preventDefault(); e.stopPropagation();
        if (e.stopImmediatePropagation) e.stopImmediatePropagation();
        openAuxiliaryView(auxiliaryEntry.getAttribute('data-toybaco-aux-entry'), auxiliaryEntry.getAttribute('data-toybaco-aux-purpose'));
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
      syncPostingStatusScope();
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
      ensureAuxiliaryNavigation(sample);
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
    reconcilePostRenewal();
    if (auxiliaryView) {
      if (auxiliaryAccount === currentAccountId() && auxiliaryRoute === auxiliaryLocation()) return;
      closeAiModePanel();
      closeAuxiliaryView();
    }
    if (panel && hasPostingRouteGuard()) return;
    if (isAssistantHash(window.location.hash || '')) { openAuxiliaryView('ai', null, true); return; }
    var p = currentHashPath();
    // hash が受信箱のルーターに捨てられていても、退避してあれば開く。
    // ログイン前やメイン領域未準備の間は保持し、openPanelのmount成功で消費する。
    if (p === null && !panel && hasPendingPath() && isLoggedInView()) {
      var pending = readPendingPath();
      if (pending !== null) { openPanel(pending, false); return; }
    }
    if (p === null) {
      if (panel && !requestPanelClose(closePanel, function () {
        if (panel) writePostingHistory(postingHash(panelPath), true);
      })) closePanel();
      return;
    }
    if (!panel) { openPanel(p, true); return; }
    // 戻る/進むも補助ナビと同じ保存確認・読み込み・選択表示を使う。
    navigatePostPath(p, true);
  }

  var previousBillingAccount = null;

  function afterNavChange() {
    reconcilePostRenewal();
    if (auxiliaryView && (auxiliaryAccount !== currentAccountId() || auxiliaryRoute !== auxiliaryLocation())) {
      closeAiModePanel();
      closeAuxiliaryView();
    }
    if (panelLayout) panelLayout.update();
    var billingAccount = /\/settings\/contract\/?$/.test(window.location.pathname) ? currentAccountId() : null;
    var leavingBillingAccount = previousBillingAccount;
    previousBillingAccount = billingAccount;
    if (leavingBillingAccount && leavingBillingAccount !== billingAccount && currentAccountId() === leavingBillingAccount) {
      reconcilePostingAccess(leavingBillingAccount, true);
    }
    inject();
    ensurePostingContract();
    if (!panel && (currentHashPath() !== null || isAssistantHash(window.location.hash || '') || hasPendingPath())) {
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
    previousBillingAccount = /\/settings\/contract\/?$/.test(window.location.pathname) ? currentAccountId() : null;
    inject();
    ensurePostingContract();
    hookHistory();
    watchPostingTheme();
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
    window.addEventListener('toybaco:posting-group-toggle', function (event) {
      var detail = event.detail;
      if (!hasPostingRouteGuard() || !detail ||
          typeof detail.proceed !== 'function' || typeof detail.navigates !== 'boolean') return;
      var auxiliaryPosting = auxiliaryPostingDestination();
      var assistant = isAssistantHash(window.location.hash || '');
      closeAuxiliaryView();
      if (auxiliaryPosting || assistant) {
        detail.handled = true;
        if (detail.navigates) { detail.proceed(); return; }
        closePanelToBase();
        if (!detail.preserveExpanded) detail.proceed();
        return;
      }
      if (!panel) return;
      detail.handled = true;
      if (postCloseRequest) return;
      if (detail.navigates) { detail.proceed(); return; }
      var sequence = ++postRouteSequence;
      function proceed() {
        if (sequence !== postRouteSequence) return;
        closePanelToBase();
        if (!detail.preserveExpanded) detail.proceed();
      }
      if (!requestPanelClose(proceed)) proceed();
    });
    window.addEventListener('toybaco:before-route-change', function (event) {
      if (!event.detail || typeof event.detail.proceed !== 'function') return;
      if (!panel) {
        if (event.detail.pushBaseHistory === true && isAssistantHash(window.location.hash || '')) {
          closeAuxiliaryView();
          closePanelToBase();
        }
        return;
      }
      var detail = event.detail;
      var sequence = ++postRouteSequence;
      var destination = null;
      if (typeof detail.to === 'string') {
        try {
          var target = new URL(detail.to, window.location.href);
          if (target.origin === window.location.origin &&
              target.pathname + target.search === panelRouteBase && isPostingHash(target.hash)) {
            var query = new URLSearchParams(target.hash.slice(target.hash.indexOf('?') + 1));
            destination = validatePath(query.get('path') || DEFAULT_PATH);
          }
        } catch (e) { /* native destinations still use the existing close confirmation */ }
      }
      if (destination !== null && destination === panelPath) return;
      function cancel() { if (typeof detail.cancel === 'function') detail.cancel(); }
      if (postCloseRequest) {
        event.preventDefault();
        cancel();
        return;
      }
      function proceed() {
        if (sequence !== postRouteSequence) { cancel(); return; }
        if (destination !== null) navigatePostPath(destination, true);
        else if (detail.pushBaseHistory === true) closePanelToBase();
        else closePanel(detail.preserveHistory === true);
        detail.proceed();
      }
      if (requestPanelClose(proceed, cancel)) {
        event.preventDefault();
      } else {
        proceed();
      }
    });
  } catch (e) { /* start 後の再試行で入口は出す */ }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
