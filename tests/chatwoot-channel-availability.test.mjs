import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { test } from 'node:test';
import vm from 'node:vm';

const root = process.env.TOYBACO_SOURCE_ROOT || resolve(import.meta.dirname, '..');
const dashboard = 'overlay/app/app/javascript/dashboard';
const source = path => readFileSync(resolve(root, dashboard, path), 'utf8');
const imports = /^import[\s\S]*?;\n/gm;
const policy = source('helper/channelAvailability.js').replace('export const', 'const');

function context(switches) {
  const sandbox = { window: { chatwootConfig: { toybacoChannels: switches } } };
  vm.createContext(sandbox);
  vm.runInContext(`${policy}\nthis.available = isToybacoChannelAvailable;`, sandbox);
  return sandbox;
}

test('product switches are independent and fail closed for missing or string config', () => {
  for (const switches of [undefined, {}, { sms: 'true', whatsapp: 'true', twitter: 'true' }]) {
    const { available } = context(switches);
    for (const type of ['sms', 'twilio', 'voice', 'whatsapp', 'whatsapp_call', 'twitter', 'twitter_profile']) assert.equal(available(type), false);
    for (const type of ['line', 'email', 'api', 'website', 'instagram', 'facebook', 'telegram', 'tiktok']) {
      assert.equal(available(type), true);
    }
  }
  assert.equal(context({ sms: true }).available('sms'), true);
  assert.equal(context({ sms: true }).available('whatsapp'), false);
  assert.equal(context({ whatsapp: true }).available('whatsapp'), true);
  assert.equal(context({ whatsapp: true }).available('sms'), false);
  assert.equal(context({ twitter: true }).available('twitter'), true);
  assert.equal(context({ twitter: true }).available('sms'), false);
  assert.equal(context({ sms: true }).available('twitter'), false);
});

test('settings list and click handler refuse unoffered channels even with account features enabled', () => {
  const sandbox = context({ sms: false, whatsapp: false });
  const navigations = [];
  Object.assign(sandbox, {
    computed: fn => ({ get value() { return fn(); } }),
    useI18n: () => ({ t: key => key }),
    useRouter: () => ({ push: value => navigations.push(value) }),
    useMapGetter: () => ({ value: {} }),
    useAccount: () => ({ accountId: { value: 1 }, currentAccount: { value: { features: { channel_voice: true } } }, isOnChatwootCloud: { value: false } }),
  });
  const script = source('routes/dashboard/settings/inbox/ChannelList.vue').split('<script setup>')[1].split('</script>')[0];
  vm.runInContext(`${script.replace(imports, '')}\nthis.list = channelList; this.click = initChannelAuth;`, sandbox);
  const keys = Array.from(sandbox.list.value, channel => channel.key);
  for (const type of ['sms', 'whatsapp', 'voice', 'whatsapp_call', 'twitter']) {
    assert.equal(keys.includes(type), false, type);
    sandbox.click(type);
  }
  assert.equal(navigations.length, 0);
  sandbox.click('line');
  assert.equal(navigations.length, 1);
  assert.equal(navigations[0].params.sub_page, 'line');
});

test('onboarding defaults, catalog, previews and detected social entries exclude disabled channels', () => {
  const sandbox = context({ sms: false, whatsapp: false });
  sandbox.CHANNEL_TYPES = Object.fromEntries(['website', 'whatsapp', 'facebook', 'instagram', 'telegram', 'line'].map(x => [x.toUpperCase(), x]));
  const script = source('routes/dashboard/onboarding/inbox-setup/constants.js').replace(imports, '').replaceAll('export const', 'const');
  vm.runInContext(`${script}\nthis.result = { DEFAULT_CHANNEL_TYPES, CHANNEL_LIST, FALLBACK_PREVIEW_CHANNELS, SOCIAL_PLATFORMS };`, sandbox);
  const result = sandbox.result;
  for (const type of ['sms', 'whatsapp', 'voice']) {
    assert.equal(result.DEFAULT_CHANNEL_TYPES.includes(type), false);
    assert.equal(result.CHANNEL_LIST.some(channel => channel.type === type), false);
    assert.equal(result.FALLBACK_PREVIEW_CHANNELS.some(channel => channel.type === type), false);
    assert.equal(Object.hasOwn(result.SOCIAL_PLATFORMS, type), false);
  }
  assert.equal(Object.hasOwn(result.SOCIAL_PLATFORMS, 'line'), true);
});

test('onboarding refuses the embedded signup popup before invoking the SDK', async () => {
  const sandbox = context({ whatsapp: false });
  let calls = 0;
  Object.assign(sandbox, {
    useI18n: () => ({ t: value => value }),
    useStore: () => ({ dispatch: () => { throw new Error('unexpected API call'); } }),
    useAccount: () => ({ isMetaInboxCreationDisabled: { value: false } }),
    useWhatsappEmbeddedSignup: () => ({ runEmbeddedSignup: () => { calls += 1; return null; } }),
    googleClient: {}, microsoftClient: {}, instagramClient: {}, tiktokClient: {},
  });
  const script = source('routes/dashboard/onboarding/inbox-setup/useChannelConnect.js').replace(imports, '').replace('export function', 'function');
  vm.runInContext(`${script}\nthis.connect = useChannelConnect().connectWhatsapp;`, sandbox);
  await sandbox.connect();
  assert.equal(calls, 0);
});
