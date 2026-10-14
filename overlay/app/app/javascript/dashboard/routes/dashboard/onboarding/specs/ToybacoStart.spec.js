import { h, nextTick, ref, watch } from 'vue';
import { flushPromises, mount, RouterLinkStub } from '@vue/test-utils';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  growthGuideErrorStatus,
  refreshGrowthGuide,
  selectGrowthGuideAccount,
} from 'dashboard/composables/toybacoGrowthGuide';
import ToybacoStart from '../ToybacoStart.vue';

const mocks = vi.hoisted(() => ({ accountId: null }));

vi.mock('vue-router', () => ({
  useRoute: () => ({ name: 'toybaco_growth_start' }),
  useRouter: () => ({ push() {} }),
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({ accountId: mocks.accountId }),
}));

vi.mock('dashboard/api/channel/googleClient', () => ({ default: {} }));
vi.mock('dashboard/api/channel/microsoftClient', () => ({ default: {} }));

const UNAVAILABLE =
  'この案内は、無料プランから始めた店舗向けです。この店舗では使えません。';

const response = (status, body = {}) => ({
  status,
  ok: status >= 200 && status < 300,
  redirected: false,
  json: async () => body,
});

const growthState = {
  account_id: 4,
  phase: 'purpose',
  administrator: true,
  inboxes: [],
  connections: { count: 0, limit: null, channels: [] },
  preference: { purpose: null, dismissed: false, skipped: [], opened: [] },
};

// fetch は試験が答えるまで待つ。
let calls;
const fetchStub = (url, options = {}) =>
  new Promise((resolve, reject) => {
    calls.push({ url, method: options.method || 'GET', resolve });
    options.signal?.addEventListener('abort', () =>
      reject(Object.assign(new Error('aborted'), { name: 'AbortError' }))
    );
  });
const guideReads = () =>
  calls.filter(call => call.url.startsWith('/toybaco/growth/onboarding'));

// 途中で落ちた試験の画面が次の試験に残って動かないよう、試験ごとに必ず閉じる。
const wrappers = [];
const track = wrapper => {
  wrappers.push(wrapper);
  return wrapper;
};
afterEach(() => {
  wrappers.splice(0).forEach(wrapper => {
    if (!wrapper.vm.$.isUnmounted) wrapper.unmount();
  });
});

const mountStart = () =>
  track(
    mount(ToybacoStart, { global: { stubs: { RouterLink: RouterLinkStub } } })
  );

