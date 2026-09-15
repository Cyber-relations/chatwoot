import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';

// Full Vue SFCs are mounted. Only route/policy/store data and decorative leaves
// are supplied by this fixture; the sidebar provider and focus handlers are real.
const options = {};
for (let i = 2; i < process.argv.length; i += 2) {
  const key = process.argv[i];
  assert.ok(['--overlay-root', '--chatwoot-root', '--vue-dependency-root', '--dom-dependency-root'].includes(key), 'unknown option');
  assert.ok(process.argv[i + 1], 'option requires a path');
  options[key] = path.resolve(process.argv[i + 1]);
}
const sourceRoot = options['--chatwoot-root'] || process.env.CHATWOOT_ROOT;
assert.ok(sourceRoot, 'pass --chatwoot-root or CHATWOOT_ROOT; dependencies must already be installed');
const overlayRoot = options['--overlay-root'] || process.env.CHATWOOT_OVERLAY_ROOT;
const vueRequire = createRequire(path.join(options['--vue-dependency-root'] || sourceRoot, 'package.json'));
const domRequire = createRequire(path.join(options['--dom-dependency-root'] || sourceRoot, 'package.json'));
const { JSDOM, VirtualConsole } = domRequire('jsdom');
const { parse, compileScript, babelParse } = vueRequire('@vue/compiler-sfc');
const runtimeErrors = [];
const virtualConsole = new VirtualConsole();
virtualConsole.on('jsdomError', error => runtimeErrors.push(error.message));
const dom = new JSDOM('<!doctype html><html><body><button id="outside">Outside</button></body></html>', {
  url: 'https://sidebar.invalid/app/accounts/1/dashboard', pretendToBeVisual: true, virtualConsole,
});
const globals = ['window', 'document', 'navigator', 'Node', 'Element', 'HTMLElement', 'SVGElement',
  'Event', 'CustomEvent', 'MouseEvent', 'KeyboardEvent', 'FocusEvent', 'getComputedStyle',
  'requestAnimationFrame', 'cancelAnimationFrame', 'fetch'];
const savedGlobals = new Map(globals.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
for (const key of globals) {
  const value = key === 'fetch' ? () => { throw new Error('network forbidden'); }
    : typeof dom.window[key] === 'function' && ['getComputedStyle', 'requestAnimationFrame', 'cancelAnimationFrame'].includes(key)
      ? dom.window[key].bind(dom.window) : dom.window[key];
  Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });
}
// Vue runtime-dom must observe this document on its first import.
const Vue = vueRequire('vue');
const sourceHashes = {};
const cases = [];
const timers = new Map();
let timerId = 0;
let app;
let host;
let route;
let router;
let allowed;
let sidebar;
let holdMobileFocus = false;
const mobileFocusWaiters = [];
const mobileListeners = new Set();
const releaseMobileFocus = () => {
  holdMobileFocus = false;
  for (const resolve of mobileFocusWaiters.splice(0)) resolve();
};
const pushes = [];
const accountNavigations = [];
const accountFixtures = new Map();
const accountWindow = { location: { set href(value) { accountNavigations.push(value); } } };
const focusCalls = [];
const originalFocus = dom.window.HTMLElement.prototype.focus;
const originalInert = Object.getOwnPropertyDescriptor(dom.window.HTMLElement.prototype, 'inert');
const needsInertReflection = !('inert' in dom.window.HTMLElement.prototype);
if (needsInertReflection) {
  // Older JSDOM lacks this native boolean reflected property. Reflect only the
  // attribute; do not synthesize inert focus/Tab/AX behavior or change Vue code.
  Object.defineProperty(dom.window.HTMLElement.prototype, 'inert', {
    configurable: true,
    get() { return this.hasAttribute('inert'); },
    set(value) { if (value) this.setAttribute('inert', ''); else this.removeAttribute('inert'); },
  });
}
dom.window.HTMLElement.prototype.focus = function (...args) {
  focusCalls.push({ connected: this.isConnected, text: this.textContent });
  return originalFocus.apply(this, args);
};
const base = 'app/javascript/dashboard/components-next/sidebar/';
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
function source(relative) {
  const overlay = overlayRoot && path.join(overlayRoot, relative);
  const filename = overlay && fs.existsSync(overlay) ? overlay : path.join(sourceRoot, relative);
  const bytes = fs.readFileSync(filename);
  sourceHashes[relative] = sha(bytes);
  return bytes.toString();
}

