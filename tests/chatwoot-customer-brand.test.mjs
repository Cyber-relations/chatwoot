import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import vm from 'node:vm';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const app = resolve(root, 'overlay/app');
const read = path => readFileSync(resolve(app, path), 'utf8');
const profile = read('app/javascript/dashboard/components-next/sidebar/SidebarProfileMenu.vue');

function profileMenu(type, supportEnabled = false) {
  const events = [];
  const start = profile.indexOf('const menuItems = computed');
  const end = profile.indexOf('</script>', start);
  assert.ok(start > 0 && end > start);
  const items = vm.runInNewContext(`${profile.slice(start, end)}; allowedMenuItems.value`, {
    computed: fn => ({ value: fn() }),
    currentUser: { value: { type } },
    currentAccount: { value: { toybaco_support: supportEnabled } },
    window: { dispatchEvent: event => events.push(event.type) },
    Event,
    t: key => key,
    emit: event => events.push(event),
    Auth: { logout: () => events.push('logout') },
    document: { querySelector: () => ({ open: value => events.push(value.parent) }) },
  });
  return { items, events };
}

test('all customer roles retain help, support and update links within Toybaco', () => {
  for (const type of ['User', 'Administrator', 'SuperAdmin']) {
    const { items } = profileMenu(type);
    for (const [key, link] of [
      ['CONTACT_SUPPORT', 'mailto:support@toybaco.jp'],
      ['DOCS', '/toybaco-help.html'],
      ['CHANGELOG', '/toybaco-help.html#updates'],
    ]) {
      const item = items.find(item => item.label === `SIDEBAR_ITEMS.${key}`);
      assert.ok(item?.show && item.showOnCustomBrandedInstance, `${type}: ${key}`);
      assert.equal(item.link, link);
      assert.equal(item.nativeLink, true);
    }
    assert.equal(items.some(item => item.link === '/super_admin'), type === 'SuperAdmin');
  }
});

test('in-product support is available only when released and opens beside the current work', () => {
  assert.equal(profileMenu('User').items.some(item => item.label === '使い方を調べる'), false);
  const { items, events } = profileMenu('User', true);
  const support = items.find(item => item.label === '使い方を調べる');
  assert.equal(items.some(item => item.link?.startsWith?.('mailto:')), false);
  assert.equal(support.link, undefined);
  support.click();
  assert.deepEqual(events, ['close', 'toybaco:open-support']);
});

test('every released role starts with self service without a direct email shortcut', () => {
  for (const type of ['User', 'Administrator', 'SuperAdmin']) {
    const { items } = profileMenu(type, true);
    assert.equal(items.filter(item => item.label === '使い方を調べる').length, 1);
    assert.equal(items.some(item => typeof item.link === 'string' && item.link.startsWith('mailto:')), false);
  }
});

test('profile, shortcuts, appearance and logout remain operable', () => {
  const { items, events } = profileMenu('User');
  const item = key => items.find(value => value.label === `SIDEBAR_ITEMS.${key}`);
  assert.equal(item('PROFILE_SETTINGS').link.name, 'profile_settings_index');
  item('KEYBOARD_SHORTCUTS').click();
  item('APPEARANCE').click();
  item('LOGOUT').click();
  assert.deepEqual(events, ['openKeyShortcutModal', 'appearance_settings', 'logout']);
});

