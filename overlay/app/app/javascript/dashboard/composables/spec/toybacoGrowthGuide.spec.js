import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// 案内の状態の composable は店舗・読み込み中の読み取りをモジュールに持つので、試験ごとに読み込み直す。
const load = async () => {
  vi.resetModules();
  return import('dashboard/composables/toybacoGrowthGuide');
};

const response = (status, body = {}) => ({
  status,
  ok: status >= 200 && status < 300,
  redirected: false,
  json: async () => body,
});

// fetch は試験が答えるまで待つ(答える前に店舗を切り替えられるように)。
const pendingFetch = () => {
  const calls = [];
  const fetch = (url, options) =>
    new Promise((resolve, reject) => {
      calls.push({ url, options, resolve, reject });
      options?.signal?.addEventListener('abort', () =>
        reject(Object.assign(new Error('aborted'), { name: 'AbortError' }))
      );
    });
  return { calls, fetch };
};

describe('toybacoGrowthGuide の失敗の status', () => {
  let server;

  beforeEach(() => {
    server = pendingFetch();
    vi.stubGlobal('fetch', server.fetch);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it.each([401, 403, 404])(
    '読み込みが %i なら status を持ち、案内を開けない文を出す',
    async status => {
      const guide = await load();
      guide.selectGrowthGuideAccount(4);
      const read = guide.refreshGrowthGuide();
      expect(server.calls.map(call => call.url)).toEqual([
        '/toybaco/growth/onboarding?account_id=4',
      ]);
      server.calls[0].resolve(response(status));
      await read;
      expect(guide.growthGuideErrorStatus.value).toBe(status);
      expect(guide.growthGuideError.value).toBe('この店舗の案内を開けません。');
      expect(guide.growthGuideState.value).toBeNull();
    }
  );

  // 文はこれまでどおり(通信の失敗は fetch の文のまま)。status だけが付かない。
  it.each([
    [
      '500',
      call => call.resolve(response(500)),
      '読み込めませんでした。もう一度お試しください。',
    ],
    [
      'リダイレクト',
      call => call.resolve({ ...response(200), redirected: true }),
      '読み込めませんでした。もう一度お試しください。',
    ],
    [
      '通信の失敗',
      call => call.reject(new TypeError('Failed to fetch')),
      'Failed to fetch',
    ],
  ])('ほかの失敗(%s)では status を持たない', async (_name, answer, text) => {
    const guide = await load();
    guide.selectGrowthGuideAccount(4);
    const read = guide.refreshGrowthGuide();
    answer(server.calls[0]);
    await read;
    expect(guide.growthGuideErrorStatus.value).toBeNull();
    expect(guide.growthGuideError.value).toBe(text);
  });

  it('404 の後に別の失敗をしたら status を消し、読めたら文も status も消す', async () => {
    const guide = await load();
    guide.selectGrowthGuideAccount(4);
    let read = guide.refreshGrowthGuide();
    server.calls[0].resolve(response(404));
    await read;
    expect(guide.growthGuideErrorStatus.value).toBe(404);

    read = guide.refreshGrowthGuide();
    server.calls[1].resolve(response(500));
    await read;
    expect(guide.growthGuideErrorStatus.value).toBeNull();
    expect(guide.growthGuideError.value).toBe(
      '読み込めませんでした。もう一度お試しください。'
    );

    read = guide.refreshGrowthGuide();
    server.calls[2].resolve(response(404));
    await read;
    expect(guide.growthGuideErrorStatus.value).toBe(404);

    read = guide.refreshGrowthGuide();
    server.calls[3].resolve(response(200, { account_id: 4, phase: 'purpose' }));
    await read;
    expect(guide.growthGuideErrorStatus.value).toBeNull();
    expect(guide.growthGuideError.value).toBe('');
    expect(guide.growthGuideState.value).toEqual({
      account_id: 4,
      phase: 'purpose',
    });
  });

  it('保存(PUT)の失敗も同じ status を持つ', async () => {
    const guide = await load();
    guide.selectGrowthGuideAccount(4);
    let saved = guide.updateGrowthGuide({ dismissed: true });
    expect(server.calls[0].options.method).toBe('PUT');
    server.calls[0].resolve(response(404));
    await saved;
    expect(guide.growthGuideErrorStatus.value).toBe(404);

    saved = guide.updateGrowthGuide({ dismissed: true });
    server.calls[1].resolve(
      response(422, { error: '操作を確認してください。' })
    );
    await saved;
    expect(guide.growthGuideErrorStatus.value).toBeNull();
    expect(guide.growthGuideError.value).toBe(
      '読み込めませんでした。もう一度お試しください。'
    );
  });

  it('店舗を選び直すと status を消し、前の店舗への応答では status を付けない', async () => {
    const guide = await load();
    guide.selectGrowthGuideAccount(4);
    let read = guide.refreshGrowthGuide();
    server.calls[0].resolve(response(404));
    await read;
    expect(guide.growthGuideErrorStatus.value).toBe(404);

    guide.selectGrowthGuideAccount(5);
    expect(guide.growthGuideErrorStatus.value).toBeNull();
    expect(guide.growthGuideError.value).toBe('');

    // 読み込み中に店舗を切り替えた: 前の読み込みは止まり、何も付けない。
    read = guide.refreshGrowthGuide();
    guide.selectGrowthGuideAccount(6);
    await read;
    server.calls[1].resolve(response(404));
    await Promise.resolve();
    expect(guide.growthGuideErrorStatus.value).toBeNull();
    expect(guide.growthGuideError.value).toBe('');
  });

  it('選んでいる店舗を growthGuideAccount で示し、選び直すと前の店舗の状態を消す', async () => {
    const guide = await load();
    expect(guide.growthGuideAccount.value).toBeNull();
    guide.selectGrowthGuideAccount(4);
    expect(guide.growthGuideAccount.value).toBe('4');
    const read = guide.refreshGrowthGuide();
    server.calls[0].resolve(response(200, { account_id: 4, phase: 'purpose' }));
    await read;
    expect(guide.growthGuideState.value.account_id).toBe(4);

    guide.selectGrowthGuideAccount(5);
    expect(guide.growthGuideAccount.value).toBe('5');
    expect(guide.growthGuideState.value).toBeNull();
    guide.selectGrowthGuideAccount(null);
    expect(guide.growthGuideAccount.value).toBeNull();
  });

  // 応答を確かめてから refreshGrowthGuide の catch に届くまでには microtask 1 つ分の隙間があり、その間に上部の案内の
  // watcher(Vue の flush も microtask)が店舗を外すことがある。401・403・404 はその前に出ていなければならない。
  it.each([401, 403, 404])(
    '%i の応答は、店舗が同じなら catch に届く前(同期)に growthGuideErrorStatus と growthGuideError に出る',
    async status => {
      const guide = await load();
      guide.selectGrowthGuideAccount(4);
      const read = guide.refreshGrowthGuide();
      let seen;
      server.calls[0].resolve(response(status));
      // 応答の続き(request の検証)の直後、catch より先に動く microtask で店舗を外す。
      queueMicrotask(() => {
        seen = [
          guide.growthGuideErrorStatus.value,
          guide.growthGuideError.value,
        ];
        guide.selectGrowthGuideAccount(null);
      });
      await read;
      expect(seen).toEqual([status, 'この店舗の案内を開けません。']);
      // 店舗を外したので消え、遅れて届いた catch は書き戻さない。
      expect(guide.growthGuideErrorStatus.value).toBeNull();
      expect(guide.growthGuideError.value).toBe('');
    }
  );

  // 保存(PUT)は止められないので、店舗を選び直した後に前の店舗の応答が届くことがある。
  it.each([401, 403, 404])(
    '店舗を選び直した後に届いた前の店舗の保存の %i は、status も文も出さない',
    async status => {
      const guide = await load();
      guide.selectGrowthGuideAccount(4);
      const saved = guide.updateGrowthGuide({ dismissed: true });
      guide.selectGrowthGuideAccount(5);
      server.calls[0].resolve(response(status));
      await saved;
      expect(guide.growthGuideErrorStatus.value).toBeNull();
      expect(guide.growthGuideError.value).toBe('');
    }
  );

  it('読み込み中は二重に読まず、店舗が無ければ読まない', async () => {
    const guide = await load();
    await guide.refreshGrowthGuide();
    expect(server.calls).toHaveLength(0);

    guide.selectGrowthGuideAccount(4);
    const read = guide.refreshGrowthGuide();
    guide.refreshGrowthGuide();
    expect(server.calls).toHaveLength(1);
    server.calls[0].resolve(response(404));
    await read;
    expect(guide.growthGuideErrorStatus.value).toBe(404);
  });
});