// Transform import/export syntax using the compiler's parser, without changing
// function bodies or template output. No transpiler dependency or disk bundle.
function evaluateModule(code, load, resultName, executionWindow = window) {
  const parsed = babelParse(code, { sourceType: 'module' });
  const edits = [];
  const exports = [];
  let imports = 0;
  for (const node of parsed.program.body) {
    if (node.type === 'ImportDeclaration') {
      const name = '__import' + imports++;
      let replacement = 'const ' + name + '=__load(' + JSON.stringify(node.source.value) + ');';
      for (const item of node.specifiers) {
        const value = item.type === 'ImportDefaultSpecifier' ? name + '.default'
          : item.type === 'ImportNamespaceSpecifier' ? name
            : name + '[' + JSON.stringify(item.imported.name || item.imported.value) + ']';
        replacement += 'const ' + item.local.name + '=' + value + ';';
      }
      edits.push([node.start, node.end, replacement]);
    } else if (node.type === 'ExportNamedDeclaration') {
      assert.equal(node.declaration?.type, 'FunctionDeclaration', 'only existing provider function exports');
      exports.push(node.declaration.id.name);
      edits.push([node.start, node.declaration.start, '']);
    } else {
      assert.notEqual(node.type, 'ExportDefaultDeclaration', 'SFC output uses genDefaultAs');
    }
  }
  for (const [start, end, replacement] of edits.sort((a, b) => b[0] - a[0])) code = code.slice(0, start) + replacement + code.slice(end);
  const result = resultName || '{' + exports.join(',') + '}';
  return new Function('__load', 'setTimeout', 'clearTimeout', 'window', code + '\nreturn ' + result + ';')(
    load,
    callback => { const id = ++timerId; timers.set(id, callback); return id; },
    id => timers.delete(id), executionWindow
  );
}
const storeApi = { useMapGetter: name => accountFixtures.get(name) || Vue.ref(false) };
const routerApi = { useRoute: () => route, useRouter: () => router };
const empty = Vue.defineComponent({ setup: () => () => null });
const icon = Vue.defineComponent({ inheritAttrs: false, setup: (_props, context) => () => Vue.h('span', { ...context.attrs, 'aria-hidden': 'true' }) });
const policy = Vue.defineComponent({ props: ['as', 'permissions', 'featureFlag'], setup: (props, context) => () => Vue.h(props.as || 'div', context.attrs, context.slots.default?.()) });
const leaf = Vue.defineComponent({ props: ['label', 'to'], setup: (props, context) => () => Vue.h('a', { ...context.attrs, href: props.to?.path, onClick: event => { event.preventDefault(); router.push(props.to); } }, props.label) });
const compiled = new Map();
const modules = new Map();
const dropdownBase = 'app/javascript/dashboard/components-next/dropdown-menu/base/';
const outsideClickHandlers = new WeakMap();
// VueUse is not installed in this portable fixture. These adapters supply only
// reactive toggle and directive lifecycle/events, never dropdown key/focus logic.
const dropdownOutsideClick = {
  mounted(element, binding) {
    const [close, options] = binding.value;
    const handler = event => {
      if (!element.contains(event.target) && !options.ignore.some(selector => event.target.closest(selector))) close(event);
    };
    outsideClickHandlers.set(element, handler);
    document.addEventListener('click', handler, true);
  },
  unmounted(element) {
    document.removeEventListener('click', outsideClickHandlers.get(element), true);
    outsideClickHandlers.delete(element);
  },
};
let provider;
function load(name, from) {
  if (name === 'vue') return Vue;
  if (name === 'vue-router') return routerApi;
  if (name.startsWith('dashboard/composables/store')) return storeApi;
  if (name === 'vue-i18n') return { useI18n: () => ({ t: key => key }) };
  if (name === 'dashboard/composables/useAccount') return { useAccount: () => ({
    accountId: Vue.ref(4), currentAccount: Vue.computed(() => accountFixtures.get('getCurrentUser').value.accounts.find(account => account.id === 4)),
  }) };
  if (name === 'dashboard/composables/usePolicy') return { usePolicy: () => ({ shouldShow: (_flag, permissions) => permissions.every(item => allowed.value.has(item)) }) };
  if (name === 'dashboard/composables/useUISettings') return { useUISettings: () => ({ uiSettings: Vue.ref({}), updateUISettings() { throw new Error('settings writes forbidden'); } }) };
  if (name === './provider') return provider;
  if (name === 'next/icon/Icon.vue') return { default: icon };
  if (name === 'dashboard/components-next/icon/Icon.vue' || name === 'next/icon/Logo.vue') return { default: icon };
  if (name === 'next/button/Button.vue') return { default: empty };
  if (name === 'next/dropdown-menu/base') return Object.fromEntries(
    ['DropdownContainer', 'DropdownBody', 'DropdownSection', 'DropdownItem'].map(component => [component, sfc(dropdownBase + component + '.vue')])
  );
  if (name === '@vueuse/components') return { vOnClickOutside: dropdownOutsideClick };
  if (name === 'dashboard/components/policy.vue') return { default: policy };
  if (name === './SidebarGroupLeaf.vue') return { default: leaf };
  if (['./SidebarSubGroup.vue', './SidebarGroupEmptyLeaf.vue', './SidebarUnreadBadge.vue', './SidebarSortMenu.vue'].includes(name)) return { default: empty };
  if (name === '@vueuse/core') return { useToggle: initial => {
    const value = Vue.ref(initial);
    return [value, next => { value.value = typeof next === 'boolean' ? next : !value.value; return value.value; }];
  }, onClickOutside: (element, callback) => {
    const handler = event => { if (element.value && !element.value.contains(event.target) && !event.target.closest('[data-popover-content]')) callback(event); };
    Vue.onMounted(() => document.addEventListener('pointerdown', handler));
    Vue.onUnmounted(() => document.removeEventListener('pointerdown', handler));
  } };
  const relative = name.startsWith('./') ? path.posix.join(path.posix.dirname(from), name)
    : name === 'dashboard/components-next/TeleportWithDirection.vue' ? 'app/javascript/dashboard/components-next/TeleportWithDirection.vue'
      : name === 'dashboard/composables/useDropdownPosition' ? 'app/javascript/dashboard/composables/useDropdownPosition.js' : null;
  if (relative?.endsWith('.js')) {
    if (!modules.has(relative)) modules.set(relative, evaluateModule(source(relative), dependency => load(dependency, relative)));
    return modules.get(relative);
  }
  assert.ok(relative?.endsWith('.vue'), 'unhandled import: ' + name);
  return { default: sfc(relative) };
}
function sfc(relative) {
  if (compiled.has(relative)) return compiled.get(relative);
  const parsed = parse(source(relative), { filename: relative });
  assert.deepEqual(parsed.errors, [], 'SFC parse: ' + relative);
  const output = compileScript(parsed.descriptor, { id: sha(Buffer.from(relative)), genDefaultAs: '__component', inlineTemplate: true });
  const component = evaluateModule(output.content, name => load(name, relative), '__component',
    relative === base + 'SidebarAccountSwitcher.vue' ? accountWindow : window);
  compiled.set(relative, component);
  return component;
}
const tick = async () => { for (let i = 0; i < 8; i++) await Vue.nextTick(); };
const runTimers = async () => { for (const [id, callback] of [...timers]) { timers.delete(id); callback(); } await tick(); };
const child = (name, pathname = '/' + name, permission = 'allowed') => ({ name, label: name, to: { path: pathname, params: {}, permission }, activeOn: [] });
function event(target, key, extra = {}) {
  const ev = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true, ...extra });
  if (extra.prePrevented) ev.preventDefault();
  target.dispatchEvent(ev);
  return ev;
}
const popover = () => document.getElementById('toybaco-sidebar-popover-Settings');
const trigger = () => host.querySelector('[title="Settings"]');
const expandedList = () => host.querySelector('#toybaco-sidebar-children-Settings');
function pass(name) { cases.push(name); }
async function dispose() {
  if (app) app.unmount();
  app = null;
  releaseMobileFocus();
  if (host) host.remove();
  host = null;
  provider?.usePopoverState().closeActivePopover();
  provider?.usePopoverState().cancelClose();
  await tick();
  assert.equal(document.querySelector('[id^="toybaco-sidebar-popover-"]'), null);
}
async function mount({ collapsed = true, pathname = '/active', children = [child('denied', '/denied', 'denied'), child('first'), child('active')], expanded = null } = {}) {
  await dispose();
  pushes.length = 0;
  allowed = Vue.ref(new Set(['allowed']));
  route = Vue.reactive({ path: pathname, name: pathname, params: {} });
  router = { resolve: to => ({ path: to?.path || '/', meta: { permissions: to?.permission ? [to.permission] : [] } }), getRoutes: () => [],
    push: async to => { pushes.push(to); route.path = to.path; route.name = to.path; return undefined; } };
  sidebar = { expandedItem: Vue.ref(expanded), isCollapsed: Vue.ref(collapsed), isResizing: Vue.ref(false), sidebarWidth: Vue.ref(collapsed ? 56 : 168),
    setExpandedItem: name => { sidebar.expandedItem.value = sidebar.expandedItem.value === name ? null : name; } };
  const props = Vue.reactive({ name: 'Settings', label: 'Settings', icon: 'i-lucide-settings', children });
  host = document.createElement('div'); document.body.append(host);
  app = Vue.createApp({ setup() { provider.provideSidebarContext(sidebar); return () => Vue.h(Group, props); } });
  app.config.errorHandler = error => runtimeErrors.push(error.message);
  app.component('RouterLink', leaf);
  app.mount(host); await tick();
  return props;
}
let Group;
let mobileContractHashes;
function mountActualParentEscape(mode) {
  const code = source('public/brand-assets/toybaco-post-entry.js');
  const parsed = babelParse(code, { sourceType: 'script' });
  const names = ['isVisibleNativeOverlay', 'hasNativeEscapeOverlay', 'onKeydown', 'auxiliaryKeydown'];
  const declarations = new Map(names.map(name => [name, []]));
  const visit = node => {
    if (!node || typeof node !== 'object') return;
    if (node.type === 'FunctionDeclaration' && declarations.has(node.id?.name)) declarations.get(node.id.name).push(node);
    for (const value of Object.values(node)) {
      if (Array.isArray(value)) value.forEach(visit);
      else if (value && typeof value === 'object') visit(value);
    }
  };
  visit(parsed.program);
  const functions = names.map(name => {
    const found = declarations.get(name); assert.equal(found.length, 1, 'unique actual parent function: ' + name);
    return code.slice(found[0].start, found[0].end);
  }).join('\n');
  mobileContractHashes.parent_escape_functions_sha256 = sha(Buffer.from(functions));
  const parent = document.createElement('div');
  if (mode === 'about' || mode === 'ai') parent.setAttribute('data-toybaco-aux-view', mode);
  else parent.setAttribute('data-toybaco-post-entry-panel', '');
  document.body.append(parent);
  const effects = { request: 0, postingClose: 0, aboutClose: 0 };
  // Only the final business close/request effects are counted. Overlay visibility,
  // both key handlers and their capture ordering run unchanged on the same DOM.
  const handlers = new Function('panel', 'auxiliaryView', 'aiPanel', 'document', 'window', 'setTimeout',
    'requestPanelClose', 'closePanel', 'closeAuxiliaryView',
    functions + '\nreturn {onKeydown, auxiliaryKeydown};')(
    mode === 'posting' ? parent : null, mode === 'about' || mode === 'ai' ? parent : null, null, document, window,
    callback => { const id = ++timerId; timers.set(id, callback); return id; },
    () => { effects.request += 1; return false; }, () => { effects.postingClose += 1; },
    restore => { assert.equal(restore, true); effects.aboutClose += 1; }
  );
  document.addEventListener('keydown', handlers.onKeydown, true);
  document.addEventListener('keydown', handlers.auxiliaryKeydown, true);
  return { effects, parent, cleanup() {
    document.removeEventListener('keydown', handlers.onKeydown, true);
    document.removeEventListener('keydown', handlers.auxiliaryKeydown, true);
    parent.remove();
  } };
}

