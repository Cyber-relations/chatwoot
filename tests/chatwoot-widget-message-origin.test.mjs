import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const root = path.resolve(process.argv[2] || path.join(import.meta.dirname, '..'));
const source = fs.readFileSync(path.join(root, 'overlay/app/app/javascript/sdk/IFrameHelper.js'), 'utf8');
const moduleBody = source.replace(/^import [\s\S]*? from '[^']+';\n/gm, '').replace('export const IFrameHelper', 'const IFrameHelper');
const target = {};
const sent = [];
const listeners = new Set();
let frame = { src: 'https://app.example.invalid/widget?website_token=public-fixture', contentWindow: target };
const hostHandler = () => {};
const context = {
  URL,
  document: { getElementById: () => frame },
  window: {
    location: { href: 'https://shop.example.invalid/path' },
    onmessage: hostHandler,
    addEventListener: (event, handler) => { assert.equal(event, 'message'); listeners.add(handler); },
    removeEventListener: (event, handler) => { assert.equal(event, 'message'); listeners.delete(handler); },
  },
};
target.postMessage = (...args) => sent.push(args);
vm.runInNewContext(`${moduleBody}\nthis.helper = IFrameHelper;`, context);
const helper = context.helper;
const received = [];
helper.events.accepted = event => received.push(event);
helper.initPostMessageCommunication();
assert.equal(context.window.onmessage, hostHandler, 'Host page message handler must survive');
assert.equal(listeners.size, 1);
const valid = { source: target, origin: 'https://app.example.invalid', data: 'chatwoot-widget:{"event":"accepted","marker":"synthetic"}' };
helper.messageListener(valid);
assert.equal(received.length, 1);
const rejected = [
  { origin: 'https://unrelated.example.invalid' },
  { origin: 'https://app.example.invalid.attacker.invalid' },
  { origin: 'http://app.example.invalid' },
  { origin: 'null' },
  { source: {} },
  { source: null },
  { data: { event: 'accepted' } },
  { data: 'other-channel:{"event":"accepted"}' },
  { data: 'chatwoot-widget:{' },
  { data: 'chatwoot-widget:null' },
  { data: 'chatwoot-widget:[]' },
  { data: 'chatwoot-widget:{"event":"constructor"}' },
  { data: 'chatwoot-widget:{"event":"__proto__"}' },
  { data: 'chatwoot-widget:{"event":7}' },
];
for (const override of rejected) helper.messageListener({ ...valid, ...override });
assert.equal(received.length, 1, 'Untrusted or malformed messages must not invoke widget events');
helper.initPostMessageCommunication();
assert.equal(listeners.size, 1, 'Reset must replace its own listener instead of duplicating handlers');
helper.sendMessage('set-user', { identifier: 'synthetic' });
assert.equal(sent.length, 1);
assert.equal(sent[0][1], 'https://app.example.invalid', 'Private event must use the iframe origin');
for (const invalidFrame of [null, { src: 'data:text/html,fixture', contentWindow: target }, { src: 'https://[invalid', contentWindow: target }]) {
  frame = invalidFrame;
  helper.messageListener(valid);
  helper.sendMessage('set-user', { identifier: 'synthetic' });
}
assert.equal(sent.length, 1);
assert.equal(received.length, 1);
frame = { src: 'https://other-app.example.invalid/widget', contentWindow: target };
helper.messageListener(valid);
assert.equal(received.length, 1, 'Old origin must stop after iframe destination changes');
helper.messageListener({ ...valid, origin: 'https://other-app.example.invalid' });
assert.equal(received.length, 2);
helper.sendMessage('set-user', { identifier: 'synthetic' });
assert.equal(sent[1][1], 'https://other-app.example.invalid');

