import { ref } from 'vue';

export const growthGuideState = ref(null);
export const growthGuideError = ref('');
export const growthGuideBusy = ref(false);
let accountId = null;
let epoch = 0;
let pendingRead = null;

export function selectGrowthGuideAccount(id) {
  if (String(id || '') === String(accountId || '')) return;
  accountId = id ? String(id) : null;
  epoch += 1;
  pendingRead?.abort();
  pendingRead = null;
  growthGuideState.value = null;
  growthGuideError.value = '';
  growthGuideBusy.value = false;
}

async function request(path, method, body, signal) {
  if (!accountId) return null;
  const selectedEpoch = epoch;
  const response = await fetch(
    `${path}?account_id=${encodeURIComponent(accountId)}`,
    {
      method,
      signal,
      credentials: 'same-origin',
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
    }
  );
  if (selectedEpoch !== epoch) return null;
  if ([401, 403, 404].includes(response.status)) {
    growthGuideState.value = null;
    throw new Error('この店舗の案内を開けません。');
  }
  if (!response.ok || response.redirected)
    throw new Error('読み込めませんでした。もう一度お試しください。');
  const data = await response.json();
  if (selectedEpoch !== epoch || String(data.account_id) !== accountId)
    return null;
  growthGuideState.value = data;
  growthGuideError.value = '';
  return data;
}

export async function refreshGrowthGuide() {
  if (!accountId || pendingRead || growthGuideBusy.value) return;
  const controller = new AbortController();
  const selectedEpoch = epoch;
  pendingRead = controller;
  try {
    return await request(
      '/toybaco/growth/onboarding',
      'GET',
      null,
      controller.signal
    );
  } catch (error) {
    if (selectedEpoch === epoch && error.name !== 'AbortError')
      growthGuideError.value = error.message;
  } finally {
    if (pendingRead === controller) pendingRead = null;
  }
}

async function update(path, body) {
  if (!accountId || growthGuideBusy.value) return;
  epoch += 1;
  pendingRead?.abort();
  pendingRead = null;
  const selectedEpoch = epoch;
  growthGuideBusy.value = true;
  try {
    return await request(path, 'PUT', body);
  } catch (error) {
    if (selectedEpoch === epoch) growthGuideError.value = error.message;
  } finally {
    if (selectedEpoch === epoch) growthGuideBusy.value = false;
  }
}

export const updateGrowthGuide = (preference) =>
  update('/toybaco/growth/onboarding', { preference });

// 会話画面の AI 応答パネル(注入 JS)は取得済みの AI 利用状況を持ち続ける。店舗情報を保存できたら
// その店舗を知らせて、「店舗情報を確認すると自動応答を設定できます。」を取り直してもらう。
export async function saveGrowthFacts(fields) {
  const savedAccountId = accountId;
  const data = await update('/toybaco/growth/facts', {
    fields,
    confirmed: true,
  });
  if (data && savedAccountId)
    window.dispatchEvent(
      new CustomEvent('toybaco:store-facts-saved', {
        detail: { accountId: savedAccountId },
      })
    );
  return data;
}

// 段 1a(2026-10-06 owner 裁定): 初回ツアーは本物の管理画面の上で、スポットライトとカードで案内する。カードに出す内容は
// サーバーの値(この案内の phase・inboxes・facts・pending・administrator と、/toybaco/ai_readiness の inboxes・
// managed_auto_path)だけで決める。DOM や SPA の API からは推定しない(的を光らせるかどうかは、的が今の画面にあるかで決める)。
const TOUR_STEPS = {
  inbox: ['facts', 'connect', 'receive', 'decide'],
  posting: ['facts', 'posting', 'connect'],
};
// 受信の確認と最初の返信は、カードでは 1 つの段(お客さん役で試す)として数える。
const TOUR_SAME_STEP = { reply: 'receive' };
const AI_REPLY_LABELS = { off: 'オフ', draft: '下書き', auto: '自動' };
// 受信の段の文は、案内の画面(ToybacoStart の受信の段)と同じ。メールの窓口(gmail・microsoft・email)は同じ文で、
// 知らない媒体には窓口の種類を言わない文を出す。
const RECEIVE_MAIL =
  '別のメールアドレスから、次の窓口にテストメールを送ってください。';