function compileMobileDrawerContract(descriptor) {
  const script = descriptor.scriptSetup.content;
  const parsed = babelParse(script, { sourceType: 'module' });
  const declaration = name => {
    const nodes = parsed.program.body.filter(node => node.type === 'VariableDeclaration' &&
      node.declarations.some(item => item.id.type === 'Identifier' && item.id.name === name));
    assert.equal(nodes.length, 1, 'unique actual Sidebar declaration: ' + name);
    return nodes[0];
  };
  const start = declaration('sidebarRoot').start;
  const end = declaration('closeMobileSidebar').end;
  assert.ok(start < end, 'mobile lifecycle and its actual close handler form one block');
  const lifecycle = script.slice(start, end);
  const lifecycleAst = babelParse(lifecycle, { sourceType: 'module' });
  assert.equal(lifecycleAst.program.body.filter(node => node.type === 'ExpressionStatement' &&
    node.expression.type === 'CallExpression' && node.expression.callee.name === 'watch').length, 1,
  'mount the actual mobile watch once');
  const mobile = declaration('isMobile');
  const vueImport = parsed.program.body.filter(node => node.type === 'ImportDeclaration' && node.source.value === 'vue');
  assert.equal(vueImport.length, 1);
  const asides = descriptor.template.ast.children.filter(node => node.type === 1 && node.tag === 'aside');
  assert.equal(asides.length, 1, 'actual root aside');
  const attributes = asides[0].props.filter(prop =>
    (prop.type === 6 && prop.name === 'ref') ||
    (prop.type === 7 && prop.name === 'bind' && ['inert', 'aria-hidden', 'data-toybaco-mobile-sidebar-open'].includes(prop.arg?.content)));
  assert.equal(attributes.length, 4, 'actual ref/inert/aria-hidden/open-overlay bindings are present');
  const templateAttributes = attributes.map(prop => prop.loc.source).join(' ');
  mobileContractHashes = { lifecycle_sha256: sha(Buffer.from(lifecycle)), aside_attributes_sha256: sha(Buffer.from(templateAttributes)) };
  // Only reactive inputs and representative nav leaves are fixtures. The computed
  // mobile predicate, focus lifecycle and three DOM bindings are verbatim source.
  const fixture = `<script setup>
${script.slice(vueImport[0].start, vueImport[0].end)}
import { useEventListener } from '@vueuse/core';
const props = defineProps({ isMobileSidebarOpen: Boolean, fixtureWidth: Number, fixtureCurrent: Boolean });
const emit = defineEmits(['closeMobileSidebar']);
const windowWidth = computed(() => props.fixtureWidth);
${script.slice(mobile.start, mobile.end)}
${lifecycle}
</script><template><aside ${templateAttributes}>
<nav>
  <slot />
  <a href="/hidden" hidden>Hidden</a>
  <button disabled>Disabled</button>
  <a href="/disabled" aria-disabled="true">Unavailable</a>
  <a href="/negative" tabindex="-1">Negative tabindex</a>
  <a href="/invisible" style="visibility:hidden">Invisible</a>
  <a id="fixture-first" href="/first">First</a>
  <a id="fixture-current" href="/current" aria-current="page" class="router-link-exact-active"
     :data-toybaco-nav-current="fixtureCurrent ? 'true' : 'false'">Current</a>
</nav></aside></template>`;
  const fragment = parse(fixture, { filename: 'Sidebar.mobile-lifecycle.fixture.vue' });
  assert.deepEqual(fragment.errors, []);
  const output = compileScript(fragment.descriptor, { id: 'actual-sidebar-mobile-lifecycle', genDefaultAs: '__component', inlineTemplate: true });
  return evaluateModule(output.content, name => {
    if (name === '@vueuse/core') return { useEventListener: (target, type, callback) => {
      assert.equal(target, window); assert.equal(type, 'keydown');
      // Default window bubble registration/cleanup contract only; the key
      // handler and close emission above are verbatim Sidebar source.
      Vue.onMounted(() => { target.addEventListener(type, callback); mobileListeners.add(callback); });
      Vue.onBeforeUnmount(() => { target.removeEventListener(type, callback); mobileListeners.delete(callback); });
    } };
    assert.equal(name, 'vue', 'mobile lifecycle fragment has no external data imports');
    return { ...Vue, nextTick: (...args) => {
      const completion = Vue.nextTick(...args);
      return holdMobileFocus ? completion.then(() => new Promise(resolve => mobileFocusWaiters.push(resolve))) : completion;
    } };
  }, '__component');
}