describe('ToybacoStart を直接開いたとき', () => {
  beforeEach(() => {
    calls = [];
    vi.stubGlobal('fetch', fetchStub);
    mocks.accountId = ref(4);
    // 上部の案内(ToybacoGrowthGuide)は、無料プランから始めた店舗でない店舗では店舗を選ばない(null)。
    selectGrowthGuideAccount(null);
  });

  afterEach(() => {
    selectGrowthGuideAccount(null);
    vi.unstubAllGlobals();
  });

  it('上部の案内が読んでいない店舗では自分で 1 回読み、読むまで「準備しています…」を出す', async () => {
    const wrapper = mountStart();
    expect(guideReads().map(call => [call.method, call.url])).toEqual([
      ['GET', '/toybaco/growth/onboarding?account_id=4'],
    ]);
    expect(wrapper.text()).toContain('準備しています…');
    wrapper.unmount();
  });

  it('404(案内の対象でない店舗)では対象外の文とホームへのリンクを出し、再読み込みは出さない', async () => {
    const wrapper = mountStart();
    guideReads()[0].resolve(response(404));
    await flushPromises();

    const notice = wrapper.find('[data-toybaco-guide-unavailable]');
    expect(notice.exists()).toBe(true);
    expect(notice.attributes('role')).toBe('status');
    expect(notice.text()).toContain(UNAVAILABLE);
    const link = notice.findComponent(RouterLinkStub);
    expect(link.props('to')).toEqual({
      name: 'home',
      params: { accountId: 4 },
    });
    expect(link.text()).toBe('ホームへ');
    expect(wrapper.find('[role="alert"]').exists()).toBe(false);
    expect(wrapper.text()).not.toContain('再読み込み');
    expect(wrapper.text()).not.toContain('準備しています…');
    expect(wrapper.text()).not.toContain('この店舗の案内を開けません。');
    expect(guideReads()).toHaveLength(1);
    wrapper.unmount();
  });

  it('404 ではヘッダーの「あとで続ける」を出さず、押せるのは「ホームへ」だけにする', async () => {
    const wrapper = mountStart();
    expect(wrapper.find('header').text()).toContain('あとで続ける');
    guideReads()[0].resolve(response(404));
    await flushPromises();

    expect(wrapper.find('header').exists()).toBe(true);
    expect(wrapper.find('header').text()).not.toContain('あとで続ける');
    expect(
      wrapper.findAllComponents(RouterLinkStub).map(link => link.text())
    ).toEqual(['ホームへ']);
    expect(wrapper.findAll('button')).toHaveLength(0);
    expect(calls).toHaveLength(1);
    wrapper.unmount();
  });

  it.each([401, 403])(
    '%i ではこれまでどおり案内を開けない文と再読み込みを出す',
    async status => {
      const wrapper = mountStart();
      guideReads()[0].resolve(response(status));
      await flushPromises();

      expect(wrapper.find('[data-toybaco-guide-unavailable]').exists()).toBe(
        false
      );
      expect(wrapper.find('header').text()).toContain('あとで続ける');
      const alert = wrapper.find('[role="alert"]');
      expect(alert.text()).toContain('この店舗の案内を開けません。');
      await alert.find('button').trigger('click');
      expect(guideReads()).toHaveLength(2);
      wrapper.unmount();
    }
  );

  it('ほかの失敗ではこれまでどおりの文と再読み込みを出す', async () => {
    const wrapper = mountStart();
    guideReads()[0].resolve(response(500));
    await flushPromises();

    expect(wrapper.find('[data-toybaco-guide-unavailable]').exists()).toBe(
      false
    );
    const alert = wrapper.find('[role="alert"]');
    expect(alert.text()).toContain(
      '読み込めませんでした。もう一度お試しください。'
    );
    expect(alert.find('button').text()).toBe('再読み込み');
    wrapper.unmount();
  });

  it('店舗を切り替えたら、切り替えた店舗を読み直す', async () => {
    const wrapper = mountStart();
    guideReads()[0].resolve(response(404));
    await flushPromises();
    expect(wrapper.text()).toContain(UNAVAILABLE);

    mocks.accountId.value = 5;
    await nextTick();
    await flushPromises();
    expect(guideReads().map(call => call.url)).toEqual([
      '/toybaco/growth/onboarding?account_id=4',
      '/toybaco/growth/onboarding?account_id=5',
    ]);
    expect(wrapper.text()).not.toContain(UNAVAILABLE);
    expect(wrapper.text()).toContain('準備しています…');
    guideReads()[1].resolve(response(404));
    await flushPromises();
    expect(wrapper.text()).toContain(UNAVAILABLE);
    wrapper.unmount();
  });

  it('上部の案内が店舗を選ばない(null)に戻しても、画面はその後に店舗を選んで読む', async () => {
    // App.vue と同じく、上部の案内は画面より先に作られ、店舗が変わるたびに(pre で)選び直す。ここでは店舗 4・5 とも
    // 無料プランから始めた店舗でない。
    const WidgetStandIn = {
      setup() {
        watch(
          () => mocks.accountId.value,
          () => selectGrowthGuideAccount(null),
          { immediate: true }
        );
        return () => null;
      },
    };
    const wrapper = track(
      mount(
        { render: () => [h(WidgetStandIn), h(ToybacoStart)] },
        { global: { stubs: { RouterLink: RouterLinkStub } } }
      )
    );
    guideReads()[0].resolve(response(404));
    await flushPromises();
    expect(wrapper.text()).toContain(UNAVAILABLE);

    mocks.accountId.value = 5;
    await flushPromises();
    expect(guideReads().map(call => call.url)).toEqual([
      '/toybaco/growth/onboarding?account_id=4',
      '/toybaco/growth/onboarding?account_id=5',
    ]);
    guideReads()[1].resolve(response(404));
    await flushPromises();
    expect(wrapper.text()).toContain(UNAVAILABLE);
    wrapper.unmount();
  });
});