test('every product help link resolves to a packaged page and real section', () => {
  const guide = read('public/toybaco-help.html');
  const sections = [...guide.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]);
  const ui = [profile,
    read('app/javascript/v3/views/login/Index.vue'),
    read('app/javascript/v3/views/auth/reset/password/Index.vue'),
    read('app/javascript/dashboard/constants/globals.js'),
    read('app/javascript/dashboard/components/app/UpdateBanner.vue'),
    read('app/javascript/dashboard/routes/dashboard/settings/templates/Index.vue'),
    read('app/javascript/dashboard/routes/dashboard/settings/inbox/settingsPage/ConfigurationPage.vue'),
  ].join('\n');
  for (const match of ui.matchAll(/\/toybaco-help\.html(?:#([a-z-]+))?/g)) {
    if (match[1]) assert.ok(sections.includes(match[1]), match[0]);
  }
  for (const match of guide.matchAll(/href="#([^"]+)"/g)) assert.ok(sections.includes(match[1]));
  for (const match of guide.matchAll(/(?:href|src)="(\/(?:brand-assets\/|favicon)[^"]+)"/g)) {
    assert.ok(existsSync(resolve(app, 'public' + match[1])), match[1]);
  }
  assert.doesNotMatch(ui, /https?:\/\/(?:www\.|status\.)?chatwoot\.com/);
  assert.match(ui, /META_RESTRICTION_STATUS_URL\s*=\s*'\/toybaco-help\.html#connection-status'/);
  assert.match(guide, /href="https:\/\/metastatus\.com\/"/);
  assert.doesNotMatch(guide, /Chatwoot|Postiz|Gitroom|https?:\/\/(?!toybaco\.jp|metastatus\.com)/i);
  assert.match(guide, /href="\/app"/);
  const templates = JSON.parse(read('app/javascript/dashboard/i18n/locale/ja/whatsappTemplateMgmt.json'));
  assert.equal(templates.WHATSAPP_TEMPLATE_MGMT.KNOW_MORE, '操作ガイドを見る');
});

test('bot fallbacks and the logo fallback use the approved asset without changing custom avatars', () => {
  for (const file of ['widget/components/AgentMessage.vue', 'widget/components/UnreadMessage.vue',
    'dashboard/components-next/Contacts/ContactsSidebar/components/ContactNoteItem.vue']) {
    const source = read('app/javascript/' + file);
    assert.doesNotMatch(source, /chatwoot_bot\.png/);
    assert.match(source, /\/brand-assets\/toybaco-app-icon-ivory\.png/);
    assert.match(source, file.includes('ContactNoteItem') ? /note\?\.user\?\.thumbnail/ : /avatar_url/);
  }
  const logo = read('app/javascript/dashboard/components-next/icon/Logo.vue');
  assert.match(logo, /globalConfig\.logoThumbnail \|\|/);
  assert.doesNotMatch(logo, /<svg/);
});

test('new widgets and portals start with Toybaco navy while keeping color editing', () => {
  const website = read('app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Website.vue');
  assert.match(website, /channelWidgetColor: '#1F3A5F'/);
  assert.match(website, /widget_color: this\.channelWidgetColor/);
  assert.match(website, /v-model="channelWidgetColor"/);
  const portal = read('app/javascript/dashboard/components-next/HelpCenter/PortalSwitcher/CreatePortalDialog.vue');
  assert.match(portal, /color: '#1F3A5F'/);
  assert.doesNotMatch(portal, /#2781F6/);
});

test('sample campaigns and admin support do not promote an upstream product', () => {
  assert.doesNotMatch(read('app/javascript/dashboard/components-next/Campaigns/EmptyState/CampaignEmptyStateContent.js'), /chatwoot\.com/);
  const admin = read('app/views/super_admin/settings/show.html.erb');
  assert.doesNotMatch(admin, /discord\.gg|\$chatwoot\.toggle/);
  assert.match(admin, /mailto:support@toybaco.jp/);
});

test('customer content and required license/source offers are not rewritten', () => {
  const entry = read('public/brand-assets/toybaco-post-entry.js');
  assert.match(entry, /Chatwoot \/ MIT/);
  assert.match(entry, /Postiz \/ AGPL-3\.0/);
  assert.match(entry, /\/toybaco\/source/);
  assert.match(entry, /\/api\/toybaco\/source/);
  assert.doesNotMatch(read('public/toybaco-brand.css'), /a\[href="https:\/\/www\.chatwoot\.com\/hc\/user-guide\/en"\]/);
});