async function verifyMobileDrawer(descriptor) {
  const Component = compileMobileDrawerContract(descriptor);
  const mountMobile = async ({ width = 390, open = false, current = true } = {}) => {
    await dispose();
    assert.equal(mobileListeners.size, 0, 'previous drawer listener disposed');
    const props = Vue.reactive({ fixtureWidth: width, isMobileSidebarOpen: open, fixtureCurrent: current });
    const closes = [];
    host = document.createElement('div'); document.body.append(host);
    app = Vue.createApp({ setup: () => () => Vue.h('div', [
      Vue.h('div', { id: 'mobile-sidebar-launcher' }, Vue.h('button', {}, 'Menu')),
      Vue.h('button', { id: 'fixture-dialog' }, 'New dialog'),
      Vue.h(Component, { ...props, onCloseMobileSidebar: () => { closes.push('close'); props.isMobileSidebarOpen = false; } }),
    ]) });
    app.config.errorHandler = error => runtimeErrors.push(error.message);
    app.mount(host); await tick();
    // JSDOM has no computed layout. Supply rectangles only; actual source still
    // filters hidden/inert/disabled/tabindex and computed visibility itself.
    for (const control of host.querySelectorAll('aside, a, button')) {
      Object.defineProperty(control, 'getClientRects', { value: () => [{}], configurable: true });
    }
    return { props, closes, drawer: host.querySelector('aside'), launcher: host.querySelector('#mobile-sidebar-launcher button'),
      first: host.querySelector('#fixture-first'), current: host.querySelector('#fixture-current'),
      dialog: host.querySelector('#fixture-dialog') };
  };
  let fixture = await mountMobile();
  assert.equal(fixture.drawer.hasAttribute('inert'), true);
  assert.equal(fixture.drawer.getAttribute('aria-hidden'), 'true');
  fixture.launcher.focus(); fixture.props.isMobileSidebarOpen = true; await tick();
  assert.equal(fixture.drawer.hasAttribute('inert'), false);
  assert.equal(fixture.drawer.hasAttribute('aria-hidden'), false);
  assert.equal(document.activeElement, fixture.current);
  pass('Mobile closed aside is inert/aria-hidden; launcher open focuses current eligible actual nav');

  fixture.props.isMobileSidebarOpen = false; await tick();
  assert.equal(document.activeElement, fixture.launcher);
  assert.equal(fixture.drawer.hasAttribute('inert'), true);
  fixture.props.fixtureCurrent = false;
  fixture.props.isMobileSidebarOpen = true; await tick();
  assert.equal(document.activeElement, fixture.first);
  pass('Mobile close returns drawer focus to launcher; next open selects first eligible nav when current marker is false');

  fixture = await mountMobile();
  fixture.dialog.focus(); fixture.props.isMobileSidebarOpen = true; await tick();
  assert.equal(document.activeElement, fixture.dialog);
  fixture.props.isMobileSidebarOpen = false; await tick();
  fixture.launcher.focus(); holdMobileFocus = true; fixture.props.isMobileSidebarOpen = true;
  await tick(); assert.equal(mobileFocusWaiters.length, 1);
  fixture.dialog.focus(); releaseMobileFocus(); await tick();
  assert.equal(document.activeElement, fixture.dialog);
  fixture.current.focus(); holdMobileFocus = true; fixture.props.isMobileSidebarOpen = false;
  await tick(); assert.equal(mobileFocusWaiters.length, 1);
  fixture.dialog.focus(); releaseMobileFocus(); await tick();
  assert.equal(document.activeElement, fixture.dialog);
  pass('Mobile lifecycle preserves external route/dialog focus on open and close, including the nextTick gap');

  fixture = await mountMobile();
  fixture.launcher.focus();
  const rapidFocus = focusCalls.length;
  holdMobileFocus = true; fixture.props.isMobileSidebarOpen = true; await tick();
  assert.equal(mobileFocusWaiters.length, 1);
  fixture.props.isMobileSidebarOpen = false; await tick(); releaseMobileFocus(); await tick();
  assert.equal(document.activeElement, fixture.launcher);
  assert.equal(focusCalls.length, rapidFocus);
  fixture.props.isMobileSidebarOpen = true; await tick();
  assert.equal(document.activeElement, fixture.current);
  assert.equal(focusCalls.length, rapidFocus + 1);
  pass('Mobile rapid open/close rejects stale focus; a subsequent open focuses once');

  fixture = await mountMobile();
  fixture.launcher.focus(); holdMobileFocus = true; fixture.props.isMobileSidebarOpen = true;
  await tick(); assert.equal(mobileFocusWaiters.length, 1);
  const unmountFocus = focusCalls.length;
  await dispose(); await tick();
  assert.equal(focusCalls.length, unmountFocus);
  pass('Mobile unmount during nextTick cannot focus retired drawer controls');

  fixture = await mountMobile({ width: 1000 });
  assert.equal(fixture.drawer.hasAttribute('inert'), false);
  assert.equal(fixture.drawer.hasAttribute('aria-hidden'), false);
  fixture.launcher.focus(); fixture.props.isMobileSidebarOpen = true; await tick();
  assert.equal(document.activeElement, fixture.launcher);
  fixture = await mountMobile();
  fixture.launcher.focus(); holdMobileFocus = true; fixture.props.isMobileSidebarOpen = true;
  await tick(); assert.equal(mobileFocusWaiters.length, 1);
  fixture.props.fixtureWidth = 1000; await tick(); releaseMobileFocus(); await tick();
  assert.equal(document.activeElement, fixture.launcher);
  fixture.props.isMobileSidebarOpen = false; await tick();
  assert.equal(fixture.drawer.hasAttribute('inert'), false);
  assert.equal(fixture.drawer.hasAttribute('aria-hidden'), false);
  pass('Desktop aside stays available and mobile-to-desktop transition rejects pending focus');

  for (const mode of ['posting', 'about']) {
    fixture = await mountMobile();
    fixture.launcher.focus(); fixture.props.isMobileSidebarOpen = true; await tick();
    assert.equal(fixture.drawer.getAttribute('data-toybaco-mobile-sidebar-open'), 'true');
    const parent = mountActualParentEscape(mode);
    try {
      assert.equal(timers.size, 0);
      assert.equal(event(fixture.current, 'Escape').defaultPrevented, true); await tick();
      assert.equal(timers.size, 0, 'actual parent capture saw the open drawer marker before its bubble close');
      await runTimers();
      assert.equal(fixture.closes.length, 1);
      assert.equal(fixture.drawer.hasAttribute('data-toybaco-mobile-sidebar-open'), false);
      assert.equal(document.activeElement, fixture.launcher);
      assert.deepEqual(parent.effects, { request: 0, postingClose: 0, aboutClose: 0 });
      assert.equal(parent.parent.isConnected, true);
      event(fixture.launcher, 'Escape'); await tick(); await runTimers();
      assert.equal(fixture.closes.length, 1);
      assert.deepEqual(parent.effects, mode === 'posting'
        ? { request: 1, postingClose: 1, aboutClose: 0 }
        : { request: 0, postingClose: 0, aboutClose: 1 });
    } finally { parent.cleanup(); }
  }
  pass('Actual posting/About document capture respects the real open drawer marker; first Escape closes only drawer, next Escape reaches parent');

  fixture = await mountMobile({ open: true });
  fixture.launcher.focus();
  assert.equal(event(fixture.launcher, 'Escape').defaultPrevented, true); await tick();
  assert.equal(fixture.closes.length, 1);
  fixture = await mountMobile({ open: true });
  for (const extra of [{ isComposing: true }, { keyCode: 229 }, { prePrevented: true }]) {
    event(fixture.current, 'Escape', extra); await tick(); assert.equal(fixture.closes.length, 0);
  }
  for (const role of ['menu', 'listbox', 'dialog']) {
    const nested = document.createElement('div'); nested.setAttribute('role', role);
    const button = document.createElement('button'); nested.append(button); fixture.drawer.append(nested);
    assert.equal(event(button, 'Escape').defaultPrevented, false); await tick();
    assert.equal(fixture.closes.length, 0); nested.remove();
  }
  assert.equal(event(fixture.dialog, 'Escape').defaultPrevented, false); await tick();
  assert.equal(fixture.closes.length, 0);
  fixture.props.fixtureWidth = 1000; await tick();
  assert.equal(event(fixture.current, 'Escape').defaultPrevented, false); await tick();
  assert.equal(fixture.closes.length, 0);
  await dispose(); assert.equal(mobileListeners.size, 0);
  pass('Mobile launcher Escape works; IME, consumed keys, nested menus/dialogs, outside targets and desktop remain owned by their existing handlers');
}