// (a) createFrame の経路: http の baseUrl は https にしてから iframe.src に入れる(本番の ALB は http→https に
// リダイレクトし、iframe.src は書き換わらないため)。開発ホストの http はそのまま。origin/source の照合は変えない。
const createFrameFixture = ({ baseUrl, cookie }) => {
  const frameWindow = { postMessage: (...args) => frameSent.push(args) };
  const frameSent = [];
  const frameListeners = new Set();
  let appended = null;
  const ctx = {
    URL,
    Cookies: { get: name => (name === 'cw_conversation' ? cookie : undefined) },
    loadCSS: () => {},
    addClasses: () => {},
    isFlatWidgetStyle: () => false,
    widgetHolder: { dataset: {}, appendChild: element => { appended = element; }, addEventListener: () => {} },
    body: { appendChild: () => {} },
    document: {
      createElement: tag => { assert.equal(tag, 'iframe'); return { style: {}, contentWindow: frameWindow }; },
      getElementById: id => { assert.equal(id, 'chatwoot_live_chat_widget'); return appended; },
    },
    window: {
      location: { href: 'https://shop.example.invalid/path' },
      $chatwoot: { position: 'right' },
      addEventListener: (event, handler) => { if (event === 'message') frameListeners.add(handler); },
      removeEventListener: (event, handler) => { if (event === 'message') frameListeners.delete(handler); },
    },
  };
  vm.runInNewContext(`${moduleBody}\nthis.helper = IFrameHelper;`, ctx);
  const frameReceived = [];
  ctx.helper.events.accepted = event => frameReceived.push(event);
  ctx.helper.createFrame({ baseUrl, websiteToken: 'public-fixture' });
  assert.ok(appended, `createFrame must append the iframe for ${baseUrl}`);
  assert.equal(frameListeners.size, 1);
  return { helper: ctx.helper, iframe: appended, frameWindow, frameSent, frameReceived, frameListeners };
};
const redirected = createFrameFixture({ baseUrl: 'http://app.example.invalid' });
assert.equal(redirected.iframe.src, 'https://app.example.invalid/widget?website_token=public-fixture');
const accepted = 'chatwoot-widget:{"event":"accepted","marker":"synthetic"}';
const [frameListener] = redirected.frameListeners;
frameListener({ source: redirected.frameWindow, origin: 'https://app.example.invalid', data: accepted });
assert.equal(redirected.frameReceived.length, 1, 'The https origin after the redirect must be accepted');
frameListener({ source: redirected.frameWindow, origin: 'http://app.example.invalid', data: accepted });
frameListener({ source: {}, origin: 'https://app.example.invalid', data: accepted });
assert.equal(redirected.frameReceived.length, 1, 'Origin and source stay strict after the normalization');
redirected.helper.sendMessage('set-user', { identifier: 'synthetic' });
assert.deepEqual(redirected.frameSent.map(([, origin]) => origin), ['https://app.example.invalid']);
assert.equal(createFrameFixture({ baseUrl: 'http://app.example.invalid', cookie: 'cookie-fixture' }).iframe.src,
  'https://app.example.invalid/widget?website_token=public-fixture&cw_conversation=cookie-fixture');