const RECEIVE_BODIES = {
  line: 'ご自身のLINEから、この公式アカウントにメッセージを送ってください。',
  web_widget:
    'サイトに設置コードを貼ると問い合わせが届きます。今すぐ試すなら、プレビューから1件送ってください。',
  instagram:
    '接続したInstagramのDMを受け取ります。テスト用に1件送ってください。',
  gmail: RECEIVE_MAIL,
  microsoft: RECEIVE_MAIL,
  email: RECEIVE_MAIL,
};
const RECEIVE_ANY = 'この窓口へ一言送ってみてください。';
// 返信の段は、案内した会話の画面でだけ、これまでの 3 段の案内をカードの本文に出して、その操作を光らせる
// (ToybacoGrowthGuide)。ほかの画面のカードは「開いて返信する」だけで、何も光らせない。
export const GROWTH_TOUR_REPLY_HINTS = {
  'reply.ai_draft': 'AIの返信案を返信欄で確認できます。',
  'reply.editor': 'ここに返信を入力してください。',
  'reply.send': '宛先と内容を確認して送信してください。',
};

export function growthTourProgress(state) {
  const steps = TOUR_STEPS[state?.preference?.purpose];
  if (!steps) return null;
  const index = steps.indexOf(TOUR_SAME_STEP[state.phase] || state.phase);
  return index < 0 ? null : { index: index + 1, total: steps.length };
}

// 段 decide の 1 行: 案内した窓口の AI返信の状態を、readiness が返した値のまま出す(例「この窓口：AI返信 オフ」)。
// 文は返信欄の上の 1 行(toybaco-post-entry.js)と同じ。
export function growthDecideLine(readiness, inboxId) {
  const rows = Array.isArray(readiness?.inboxes) ? readiness.inboxes : [];
  const row = rows.find(inbox => String(inbox?.id) === String(inboxId));
  if (!row || !AI_REPLY_LABELS[row.status]) return null;
  return {
    text:
      row.quota_used === true
        ? 'この窓口：AI返信 停止中（今月の枠なし）'
        : `この窓口：AI返信 ${AI_REPLY_LABELS[row.status]}`,
    reason: typeof row.reason === 'string' ? row.reason : '',
  };
}

// 窓口の自動応答の登録ページ(Rails の単独ページ)。readiness がこの店舗の画面を返したときだけ使う。
export function growthAutoReplyPath(readiness, accountId) {
  const path = `/toybaco/growth/automatic-replies?account_id=${encodeURIComponent(accountId)}`;
  return readiness?.managed_auto_path === path ? path : null;
}

function guidedInbox(state) {
  return (state.inboxes || []).find(
    inbox => String(inbox.id) === String(state.inbox_id)
  );
}