async function verifyAccountDropdown(descriptor) {
  const Drawer = compileMobileDrawerContract(descriptor);
  const AccountSwitcher = sfc(base + 'SidebarAccountSwitcher.vue');
  const Container = sfc(dropdownBase + 'DropdownContainer.vue');
  const Body = sfc(dropdownBase + 'DropdownBody.vue');
  const provideRects = () => {
    for (const element of host.querySelectorAll('aside, div, ul, a, button')) {
      Object.defineProperty(element, 'getClientRects', { value: () => [{}], configurable: true });
    }
  };
  const mountDropdown = async ({ account = true, closeOnEscape = false } = {}) => {
    await dispose();
    accountNavigations.length = 0;
    accountFixtures.clear();
    const accounts = [{ id: 4, name: 'Account 4', role: 'administrator' }, { id: 13, name: 'Account 13', role: 'agent' }];
    accountFixtures.set('getCurrentUser', Vue.ref({ accounts }));
    accountFixtures.set('getUserAccounts', Vue.ref(accounts));
    accountFixtures.set('globalConfig/get', Vue.ref({ createNewAccountFromDashboard: false }));
    const props = Vue.reactive({ fixtureWidth: 390, isMobileSidebarOpen: false, fixtureCurrent: true });
    const closes = [];
    const dropdownCloses = [];
    host = document.createElement('div'); document.body.append(host);
    const dropdown = () => account ? Vue.h(AccountSwitcher) : Vue.h(Container, {
      closeOnEscape, onClose: () => dropdownCloses.push('close'),
    }, {
      trigger: ({ toggle }) => Vue.h('button', { id: 'fixture-dropdown-trigger', onClick: toggle }, 'Dropdown'),
      default: () => Vue.h(Body, {}, { default: () => Vue.h('li', {}, 'Option') }),
    });
    app = Vue.createApp({ setup: () => () => account ? Vue.h('div', [
      Vue.h('div', { id: 'mobile-sidebar-launcher' }, Vue.h('button', {}, 'Menu')),
      Vue.h(Drawer, { ...props, onCloseMobileSidebar: () => { closes.push('close'); props.isMobileSidebarOpen = false; } }, { default: dropdown }),
    ]) : dropdown() });
    app.config.errorHandler = error => runtimeErrors.push(error.message);
    app.mount(host); await tick(); provideRects();
    const launcher = host.querySelector('#mobile-sidebar-launcher button');
    if (account) {
      launcher.focus(); props.isMobileSidebarOpen = true; await tick();
    }
    const accountTrigger = host.querySelector(account ? '#sidebar-account-switcher' : '#fixture-dropdown-trigger');
    const body = () => host.querySelector('.n-dropdown-body');
    const open = async () => { accountTrigger.focus(); accountTrigger.click(); await tick(); provideRects(); assert.ok(body()); };
    return { props, closes, dropdownCloses, launcher, trigger: accountTrigger, body, open, drawer: host.querySelector('aside') };
  };

  for (const focusOrigin of ['trigger', 'body']) {
    const fixture = await mountDropdown();
    window.history.replaceState({}, '', '/app/accounts/4/dashboard#/toybaco/assistant');
    const aiUrl = window.location.href;
    const parent = mountActualParentEscape('ai');
    try {
      await fixture.open();
      assert.equal(fixture.trigger.getAttribute('aria-haspopup'), 'listbox');
      assert.equal(fixture.body().getAttribute('role'), null, 'actual account list has no synthetic role=menu');
      assert.ok(host.querySelector('#account-4')); assert.ok(host.querySelector('#account-13'));
      const origin = focusOrigin === 'trigger' ? fixture.trigger : host.querySelector('#account-13');
      if (focusOrigin === 'body') { origin.tabIndex = -1; origin.focus(); }
      assert.equal(document.activeElement, origin);
      assert.equal(event(origin, 'Escape').defaultPrevented, true);
      await tick(); await runTimers();
      assert.equal(fixture.body(), null, 'actual isOpen state closed, not merely hidden with the drawer');
      assert.equal(document.activeElement, fixture.trigger);
      assert.equal(fixture.closes.length, 0);
      assert.equal(fixture.drawer.getAttribute('data-toybaco-mobile-sidebar-open'), 'true');
      assert.deepEqual(parent.effects, { request: 0, postingClose: 0, aboutClose: 0 });
      assert.equal(parent.parent.getAttribute('data-toybaco-aux-view'), 'ai');
      assert.equal(parent.parent.isConnected, true); assert.equal(window.location.href, aiUrl);
      assert.deepEqual(accountNavigations, []);
      assert.equal(event(fixture.trigger, 'Escape').defaultPrevented, true);
      await tick(); await runTimers();
      assert.equal(fixture.closes.length, 1, 'second Escape reaches actual Sidebar drawer handler');
      assert.equal(document.activeElement, fixture.launcher);
      assert.equal(fixture.body(), null);
      assert.deepEqual(parent.effects, { request: 0, postingClose: 0, aboutClose: 0 });
      assert.equal(parent.parent.isConnected, true); assert.equal(window.location.href, aiUrl);
      fixture.props.fixtureWidth = 1000; await tick();
      assert.equal(fixture.body(), null, 'desktop transition cannot reveal stale open dropdown state');
    } finally { parent.cleanup(); }
  }
  pass('Mounted actual account trigger/body Escape closes dropdown and restores trigger; second Escape closes actual drawer while AI URL/view survives, including desktop return');

  for (const extra of [{ isComposing: true }, { keyCode: 229 }, { prePrevented: true }]) {
    const fixture = await mountDropdown(); await fixture.open();
    const focusCount = focusCalls.length;
    let bubbled = 0;
    const bubble = () => { bubbled += 1; };
    window.addEventListener('keydown', bubble);
    try {
      const escape = event(fixture.trigger, 'Escape', extra); await tick();
      assert.equal(escape.defaultPrevented, !!extra.prePrevented);
      assert.equal(bubbled, 1, 'ignored Escape is not propagation-consumed by the dropdown');
      assert.ok(fixture.body()); assert.equal(fixture.closes.length, 0);
      assert.equal(focusCalls.length, focusCount); assert.deepEqual(accountNavigations, []);
    } finally { window.removeEventListener('keydown', bubble); }
  }
  pass('Mounted account dropdown leaves IME, keyCode229 and already-prevented Escape unconsumed without closing or refocusing');

  let fixture = await mountDropdown({ account: false, closeOnEscape: true });
  fixture.trigger.focus();
  assert.equal(event(fixture.trigger, 'Escape').defaultPrevented, false);
  assert.deepEqual(fixture.dropdownCloses, []);
  fixture = await mountDropdown({ account: false }); await fixture.open();
  assert.equal(event(fixture.trigger, 'Escape').defaultPrevented, false); await tick();
  assert.ok(fixture.body()); assert.deepEqual(fixture.dropdownCloses, []);
  pass('Mounted actual DropdownContainer leaves closed and default opt-out Escape behavior unchanged');

  fixture = await mountDropdown(); await fixture.open();
  document.getElementById('outside').click(); await tick();
  assert.equal(fixture.body(), null); assert.equal(fixture.closes.length, 0); assert.deepEqual(accountNavigations, []);
  await fixture.open(); host.querySelector('#account-13').click(); await tick();
  assert.equal(fixture.body(), null); assert.equal(fixture.closes.length, 0);
  assert.deepEqual(accountNavigations, ['/app/accounts/13/dashboard']);
  pass('Mounted account outside-click callback still closes; actual account selection closes and requests only its selected account URL through a no-navigation boundary');
  await dispose(); accountFixtures.clear();
}