const srcFor = baseUrl => createFrameFixture({ baseUrl }).iframe.src;
for (const baseUrl of ['http://localhost:3000', 'http://127.0.0.1:3000', 'http://[::1]:3000', 'http://chatwoot.localhost',
  'http://app.toybaco.test', 'https://app.example.invalid', 'https://localhost:3000',
  // DNS ルートの末尾の点、127.0.0.0/8 全体、IPv4 と IPv6 の表記ゆれも開発ホスト。
  'http://localhost.:3000', 'http://app.toybaco.test.', 'http://chatwoot.localhost.', 'http://127.0.0.2:3000',
  'http://127.255.255.254', 'http://127.0.0.2.', 'http://127.1', 'http://[0:0:0:0:0:0:0:1]:3000', 'http://[::0001]', 'http://LOCALHOST']) {
  assert.equal(srcFor(baseUrl), `${baseUrl}/widget?website_token=public-fixture`, `${baseUrl} stays as given`);
}
const localFrame = createFrameFixture({ baseUrl: 'http://localhost:3000' });
[...localFrame.frameListeners][0]({ source: localFrame.frameWindow, origin: 'http://localhost:3000', data: accepted });
assert.equal(localFrame.frameReceived.length, 1, 'A development host keeps its http origin');
// 開発ホストでの往復: http の src のまま、http の origin から受けて http の origin へ送る(https は拒否)。
const testHostFrame = createFrameFixture({ baseUrl: 'http://app.toybaco.test:3000' });
assert.equal(testHostFrame.iframe.src, 'http://app.toybaco.test:3000/widget?website_token=public-fixture');
const [testHostListener] = testHostFrame.frameListeners;
testHostListener({ source: testHostFrame.frameWindow, origin: 'https://app.toybaco.test:3000', data: accepted });
testHostListener({ source: testHostFrame.frameWindow, origin: 'http://app.toybaco.test:3000', data: accepted });
assert.equal(testHostFrame.frameReceived.length, 1, 'Only the http origin of a development host is accepted');
testHostFrame.helper.sendMessage('set-user', { identifier: 'synthetic' });
assert.deepEqual(testHostFrame.frameSent.map(([, origin]) => origin), ['http://app.toybaco.test:3000']);
// 開発ホストに似た名前(接尾辞が点で区切られていないもの)は開発ホストではない。
for (const host of ['localhost.example.invalid', 'notlocalhost', 'app.test.example.invalid', 'apptest', '127.0.0.1.example.invalid',
  '128.0.0.1', '126.0.0.1', 'localhost..', 'test']) {
  assert.equal(srcFor(`http://${host}`), `https://${host}/widget?website_token=public-fixture`, host);
}
// 文字列の置換ではなく parse した URL を serialize する: http の既定の :80 は落ち(ALB は 80→443 へリダイレクトする)、
// 明示の port は残り、scheme 内の制御文字や前後の空白は parser が正規化し、path は保つ。
for (const [baseUrl, expected] of [
  ['http://app.example.invalid:80', 'https://app.example.invalid'],
  ['http://app.example.invalid:80/', 'https://app.example.invalid'],
  ['HTTP://App.Example.invalid', 'https://app.example.invalid'],
  ['http://app.example.invalid:8080', 'https://app.example.invalid:8080'],
  ['http://app.example.invalid:443', 'https://app.example.invalid'],
  ['ht\ttp://app.example.invalid', 'https://app.example.invalid'],
  ['http\n://app.example.invalid', 'https://app.example.invalid'],
  [' http://app.example.invalid ', 'https://app.example.invalid'],
  ['http://app.example.invalid/', 'https://app.example.invalid'],
  ['http://app.example.invalid/chat', 'https://app.example.invalid/chat'],
  ['http://app.example.invalid/chat/', 'https://app.example.invalid/chat'],
]) {
  assert.equal(srcFor(baseUrl), `${expected}/widget?website_token=public-fixture`, JSON.stringify(baseUrl));
}
const explicitPort = createFrameFixture({ baseUrl: 'http://app.example.invalid:80' });
[...explicitPort.frameListeners][0]({ source: explicitPort.frameWindow, origin: 'https://app.example.invalid', data: accepted });
assert.equal(explicitPort.frameReceived.length, 1, 'The https origin is accepted after an explicit :80');
// sdk.js の reset() も IFrameHelper.getUrl で iframe.src を作り直すので、同じ正規化が効く。
assert.equal(helper.getUrl({ baseUrl: 'http://app.example.invalid', websiteToken: 't' }), 'https://app.example.invalid/widget?website_token=t');
// 解釈できない baseUrl は upstream と同じくそのまま。
assert.equal(helper.getUrl({ baseUrl: '', websiteToken: 't' }), '/widget?website_token=t');
assert.equal(helper.getUrl({ baseUrl: '/relative', websiteToken: 't' }), '/relative/widget?website_token=t');

