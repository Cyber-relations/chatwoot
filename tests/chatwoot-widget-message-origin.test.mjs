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
console.log('Widget SDK actual receiver: origin/source/format/event boundary, exact outgoing target, reset and host-listener preservation PASS');