try {
  provider = evaluateModule(source(base + 'provider.js'), name => load(name, base + 'provider.js'));
  Group = sfc(base + 'SidebarGroup.vue');
  // Parent integration syntax is checked without executing its store or router.
  const sidebarSource = parse(source(base + 'Sidebar.vue'), { filename: 'Sidebar.vue' });
  assert.deepEqual(sidebarSource.errors, []);
  compileScript(sidebarSource.descriptor, { id: 'sidebar-integration-parse' });
  babelParse(source('app/javascript/dashboard/routes/index.js'), { sourceType: 'module' });
  pass('Sidebar SFC and routes module syntax');

  await mount();
  assert.equal(trigger().getAttribute('aria-expanded'), 'false');
  assert.equal(event(trigger(), 'ArrowDown').defaultPrevented, true); await tick();
  assert.equal(document.activeElement.textContent.trim(), 'active');
  assert.equal(trigger().getAttribute('aria-controls'), popover().id);
  assert.equal(trigger().getAttribute('aria-expanded'), 'true');
  assert.equal(popover().textContent.includes('denied'), false);
  assert.equal(pushes.length, 0); pass('ArrowDown opens actual popover, focuses active allowed item and preserves route');
  assert.equal(event(document.activeElement, 'Escape').defaultPrevented, true); await tick();
  assert.equal(popover(), null); assert.equal(document.activeElement, trigger());
  assert.equal(trigger().getAttribute('aria-expanded'), 'false'); pass('Popover Escape closes and restores trigger focus');

  await mount({ pathname: '/elsewhere' });
  event(trigger(), 'ArrowRight'); await tick();
  assert.equal(document.activeElement.textContent.trim(), 'first'); pass('ArrowRight focuses first permitted item when none is active');
  assert.equal(event(document.activeElement, 'Tab').defaultPrevented, false);
  document.getElementById('outside').focus(); await tick();
  assert.equal(popover(), null); pass('Tab is not prevented; native focusout closes without stealing focus');

  await mount(); event(trigger(), 'ArrowDown'); await tick();
  trigger().parentElement.dispatchEvent(new MouseEvent('mouseleave'));
  popover().dispatchEvent(new MouseEvent('mouseleave'));
  await runTimers(); assert.ok(popover()); pass('Mouse leave timers cannot close a keyboard-focused popover');
  document.activeElement.click(); await tick();
  assert.equal(pushes.length, 1); assert.equal(pushes[0].path, '/active'); assert.equal(popover(), null);
  pass('Existing item click navigates once and closes');

  await mount({ pathname: '/elsewhere' }); trigger().click(); await tick();
  assert.equal(pushes.length, 1); assert.equal(pushes[0].path, '/first');
  pass('Ordinary collapsed trigger click keeps first-permitted navigation');
  for (const extra of [{ isComposing: true }, { keyCode: 229 }, { prePrevented: true }, { ctrlKey: true }, { shiftKey: true }]) {
    await mount(); event(trigger(), 'ArrowDown', extra); await tick(); assert.equal(popover(), null);
  }
  pass('IME, composition keyCode, already-consumed and modified keys do not open');
  await mount(); sidebar.isResizing.value = true; event(trigger(), 'ArrowDown'); await tick();
  assert.equal(popover(), null); pass('Resizing does not open a keyboard popover');
  await mount({ children: [child('denied', '/denied', 'denied')] });
  assert.equal(trigger(), null); pass('A group without permitted destinations is not mounted');

  await mount(); event(trigger(), 'ArrowDown'); await tick();
  for (const extra of [{ isComposing: true }, { keyCode: 229 }, { prePrevented: true }]) {
    event(document.activeElement, 'Escape', extra); await tick(); assert.ok(popover());
  }
  pass('Popover ignores IME and consumed Escape');
  trigger().focus(); // Directly exercise the trigger Escape path with a mouse-open popover.
  trigger().parentElement.dispatchEvent(new MouseEvent('mouseenter')); await tick();
  event(trigger(), 'Escape'); await tick(); assert.equal(popover(), null); assert.equal(document.activeElement, trigger());
  pass('Trigger Escape also closes without navigation');

  await mount(); trigger().parentElement.dispatchEvent(new MouseEvent('mouseenter')); await tick();
  trigger().parentElement.dispatchEvent(new MouseEvent('mouseleave'));
  assert.equal(timers.size, 1);
  popover().querySelector('[data-toybaco-sidebar-focusable]').focus();
  await runTimers(); assert.ok(popover()); pass('Focus entering before a pending mouse timer cancels closure');
  document.getElementById('outside').dispatchEvent(new MouseEvent('pointerdown', { bubbles: true })); await tick();
  assert.equal(popover(), null); pass('Existing outside pointer close retained');

  await mount({ pathname: '/nested', children: [{ name: 'Nested', label: 'Nested', children: [child('denied', '/denied', 'denied'), child('nested')] }] });
  event(trigger(), 'ArrowRight'); await tick();
  assert.equal(document.activeElement.textContent.trim(), 'nested');
  const subgroup = popover().querySelector('[data-toybaco-sidebar-focusable][aria-expanded]');
  assert.equal(subgroup.getAttribute('aria-expanded'), 'true');
  assert.equal(popover().querySelector('button[aria-label="Nested"]').getAttribute('aria-expanded'), 'true');
  assert.equal(popover().textContent.includes('denied'), false); pass('Active subgroup expands before focus, exposes ARIA and filters denied children');

  await mount(); event(trigger(), 'ArrowDown');
  const beforeUnmountFocus = focusCalls.length;
  await dispose(); await runTimers(); assert.equal(focusCalls.length, beforeUnmountFocus);
  pass('Unmount before popover render causes no late focus');
  await mount(); event(trigger(), 'ArrowDown'); await tick(); event(document.activeElement, 'Escape');
  const beforeEscapeUnmount = focusCalls.length;
  await dispose(); await runTimers(); assert.equal(focusCalls.length, beforeEscapeUnmount);
  pass('Unmount during Escape nextTick cannot refocus a retired trigger');

  await mount({ collapsed: false });
  assert.equal(trigger().getAttribute('aria-expanded'), 'true');
  assert.equal(trigger().getAttribute('aria-controls'), expandedList().id);
  assert.equal(trigger().getAttribute('data-toybaco-native-expanded'), 'true');
  assert.notEqual(expandedList().style.display, 'none');
  trigger().click(); await tick();
  assert.equal(trigger().getAttribute('aria-expanded'), 'false'); assert.equal(expandedList().style.display, 'none');
  assert.equal(trigger().getAttribute('data-toybaco-native-expanded'), 'false');
  await tick(); assert.equal(expandedList().style.display, 'none');
  trigger().click(); await tick(); assert.equal(trigger().getAttribute('aria-expanded'), 'true');
  assert.notEqual(expandedList().style.display, 'none'); pass('Real Header toggles active group closed/reopened; manual collapse stays closed');
  for (let i = 0; i < 2; i++) {
    trigger().click(); await tick();
    route.path = '/another-group'; await tick();
    route.path = '/active'; await tick();
    assert.equal(trigger().getAttribute('aria-expanded'), 'true'); assert.notEqual(expandedList().style.display, 'none');
  }
  pass('Repeated leave and return to an active group reopens it');
  trigger().click(); await tick(); route.path = '/first'; await tick();
  assert.equal(trigger().getAttribute('aria-expanded'), 'true'); pass('Same-group different-path deep link reopens a manually closed group');
  await mount({ collapsed: false, expanded: 'Settings' });
  assert.equal(sidebar.expandedItem.value, 'Settings'); assert.notEqual(expandedList().style.display, 'none');
  pass('Mounting an already expanded active group does not toggle it closed');
  const late = await mount({ collapsed: false, pathname: '/late', children: [child('first')] });
  assert.equal(expandedList().style.display, 'none');
  late.children.push(child('late')); await tick();
  assert.equal(route.path, '/late'); assert.equal(trigger().getAttribute('aria-expanded'), 'true');
  assert.notEqual(expandedList().style.display, 'none'); pass('Late children activate and expand a group without changing the URL');
  await verifyMobileDrawer(sidebarSource.descriptor);
  await verifyAccountDropdown(sidebarSource.descriptor);
  assert.deepEqual(runtimeErrors, []);
  assert.ok(focusCalls.every(item => item.connected), 'focus never targets detached elements');
  console.log(JSON.stringify({ status: 'PASS', cases, source_sha256: sourceHashes, mobile_contract_sha256: mobileContractHashes, inertReflectionPolyfill: needsInertReflection, externalCalls: 0,
    businessCalls: 0, boundaries: ['Full actual Group/Popover/Header/Teleport/provider; route, policy, store, decorative leaves and click-outside adapter are controlled.', 'Mobile: verbatim Sidebar lifecycle/key/close/computed/aside bindings plus four actual parent visibility/key functions on one DOM; final parent close/request effects are counted. Representative nav leaves, useEventListener registration adapter, controlled rectangles and deferred real nextTick completion for races. No native inert Tab/AX/layout assertion.', 'Account: full actual AccountSwitcher/DropdownContainer/Body/Section/Item and provider mounted without extracting or replacing the new Escape handler. Controlled account4/account13 store/i18n/decorative leaves; VueUse toggle and outside-click lifecycle adapters; account location.href captured without navigation; default inline dropdown only.', 'No computed browser layout or real router/backend assertion.'] }));
} finally {
  await dispose();
  timers.clear();
  dom.window.HTMLElement.prototype.focus = originalFocus;
  if (needsInertReflection) {
    if (originalInert) Object.defineProperty(dom.window.HTMLElement.prototype, 'inert', originalInert);
    else delete dom.window.HTMLElement.prototype.inert;
  }
  dom.window.close();
  for (const [key, descriptor] of savedGlobals) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else delete globalThis[key];
  }
}
