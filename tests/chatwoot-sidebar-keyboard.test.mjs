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
const pushes = [];
const focusCalls = [];
const originalFocus = dom.window.HTMLElement.prototype.focus;
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
function evaluateModule(code, load, resultName) {
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
  return new Function('__load', 'setTimeout', 'clearTimeout', code + '\nreturn ' + result + ';')(
    load,
    callback => { const id = ++timerId; timers.set(id, callback); return id; },
    id => timers.delete(id)
  );
}
const storeApi = { useMapGetter: () => Vue.ref(false) };
const routerApi = { useRoute: () => route, useRouter: () => router };
const empty = Vue.defineComponent({ setup: () => () => null });
const icon = Vue.defineComponent({ inheritAttrs: false, setup: (_props, context) => () => Vue.h('span', { ...context.attrs, 'aria-hidden': 'true' }) });
const policy = Vue.defineComponent({ props: ['as', 'permissions', 'featureFlag'], setup: (props, context) => () => Vue.h(props.as || 'div', context.attrs, context.slots.default?.()) });
const leaf = Vue.defineComponent({ props: ['label', 'to'], setup: (props, context) => () => Vue.h('a', { ...context.attrs, href: props.to?.path, onClick: event => { event.preventDefault(); router.push(props.to); } }, props.label) });
const compiled = new Map();
let provider;
function load(name, from) {
  if (name === 'vue') return Vue;
  if (name === 'vue-router') return routerApi;
  if (name.startsWith('dashboard/composables/store')) return storeApi;
  if (name === 'dashboard/composables/usePolicy') return { usePolicy: () => ({ shouldShow: (_flag, permissions) => permissions.every(item => allowed.value.has(item)) }) };
  if (name === 'dashboard/composables/useUISettings') return { useUISettings: () => ({ uiSettings: Vue.ref({}), updateUISettings() { throw new Error('settings writes forbidden'); } }) };
  if (name === './provider') return provider;
  if (name === 'next/icon/Icon.vue') return { default: icon };
  if (name === 'dashboard/components/policy.vue') return { default: policy };
  if (name === './SidebarGroupLeaf.vue') return { default: leaf };
  if (['./SidebarSubGroup.vue', './SidebarGroupEmptyLeaf.vue', './SidebarUnreadBadge.vue', './SidebarSortMenu.vue'].includes(name)) return { default: empty };
  if (name === '@vueuse/core') return { onClickOutside: (element, callback) => {
    const handler = event => { if (element.value && !element.value.contains(event.target) && !event.target.closest('[data-popover-content]')) callback(event); };
    Vue.onMounted(() => document.addEventListener('pointerdown', handler));
    Vue.onUnmounted(() => document.removeEventListener('pointerdown', handler));
  } };
  const relative = name.startsWith('./') ? path.posix.join(path.posix.dirname(from), name)
    : name === 'dashboard/components-next/TeleportWithDirection.vue' ? 'app/javascript/dashboard/components-next/TeleportWithDirection.vue' : null;
  assert.ok(relative?.endsWith('.vue'), 'unhandled import: ' + name);
  return { default: sfc(relative) };
}
function sfc(relative) {
  if (compiled.has(relative)) return compiled.get(relative);
  const parsed = parse(source(relative), { filename: relative });
  assert.deepEqual(parsed.errors, [], 'SFC parse: ' + relative);
  const output = compileScript(parsed.descriptor, { id: sha(Buffer.from(relative)), genDefaultAs: '__component', inlineTemplate: true });
  const component = evaluateModule(output.content, name => load(name, relative), '__component');
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
  assert.deepEqual(runtimeErrors, []);
  assert.ok(focusCalls.every(item => item.connected), 'focus never targets detached elements');
  console.log(JSON.stringify({ status: 'PASS', cases, source_sha256: sourceHashes, externalCalls: 0,
    businessCalls: 0, boundaries: ['Full actual Group/Popover/Header/Teleport/provider; route, policy, store, decorative leaves and click-outside adapter are controlled.', 'No computed browser layout or real router/backend assertion.'] }));
} finally {
  await dispose();
  timers.clear();
  dom.window.HTMLElement.prototype.focus = originalFocus;
  dom.window.close();
  for (const [key, descriptor] of savedGlobals) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else delete globalThis[key];
  }
}