// (b) listener の所有は window に置く。sdk.js を読み直して別の IFrameHelper が init しても、loaded は 1 回だけ処理する。
const sharedWindowListeners = new Set();
const sharedSent = [];
const ready = [];
const sharedTarget = { postMessage: (...args) => sharedSent.push(args) };
const sharedFrame = { src: 'https://app.example.invalid/widget?website_token=public-fixture', contentWindow: sharedTarget, style: {},
  setAttribute: () => {} };
const sharedContext = {
  URL,
  Cookies: { get: () => undefined },
  setCookieWithDomain: () => {},
  initOnEvents: [],
  CHATWOOT_READY: 'chatwoot:ready',
  dispatchWindowEvent: ({ eventName }) => ready.push(eventName),
  document: {
    getElementById: () => sharedFrame,
    getElementsByClassName: name => (name === 'woot--bubble-holder' ? [{}] : []),
    addEventListener: () => {},
  },
  window: {
    location: { href: 'https://shop.example.invalid/path' },
    $chatwoot: { position: 'right' },
    matchMedia: () => ({ matches: false }),
    addEventListener: (event, handler) => { assert.equal(event, 'message'); sharedWindowListeners.add(handler); },
    removeEventListener: (event, handler) => { assert.equal(event, 'message'); sharedWindowListeners.delete(handler); },
  },
};
// 同じ window でモジュール本文を 2 回評価する(sdk.js の再読込)。
vm.runInNewContext(`this.first = (() => {\n${moduleBody}\nreturn IFrameHelper;\n})();\n` +
  `this.second = (() => {\n${moduleBody}\nreturn IFrameHelper;\n})();`, sharedContext);
assert.notEqual(sharedContext.first, sharedContext.second, 'two separate SDK instances');
sharedContext.first.initPostMessageCommunication();
sharedContext.second.initPostMessageCommunication();
assert.equal(sharedWindowListeners.size, 1, 'The second SDK instance must replace the first listener');
assert.equal(sharedContext.window.__toybacoChatwootSdkMessageListener, sharedContext.second.messageListener);
const loaded = `chatwoot-widget:${JSON.stringify({ event: 'loaded', config: { authToken: 'token-fixture', channelConfig: { widgetColor: '#1f93ff' } } })}`;
for (const listener of [...sharedWindowListeners]) listener({ source: sharedTarget, origin: 'https://app.example.invalid', data: loaded });
assert.equal(sharedSent.filter(([data]) => data.startsWith('chatwoot-widget:{"event":"config-set"')).length, 1, 'config-set once');
assert.deepEqual(ready, ['chatwoot:ready'], 'chatwoot:ready once');
assert.ok(sharedSent.every(([, origin]) => origin === 'https://app.example.invalid'));
// 先の instance が init し直しても 1 つのまま(window の listener を外してから登録する)。
sharedContext.first.initPostMessageCommunication();
assert.equal(sharedWindowListeners.size, 1);
assert.equal(sharedContext.window.__toybacoChatwootSdkMessageListener, sharedContext.first.messageListener);
// 入れ替え後も loaded は 1 回だけ処理する。
const configSets = () => sharedSent.filter(([data]) => data.startsWith('chatwoot-widget:{"event":"config-set"')).length;
for (const listener of [...sharedWindowListeners]) listener({ source: sharedTarget, origin: 'https://app.example.invalid', data: loaded });
assert.equal(configSets(), 2, 'config-set once more after the swap back');
assert.deepEqual(ready, ['chatwoot:ready', 'chatwoot:ready'], 'chatwoot:ready once more after the swap back');

console.log('Widget SDK actual receiver: origin/source/format/event boundary, exact outgoing target, reset and host-listener preservation, ' +
  'https iframe src behind the http redirect (development hosts kept), one window-level listener across SDK reloads PASS');