describe('無料プランから始めた店舗(上部の案内が読む店舗)', () => {
  beforeEach(() => {
    calls = [];
    vi.stubGlobal('fetch', fetchStub);
    mocks.accountId = ref(4);
    // 上部の案内がこの店舗を選んでいる。
    selectGrowthGuideAccount(4);
  });

  afterEach(() => {
    selectGrowthGuideAccount(null);
    vi.unstubAllGlobals();
  });

  it('上部の案内が読み終えていれば、画面は読み直さない', async () => {
    const read = refreshGrowthGuide();
    guideReads()[0].resolve(response(200, growthState));
    await read;

    const wrapper = mountStart();
    await flushPromises();
    expect(guideReads()).toHaveLength(1);
    expect(wrapper.find('h1').text()).toBe('最初に何をしますか');
    expect(wrapper.find('[data-toybaco-guide-unavailable]').exists()).toBe(
      false
    );
    wrapper.unmount();
  });

  it('上部の案内が読み込み中なら、画面は二重に読まずにその結果を出す', async () => {
    refreshGrowthGuide();
    const wrapper = mountStart();
    expect(guideReads()).toHaveLength(1);
    expect(wrapper.text()).toContain('準備しています…');

    guideReads()[0].resolve(response(200, growthState));
    await flushPromises();
    expect(guideReads()).toHaveLength(1);
    expect(wrapper.find('h1').text()).toBe('最初に何をしますか');
    wrapper.unmount();
  });

  it('画面を閉じても、上部の案内の店舗の選択はそのまま残す', async () => {
    const read = refreshGrowthGuide();
    guideReads()[0].resolve(response(200, growthState));
    await read;
    const wrapper = mountStart();
    await flushPromises();
    wrapper.unmount();

    // 上部の案内の 5 秒ごとの読み直しは、これまでどおりこの店舗を読む。
    refreshGrowthGuide();
    expect(guideReads().map(call => call.url)).toEqual([
      '/toybaco/growth/onboarding?account_id=4',
      '/toybaco/growth/onboarding?account_id=4',
    ]);
  });
});