// カード 1 枚分の中身。actions の id は ToybacoGrowthGuide が実行する(画面の移動・設定の保存)。targets は光らせる的の候補で、
// 今の画面にある先頭の 1 つだけを光らせる。readiness は /toybaco/ai_readiness の応答(まだ読んでいなければ null、
// 読めなかったときは false)。
export function growthTourCard(state, readiness, accountId) {
  if (!state) return null;
  const progress = growthTourProgress(state);
  const card = {
    phase: state.phase,
    progress: progress
      ? `お店の準備 ${progress.index} / ${progress.total}`
      : '',
    body: [],
    note: '',
    list: [],
    actions: [],
    targets: [],
  };
  const admin = Boolean(state.administrator);
  const skip = (label = 'あとで設定する') => ({
    id: `skip:${state.phase}`,
    label,
    kind: 'secondary',
  });
  if (state.phase === 'purpose') {
    card.title = '最初に何をしますか';
    card.body = ['使い始める仕事を選ぶと、お店の準備を順に案内します。'];
    card.actions = [
      { id: 'purpose:inbox', label: '問い合わせに対応する', kind: 'primary' },
      {
        id: 'purpose:posting',
        label: 'お店の情報を発信する',
        kind: 'secondary',
      },
    ];
  } else if (state.phase === 'facts') {
    card.title = 'AIにお店を教える';
    card.body = [
      '店舗情報を保存すると、AI返信は お店の事実だけを根拠に返信案を作ります。',
      '分かるところだけで大丈夫です。',
    ];
    if (admin) {
      card.actions = [
        { id: 'open:facts', label: '店舗情報を開く', kind: 'primary' },
        skip(),
      ];
      card.targets = ['facts.confirm', 'sidebar.store_facts'];
    } else {
      card.note = '店舗情報は、店舗の管理者が入力・確認します。';
      card.actions = [skip()];
    }
  } else if (state.phase === 'connect') {
    card.title = '窓口をつなぐ';
    card.body = [
      'お客さまのメッセージが届く窓口(LINE・Webチャット・メール・Instagram)をつなぎます。',
      'あとから追加もできます。',
    ];
    if (admin) {
      card.actions = [
        { id: 'open:inbox_new', label: '窓口を追加する', kind: 'primary' },
      ];
      // つないだ窓口がもうあるのに段が残るのは、案内する窓口を 1 つに決められないとき(複数ある)。
      if ((state.inboxes || []).length)
        card.actions.push({
          id: 'proceed:connect',
          label: 'つないだ窓口で次へ',
          kind: 'secondary',
        });
      card.actions.push(skip());
      card.targets = [
        'channel.line',
        'channel.website',
        'channel.email',
        'channel.instagram',
        'sidebar.inboxes',
      ];
    } else {
      card.note = '窓口の接続は、店舗の管理者が行います。';
      card.actions = [skip()];
    }
  } else if (state.phase === 'receive') {
    const inbox = guidedInbox(state);
    card.title = 'お客さん役で試す';
    card.body = [
      Object.prototype.hasOwnProperty.call(RECEIVE_BODIES, inbox?.provider)
        ? RECEIVE_BODIES[inbox.provider]
        : RECEIVE_ANY,
    ];
    const mailbox = inbox?.label || inbox?.email;
    if (mailbox) card.body.push(mailbox);
    card.body.push('届いたら、自動で次の案内に進みます。');
    if (inbox?.provider === 'web_widget' && inbox.website_token)
      card.actions.push({
        id: 'open:widget_preview',
        label: 'プレビューで送る',
        kind: 'primary',
        href: `/widget?website_token=${encodeURIComponent(inbox.website_token)}`,
      });
    card.actions.push(skip());
  } else if (state.phase === 'reply') {
    card.title = 'お客さん役で試す';
    card.body = [
      'メッセージが届きました。AIの返信案を使って、最初の返信を送ってみましょう。',
    ];
    card.actions = [
      { id: 'open:conversation', label: '開いて返信する', kind: 'primary' },
      skip(),
    ];
  } else if (state.phase === 'decide') {
    card.title = 'この窓口の AI返信を決める';
    if (admin) {
      const line = growthDecideLine(readiness, state.inbox_id);
      if (line)
        card.body = line.reason ? [line.text, line.reason] : [line.text];
      else if (readiness === false)
        card.body = ['AI返信の状態を読み込めませんでした。'];
      const autoPath = growthAutoReplyPath(readiness, accountId);
      if (!state.facts?.confirmed)
        card.actions.push({
          id: 'open:facts',
          label: '店舗情報を開く',
          kind: 'primary',
        });
      else if (autoPath)
        card.actions.push({
          id: 'open:managed_auto',
          label: '自動で返す',
          kind: 'primary',
          href: autoPath,
        });
      card.actions.push({
        id: 'choose:draft_only',
        label: 'まずは返信案だけ使う',
        kind: card.actions.length ? 'secondary' : 'primary',
      });
      if (!state.facts?.confirmed)
        card.note = '自動で返すには、先に店舗情報の確認が要ります。';
    } else {
      card.note = 'AI返信の使い方は、店舗の管理者が決めます。';
      card.actions = [skip()];
    }
  } else if (state.phase === 'posting') {
    card.title = '投稿の準備';
    card.body = ['投稿先をつないで、最初の投稿を準備します。'];
    card.actions = [
      { id: 'open:posting', label: '投稿画面を開く', kind: 'primary' },
      skip(),
    ];
  } else if (state.phase === 'complete') {
    card.title = 'お店の準備ができました';
    const pending = { facts: '店舗情報の入力', connect: '窓口の接続' };
    card.list = (state.pending || [])
      .filter(step => pending[step])
      .map(step => pending[step]);
    if (card.list.length)
      card.body = ['残っている準備は、設定メニューからいつでも行えます。'];
    card.actions = [
      { id: 'close', label: '初回案内を閉じる', kind: 'primary' },
    ];
  } else return null;
  return card;
}
