// A support reply selects an existing article; it cannot supply navigation code.
export function createSupportQuestion({ context, change, request = fetch, timers = globalThis }) {
  let epoch = 0;
  let controller;
  let slowTimer;
  let deadline;
  let running = false;

  function cancel() {
    epoch += 1;
    controller?.abort();
    timers.clearTimeout(slowTimer);
    timers.clearTimeout(deadline);
    running = false;
    change({ busy: false, slow: false });
  }

  async function ask(question) {
    const current = context();
    if (running || !current.enabled || typeof question !== 'string' || !question.trim()) return;
    cancel();
    const attempt = epoch;
    controller = new AbortController();
    const requestController = controller;
    running = true;
    let timedOut = false;
    change({ busy: true, slow: false, error: '', retryAt: null, article: null });
    slowTimer = timers.setTimeout(() => { if (attempt === epoch) change({ slow: true }); }, 10000);
    deadline = timers.setTimeout(() => {
      if (attempt !== epoch) return;
      timedOut = true;
      requestController.abort();
    }, 60000);
    try {
      const response = await request('/toybaco/support', {
        method: 'POST', credentials: 'same-origin', cache: 'no-store',
        headers: { 'Content-Type': 'application/json' }, signal: requestController.signal,
        body: JSON.stringify({ account_id: current.accountId, support_question: question.trim() }),
      });
      const data = await response.json();
      const latest = context();
      if (attempt !== epoch || current.accountId !== latest.accountId || !latest.enabled) return;
      if (!response.ok) {
        const message = typeof data.error === 'string' && data.error.length < 180
          ? data.error : 'AIを利用できません。手順から確認してください。';
        const retry = response.status === 429 && Number.isInteger(data.retry_after) && data.retry_after > 0 && data.retry_after <= 3600
          ? Date.now() + data.retry_after * 1000 : null;
        change({ error: message, retryAt: retry });
        return;
      }
      if (data.version !== current.version || String(data.account_id) !== current.accountId)
        throw new Error('support context changed');
      const article = latest.articles.find(item => item.id === data.article?.id);
      change(article ? { article } : { error: '合う手順を特定できませんでした。下の項目から選んでください。' });
    } catch (error) {
      if (attempt === epoch && (timedOut || error.name !== 'AbortError'))
        change({ error: 'AIの確認を終えられませんでした。手順の検索は続けられます。' });
    } finally {
      if (attempt === epoch) {
        timers.clearTimeout(slowTimer);
        timers.clearTimeout(deadline);
        running = false;
        change({ busy: false, slow: false });
      }
    }
  }
  return { ask, cancel };
}

export function createSupportDiagnostics({ context, change, request = fetch, timers = globalThis }) {
  let epoch = 0;
  let controller;
  let deadline;
  function cancel() {
    epoch += 1;
    controller?.abort();
    timers.clearTimeout(deadline);
    change({ busy: false, checks: [], error: '' });
  }
  async function inspect() {
    const current = context();
    if (!current.enabled || !current.articleId) return;
    cancel();
    const attempt = epoch;
    const pending = new AbortController();
    controller = pending;
    let timedOut = false;
    change({ busy: true });
    deadline = timers.setTimeout(() => { timedOut = true; pending.abort(); }, 15000);
    try {
      const query = new URLSearchParams({ account_id: current.accountId, article_id: current.articleId });
      const response = await request(`/toybaco/support/diagnostics?${query}`, {
        credentials: 'same-origin', cache: 'no-store', signal: pending.signal,
      });
      const data = await response.json();
      const latest = context();
      if (attempt !== epoch || current.accountId !== latest.accountId || current.articleId !== latest.articleId || !latest.enabled) return;
      if (!response.ok || data.version !== current.version || String(data.account_id) !== current.accountId || data.article_id !== current.articleId)
        throw new Error('diagnostic unavailable');
      const valid = Array.isArray(data.checks) && data.checks.length > 0 && data.checks.length <= 3 && data.checks.every(row =>
        ['account', 'inboxes', 'line', 'mail', 'facts', 'billing'].includes(row.id) &&
        ['ok', 'attention', 'information', 'unknown'].includes(row.state) && typeof row.text === 'string' && row.text.length <= 180);
      if (!valid) throw new Error('invalid diagnostic result');
      change({ checks: data.checks });
    } catch (error) {
      if (attempt === epoch && (timedOut || error.name !== 'AbortError'))
        change({ error: '状況を確認できませんでした。手順から確認してください。' });
    } finally {
      if (attempt === epoch) { timers.clearTimeout(deadline); change({ busy: false }); }
    }
  }
  return { inspect, cancel };
}

const SUPPORT_GUIDES = {
  reply: ['reply.editor', 'ここに返信を入力してください。'],
  ai: ['reply.ai_draft', 'AIの下書きを返信欄で確認できます。'],
  facts: ['facts.confirm', 'お店情報を確認して保存してください。'],
  gmail: ['connection.google', 'Googleのアカウントを選んで接続します。'],
  microsoft: ['connection.microsoft', 'Microsoftのアカウントを選んで接続します。'],
  line: ['connection.line', 'LINE公式の接続設定を開きます。'],
  posting: ['posting.open', '投稿画面を開きます。'],
};
export const supportGuideArticles = () => Object.keys(SUPPORT_GUIDES);
export const supportGuideStep = id => Object.prototype.hasOwnProperty.call(SUPPORT_GUIDES, id) ? [...SUPPORT_GUIDES[id]] : null;