// 上部の案内(ToybacoGrowthGuide)の代役。App.vue と同じく画面より先に作られ、店舗か「無料プランから始めた店舗か」
// (enabled = currentAccount.toybaco_growth_onboarding)が変わるたびに(pre で)、enabled なら店舗を選んで読み、
// そうでなければ店舗を選ばない(null)。
describe('上部の案内と画面の順番がずれたとき', () => {
  let enabled;
  const GuideStandIn = {
    setup() {
      watch(
        [() => mocks.accountId.value, enabled],
        ([id, available]) => {
          selectGrowthGuideAccount(available ? id : null);
          if (available) refreshGrowthGuide();
        },
        { immediate: true }
      );
      return () => null;
    },
  };
  const mountWithGuide = () =>
    track(
      mount(
        { render: () => [h(GuideStandIn), h(ToybacoStart)] },
        { global: { stubs: { RouterLink: RouterLinkStub } } }
      )
    );

  beforeEach(() => {
    calls = [];
    vi.stubGlobal('fetch', fetchStub);
    mocks.accountId = ref(4);
    enabled = ref(true);
    selectGrowthGuideAccount(null);
  });

  afterEach(() => {
    selectGrowthGuideAccount(null);
    vi.unstubAllGlobals();
  });

  it('無料プランの店舗から対象外の店舗に切り替え、上部の案内が 1 tick 遅れて店舗を外しても、画面は読み直して対象外と出す', async () => {
    const wrapper = mountWithGuide();
    guideReads()[0].resolve(response(200, growthState));
    await flushPromises();
    expect(wrapper.find('h1').text()).toBe('最初に何をしますか');

    // この tick では店舗 5 の enabled がまだ true なので、上部の案内が 5 を選んで読み始める。
    mocks.accountId.value = 5;
    await nextTick();
    expect(guideReads().map(call => call.url)).toEqual([
      '/toybaco/growth/onboarding?account_id=4',
      '/toybaco/growth/onboarding?account_id=5',
    ]);
    // 次の tick で enabled が false になり、上部の案内が店舗を外す(読み込みは止まる)。
    enabled.value = false;
    await flushPromises();
    expect(guideReads().map(call => call.url)).toEqual([
      '/toybaco/growth/onboarding?account_id=4',
      '/toybaco/growth/onboarding?account_id=5',
      '/toybaco/growth/onboarding?account_id=5',
    ]);
    guideReads()[2].resolve(response(404));
    await flushPromises();
    expect(wrapper.text()).toContain(UNAVAILABLE);
    expect(wrapper.text()).not.toContain('準備しています…');
    expect(guideReads()).toHaveLength(3);
    wrapper.unmount();
  });

  it('対象外の文を出した後に上部の案内が店舗を外しても(select(null))、読み直さずに対象外の文を出し続ける', async () => {
    enabled.value = false;
    const wrapper = mountWithGuide();
    guideReads()[0].resolve(response(404));
    await flushPromises();
    expect(wrapper.text()).toContain(UNAVAILABLE);

    selectGrowthGuideAccount(null);
    await nextTick();
    expect(wrapper.text()).toContain(UNAVAILABLE);
    expect(wrapper.text()).not.toContain('準備しています…');
    await flushPromises();
    expect(guideReads()).toHaveLength(1);
    expect(wrapper.text()).toContain(UNAVAILABLE);
    expect(wrapper.text()).not.toContain('準備しています…');
    expect(wrapper.find('header').text()).not.toContain('あとで続ける');
    wrapper.unmount();
  });

  it('enabled がまだ true のまま対象外の店舗に切り替え、上部の案内が読んで 404 になった後に店舗を外しても、GET を増やさず文を途切れさせない', async () => {
    const wrapper = mountWithGuide();
    guideReads()[0].resolve(response(200, growthState));
    await flushPromises();
    expect(wrapper.find('h1').text()).toBe('最初に何をしますか');

    // 店舗 5 へ切り替え。enabled の cache はまだ true なので、上部の案内が 5 を選んで読む。
    mocks.accountId.value = 5;
    await nextTick();
    expect(guideReads().map(call => call.url)).toEqual([
      '/toybaco/growth/onboarding?account_id=4',
      '/toybaco/growth/onboarding?account_id=5',
    ]);
    guideReads()[1].resolve(response(404));
    await flushPromises();
    expect(wrapper.text()).toContain(UNAVAILABLE);

    // enabled が false になり、上部の案内が店舗を外す(errorStatus も消える)。
    enabled.value = false;
    await nextTick();
    expect(wrapper.text()).toContain(UNAVAILABLE);
    expect(wrapper.text()).not.toContain('準備しています…');
    await flushPromises();
    expect(guideReads()).toHaveLength(2);
    expect(wrapper.text()).toContain(UNAVAILABLE);
    expect(wrapper.text()).not.toContain('準備しています…');
    wrapper.unmount();
  });

  it('上部の案内が読んだ 404 が届いた直後(await の前)に enabled が false になっても、GET を増やさず対象外の文を出す', async () => {
    const wrapper = mountWithGuide();
    guideReads()[0].resolve(response(200, growthState));
    await flushPromises();
    expect(wrapper.find('h1').text()).toBe('最初に何をしますか');

    // 店舗 5 へ切り替え。enabled の cache はまだ true なので、上部の案内が 5 を選んで読む。
    mocks.accountId.value = 5;
    await nextTick();
    expect(guideReads()).toHaveLength(2);
    // 404 を返したすぐ後、await せずに enabled が false になる(上部の案内の店舗を外す watcher が並ぶ)。
    guideReads()[1].resolve(response(404));
    enabled.value = false;
    await flushPromises();
    expect(guideReads().map(call => call.url)).toEqual([
      '/toybaco/growth/onboarding?account_id=4',
      '/toybaco/growth/onboarding?account_id=5',
    ]);
    expect(wrapper.text()).toContain(UNAVAILABLE);
    expect(wrapper.text()).not.toContain('準備しています…');
    expect(wrapper.find('[role="alert"]').exists()).toBe(false);

    refreshGrowthGuide();
    await flushPromises();
    expect(guideReads()).toHaveLength(2);
    wrapper.unmount();
  });

  it('前の店舗の状態が残ったまま別の店舗の画面を開いても、前の店舗のツアーを出さずにこの店舗を読む', async () => {
    // 店舗 4 の状態がモジュールに残っている(上部の案内はまだ店舗 5 を選び直していない)。
    selectGrowthGuideAccount(4);
    const read = refreshGrowthGuide();
    guideReads()[0].resolve(response(200, growthState));
    await read;

    mocks.accountId = ref(5);
    const wrapper = mountStart();
    expect(wrapper.find('h1').exists()).toBe(false);
    expect(wrapper.text()).toContain('準備しています…');
    expect(guideReads().map(call => call.url)).toEqual([
      '/toybaco/growth/onboarding?account_id=4',
      '/toybaco/growth/onboarding?account_id=5',
    ]);
    guideReads()[1].resolve(response(404));
    await flushPromises();
    expect(wrapper.text()).toContain(UNAVAILABLE);
    wrapper.unmount();
  });

  it('対象外の店舗で画面を閉じたら店舗の選択を返し、その後の読み直しは何も読まない', async () => {
    enabled.value = false;
    const wrapper = mountWithGuide();
    guideReads()[0].resolve(response(404));
    await flushPromises();
    expect(wrapper.text()).toContain(UNAVAILABLE);

    wrapper.unmount();
    refreshGrowthGuide();
    expect(guideReads()).toHaveLength(1);
  });

  it('覚えておいた 404 だけで対象外を出しているときも、画面を閉じたら店舗の選択を返し、その後の読み直しは何も読まない', async () => {
    enabled.value = false;
    const wrapper = mountWithGuide();
    guideReads()[0].resolve(response(404));
    await flushPromises();
    // 上部の案内が店舗を外し(errorStatus も消える)、その後(古い cache で)この店舗をまた選んで読み、500 で失敗する。
    // errorStatus は無く、覚えておいた 404 だけで文を出している。
    selectGrowthGuideAccount(null);
    await flushPromises();
    enabled.value = true;
    await flushPromises();
    expect(guideReads()).toHaveLength(2);
    guideReads()[1].resolve(response(500));
    await flushPromises();
    expect(growthGuideErrorStatus.value).toBeNull();
    expect(wrapper.text()).toContain(UNAVAILABLE);
    expect(wrapper.text()).not.toContain('準備しています…');

    wrapper.unmount();
    refreshGrowthGuide();
    expect(guideReads()).toHaveLength(2);
  });

  it('404 と同じ tick で上部の案内が店舗を外しても、404 を覚えて読み直さない', async () => {
    // enabled の cache が true なので、上部の案内がこの店舗を選んで読む。
    const wrapper = mountWithGuide();
    expect(guideReads()).toHaveLength(1);
    // 404 が届いたその場で enabled が false になる。上部の案内は次の flush で(画面の pre の watcher より先に)店舗を外す。
    const stop = watch(
      growthGuideErrorStatus,
      status => {
        if (status === 404) enabled.value = false;
      },
      { flush: 'sync' }
    );
    guideReads()[0].resolve(response(404));
    await flushPromises();
    stop();
    expect(growthGuideErrorStatus.value).toBeNull();
    expect(wrapper.text()).toContain(UNAVAILABLE);
    expect(wrapper.text()).not.toContain('準備しています…');
    expect(guideReads()).toHaveLength(1);
    wrapper.unmount();
  });

  it('覚えておいた 404 の店舗でも、上部の案内が状態を読めたら状態の表示を優先する', async () => {
    enabled.value = false;
    const wrapper = mountWithGuide();
    guideReads()[0].resolve(response(404));
    await flushPromises();
    selectGrowthGuideAccount(null);
    await flushPromises();
    expect(wrapper.text()).toContain(UNAVAILABLE);

    // 上部の案内がこの店舗を選んで読み、状態が読めた。
    enabled.value = true;
    await flushPromises();
    guideReads()[1].resolve(response(200, growthState));
    await flushPromises();
    expect(wrapper.find('h1').text()).toBe('最初に何をしますか');
    expect(wrapper.text()).not.toContain(UNAVAILABLE);
    wrapper.unmount();
  });
});
