import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
// An optional overlay root runs the same behavioral contract against fresh generator output.
const overlayRoot = process.argv[2] ? path.resolve(process.argv[2]) : path.join(root, 'overlay/app');
const component = fs.readFileSync(path.join(overlayRoot, 'app/javascript/dashboard/components/widgets/conversation/ReplyBox.vue'), 'utf8');
const start = component.indexOf('    getKeyboardEvents() {');
const end = component.indexOf('    isAValidEvent(', start);
assert.ok(start >= 0 && end > start, 'the actual ReplyBox keyboard handlers must be loaded');
const methods = vm.runInNewContext(`({${component.slice(start, end)}})`);

function keyboardFixture({ copilot = false, valid = true } = {}) {
  let replies = 0;
  let copilotReplies = 0;
  const context = {
    isFocused: true,
    copilot: { isActive: { value: copilot } },
    isAValidEvent: () => valid,
    onSendReply: () => { replies += 1; },
    onSubmitCopilotReply: () => { copilotReplies += 1; },
  };
  return {
    handlers: methods.getKeyboardEvents.call(context),
    sent: () => replies + copilotReplies,
  };
}

for (const shortcut of ['Enter', '$mod+Enter']) {
  for (const event of [{ isComposing: true }, { isComposing: false, keyCode: 229 }]) {
    for (const copilot of [false, true]) {
      const fixture = keyboardFixture({ copilot });
      let prevented = false;
      fixture.handlers[shortcut].action({ ...event, preventDefault() { prevented = true; } });
      assert.equal(fixture.sent(), 0, `${shortcut} must not send while Japanese IME confirms text`);
      assert.equal(prevented, false, 'IME confirmation must retain its native input behavior');
    }
  }
  const fixture = keyboardFixture();
  fixture.handlers[shortcut].action({ isComposing: false, keyCode: 13, preventDefault() {} });
  assert.equal(fixture.sent(), 1, `${shortcut} must still send after composition finishes`);
  const invalid = keyboardFixture({ valid: false });
  invalid.handlers[shortcut].action({ isComposing: false, keyCode: 13, preventDefault() {} });
  assert.equal(invalid.sent(), 0, 'existing focus/menu/hotkey restrictions must remain in force');
}

const copilot = keyboardFixture({ copilot: true });
copilot.handlers['$mod+Enter'].action({ isComposing: false, keyCode: 13, preventDefault() {} });
assert.equal(copilot.sent(), 1, 'the existing AI editor shortcut remains available outside composition');

// Opening contact details must not turn the tablet reply workspace into a
// narrow third column. Run the component's actual outside-close handler too.
const sidebarPath = path.join(overlayRoot, 'app/javascript/dashboard/components/widgets/conversation/ConversationSidebar.vue');
const sidebar = fs.readFileSync(sidebarPath, 'utf8');
const sidebarScript = sidebar.slice(sidebar.indexOf('const { uiSettings,'), sidebar.indexOf('</script>'));
assert.ok(sidebarScript.startsWith('const { uiSettings,'), 'load the actual contact sidebar setup');
const sidebarClasses = sidebar.match(/class="(bg-n-surface-2 [^"]+)"/)?.[1].split(/\s+/);
assert.ok(sidebarClasses?.includes('fixed'), 'retain the existing mobile overlay');
const breakpoints = { md: 768, lg: 1024, xl: 1280 };
function sidebarPositionAt(width) {
  const staticRule = sidebarClasses.find(value => /^(md|lg|xl):static$/.test(value));
  assert.ok(staticRule, 'the native desktop panel must remain in normal flow');
  return width >= breakpoints[staticRule.split(':')[0]] ? 'static' : 'fixed';
}

// Execute the real setup and lifecycle hooks with only the Vue/DOM boundary
// replaced. The fixture does not reimplement the sidebar's focus or key logic.
function sidebarFixture({ width = 1024, visible = true, hasCloseButton = true, origin = 'contact switch' } = {}) {
  const uiSettings = { value: { is_contact_sidebar_open: true, is_copilot_panel_open: false } };
  const updates = [];
  const mounted = [];
  const beforeUnmount = [];
  const ticks = [];
  const listeners = new Map();
  const focusCalls = [];
  const elements = [];
  const document = { activeElement: null };
  function element(name, parent = null, selectors = []) {
    const node = {
      name,
      parent,
      visible: true,
      isConnected: true,
      matches: selector => selector.split(',').some(value => selectors.includes(value.trim())),
      closest(selector) {
        for (let current = node; current; current = current.parent) {
          if (current.matches(selector)) return current;
        }
        return null;
      },
      contains(target) {
        for (let current = target; current; current = current.parent) {
          if (current === node) return true;
        }
        return false;
      },
      getClientRects() {
        for (let current = node; current; current = current.parent) {
          if (!current.isConnected || !current.visible) return [];
        }
        return visible ? [{}] : [];
      },
      focus(options) {
        focusCalls.push({ node, options });
        if (node.isConnected) document.activeElement = node;
      },
    };
    elements.push(node);
    return node;
  }
  const body = element('body');
  const trigger = element(origin, body);
  const panel = element('contact panel', body);
  const closeButton = element('close button', panel);
  const outsideInput = element('outside reply input', body);
  panel.querySelector = selector => {
    assert.equal(selector, '[data-sidebar-close]', 'focus the actual native close control');
    return hasCloseButton ? closeButton : null;
  };
  panel.querySelectorAll = selector => elements.filter(node => panel.contains(node) && node.matches(selector));
  document.querySelectorAll = selector => elements.filter(node => node.matches(selector));
  document.body = body;
  document.activeElement = trigger;
  const native = vm.runInNewContext(`(() => { ${sidebarScript}; return { activeTab, contactPanel, closeContactPanel }; })()`, {
    useUISettings: () => ({ uiSettings, updateUISettings: value => { updates.push(value); Object.assign(uiSettings.value, value); } }),
    useWindowSize: () => ({ width: { value: width } }),
    computed: value => ({ get value() { return value(); } }),
    ref: value => ({ value }),
    onMounted: callback => mounted.push(callback),
    onBeforeUnmount: callback => beforeUnmount.push(callback),
    nextTick: callback => ticks.push(callback),
    useEventListener: (target, type, handler) => {
      assert.equal(target, document);
      listeners.set(type, handler);
    },
    document,
  });
  function flushTicks() {
    while (ticks.length) ticks.shift()();
  }
  return {
    native, updates, document, trigger, panel, closeButton, outsideInput, body, focusCalls,
    element, flushTicks,
    dispatchPanelKey: event => listeners.get('keydown')(event),
    childOverlay(selector, { teleported = false, shown = true } = {}) {
      const child = element(selector, teleported ? body : panel, [selector]);
      child.visible = shown;
      const input = element('child search input', child);
      return {
        child, input,
        close() {
          child.visible = false;
          // Hiding a focused native input gives focus back to the document.
          if (child.contains(document.activeElement)) document.activeElement = body;
        },
      };
    },
    mount({ flush = true } = {}) {
      native.contactPanel.value = panel;
      mounted.forEach(callback => callback());
      if (flush) flushTicks();
    },
    unmount() {
      beforeUnmount.forEach(callback => callback());
      panel.isConnected = false;
      closeButton.isConnected = false;
      if (panel.contains(document.activeElement)) document.activeElement = body;
      native.contactPanel.value = null;
      listeners.clear();
      flushTicks();
    },
    key(overrides = {}) {
      let prevented = 0;
      let stopped = 0;
      const event = {
        key: 'Escape', defaultPrevented: false, isComposing: false, target: document.activeElement,
        preventDefault() { prevented += 1; this.defaultPrevented = true; },
        stopPropagation() { stopped += 1; },
        ...overrides,
      };
      assert.ok(listeners.has('keydown'), 'exercise the registered document keyboard handler');
      listeners.get('keydown')(event);
      return { prevented, stopped };
    },
  };
}

for (const width of [390, 767, 768, 1023, 1024, 1179, 1180, 1279, 1280, 1440]) {
  const overlay = width < 1280;
  assert.equal(sidebarPositionAt(width), overlay ? 'fixed' : 'static', `${width}px contact details must preserve conversation width`);
  const fixture = sidebarFixture({ width });
  const { native, updates } = fixture;
  fixture.mount();
  assert.equal(native.activeTab.value, 0);
  assert.equal(fixture.document.activeElement, overlay ? fixture.closeButton : fixture.trigger, `${width}px mount must focus only an overlay`);
  native.closeContactPanel();
  assert.equal(updates.length, overlay ? 1 : 0, `${width}px outside-click behavior must match the panel layout`);
  assert.equal(native.activeTab.value, overlay ? null : 0);
  if (overlay) {
    assert.deepEqual(JSON.parse(JSON.stringify(updates[0])), { is_contact_sidebar_open: false, is_copilot_panel_open: false }, 'close only the panel flags');
    native.closeContactPanel();
    assert.equal(updates.length, 1, 'closing an already closed panel must not write settings again');
  }
  fixture.unmount();
}

for (const width of [390, 768, 1024, 1279]) {
  for (const origin of ['contact switch', 'reply editor']) {
    const fixture = sidebarFixture({ width, origin });
    fixture.mount();
    assert.equal(fixture.document.activeElement, fixture.closeButton, 'opening the overlay moves keyboard focus to its close control');
    assert.deepEqual(JSON.parse(JSON.stringify(fixture.focusCalls[0].options)), { preventScroll: true });
    assert.deepEqual(fixture.key(), { prevented: 1, stopped: 1 }, 'Escape closes the visible overlay and consumes the event');
    assert.equal(fixture.native.activeTab.value, null);
    assert.equal(fixture.updates.length, 1);
    fixture.unmount();
    assert.equal(fixture.document.activeElement, fixture.trigger, `closing must restore the actual ${origin} at ${width}px`);
    assert.deepEqual(JSON.parse(JSON.stringify(fixture.focusCalls.at(-1).options)), { preventScroll: true });
  }
}

for (const event of [{ key: 'Enter' }, { defaultPrevented: true }, { isComposing: true }]) {
  const fixture = sidebarFixture();
  fixture.mount();
  assert.deepEqual(fixture.key(event), { prevented: 0, stopped: 0 }, 'ordinary keys, nested-widget Escape, and IME composition retain their own behavior');
  assert.equal(fixture.updates.length, 0, 'a consumed or inapplicable key must leave the contact panel open');
  assert.equal(fixture.document.activeElement, fixture.closeButton);
  fixture.unmount();
}

for (const [name, selector] of [['label', '.label-wrap > .absolute']]) {
  const fixture = sidebarFixture();
  fixture.mount();
  const dropdown = fixture.childOverlay(selector);
  dropdown.input.focus();
  // The parent's document keydown must leave the native label child mounted
  // long enough for its own Escape listener to close it.
  assert.deepEqual(fixture.key(), { prevented: 0, stopped: 0 }, `${name} receives its first Escape`);
  assert.equal(fixture.native.activeTab.value, 0, `${name} keydown must not unmount the inspector before child keyup`);
  assert.equal(fixture.updates.length, 0);
  dropdown.close();
  assert.equal(dropdown.child.getClientRects().length, 0, `${name} closes on its native keyup`);
  assert.deepEqual(fixture.key(), { prevented: 1, stopped: 1 }, `the next Escape closes the inspector after ${name} is hidden`);
  fixture.unmount();
  assert.equal(fixture.document.activeElement, fixture.trigger, `keyboard dismissal after ${name} must restore its original trigger`);
}

const multiselect = fs.readFileSync(path.join(overlayRoot, 'app/javascript/shared/components/ui/MultiselectDropdown.vue'), 'utf8');
const multiselectScript = multiselect.slice(multiselect.indexOf('const emit ='), multiselect.indexOf('const hasValue ='));
assert.ok(multiselectScript.startsWith('const emit ='), 'load the actual dropdown setup and handlers');
const escapeBinding = multiselect.match(/@(keydown|keyup)\.esc="([^"]+)"/);
assert.ok(escapeBinding, 'exercise the Escape handler bound by the actual template');
assert.match(multiselect, /<Button\s+ref="dropdownTrigger"/, 'focus restoration must target the native trigger button');

function multiselectFixture({ width = 1279, binding = escapeBinding[1], parentFirst = false } = {}) {
  const fixture = sidebarFixture({ width });
  fixture.mount();
  const wrapper = fixture.element('multiselect', fixture.panel);
  const trigger = fixture.element('dropdown trigger', wrapper);
  const child = fixture.element('dropdown items', wrapper, ['.dropdown-wrap']);
  const input = fixture.element('dropdown search', child);
  input.tagName = 'INPUT';
  input.blur = () => { fixture.document.activeElement = fixture.body; };
  const selected = [];
  const pending = [];
  const visible = { value: true };
  const native = vm.runInNewContext(`(() => { ${multiselectScript}; return { showSearchDropdown, dropdownTrigger, onCloseDropdown, onClickSelectItem, ${escapeBinding[2]} }; })()`, {
    defineEmits: () => (...args) => selected.push(args),
    ref: value => ({ value }),
    useToggle: () => [visible, value => {
      visible.value = value === undefined ? !visible.value : value;
      pending.push(() => {
        child.visible = visible.value;
        if (!child.visible && child.contains(fixture.document.activeElement)) input.blur();
      });
    }],
    nextTick: callback => pending.push(callback),
  });
  native.dropdownTrigger.value = { $el: trigger };
  input.focus();
  function press(key = 'Escape', overrides = {}) {
    const events = [];
    for (const type of ['keydown', 'keyup']) {
      const event = {
        type, key, target: fixture.document.activeElement,
        defaultPrevented: false, propagationStopped: false, isComposing: false,
        preventDefault() { this.defaultPrevented = true; },
        stopPropagation() { this.propagationStopped = true; },
        ...overrides,
      };
      for (let node = event.target; node; node = node.parent) {
        if (node === wrapper && type === binding && key === 'Escape') native[escapeBinding[2]](event);
        if (event.propagationStopped) break;
      }
      if (type === 'keydown' && !event.propagationStopped) {
        // Match the existing document shortcut boundary: useKeyboardEvents
        // blurs a typeable Escape target even when its own popup is closed.
        const documentShortcut = () => {
          if (event.key === 'Escape' && event.target.tagName === 'INPUT') event.target.blur();
        };
        if (parentFirst) fixture.dispatchPanelKey(event);
        documentShortcut();
        if (!parentFirst) fixture.dispatchPanelKey(event);
      }
      while (pending.length) pending.shift()();
      fixture.flushTicks();
      events.push(event);
    }
    return events;
  }
  return { ...fixture, dropdown: native, dropdownTrigger: trigger, child, input, selected, press };
}

// A real key cycle targets keyup at the element focused after keydown. This
// negative control reproduces the old blur-to-BODY failure without manually
// closing the child, then the same cycle exercises the production fix.
{
  const legacy = multiselectFixture({ binding: 'keyup' });
  const events = legacy.press();
  assert.equal(events[1].target, legacy.body);
  assert.equal(legacy.dropdown.showSearchDropdown.value, true, 'keyup-only Escape loses the child after document blur');
  assert.equal(legacy.native.activeTab.value, 0);
  legacy.unmount();
}
for (const width of [390, 1279, 1440]) {
  for (const parentFirst of [false, true]) {
    const fixture = multiselectFixture({ width, parentFirst });
    const events = fixture.press();
    assert.equal(events[0].defaultPrevented, true, 'the open child owns Escape before document shortcuts');
    assert.equal(events[0].propagationStopped, true);
    assert.equal(fixture.dropdown.showSearchDropdown.value, false, 'the actual child handler closes the dropdown');
    assert.equal(fixture.child.getClientRects().length, 0);
    assert.equal(events[1].target, fixture.dropdownTrigger, 'keyup reaches the restored trigger rather than BODY');
    assert.equal(fixture.document.activeElement, fixture.dropdownTrigger);
    assert.equal(fixture.native.activeTab.value, 0, 'the first Escape preserves the contact panel');
    assert.equal(fixture.selected.length, 0, 'keyboard dismissal must never select or mutate an assignee');
    fixture.press();
    assert.equal(fixture.native.activeTab.value, width < 1280 ? null : 0, 'closed dropdown Escape reaches the parent breakpoint behavior');
    fixture.unmount();
    if (width < 1280) assert.equal(fixture.document.activeElement, fixture.trigger);
  }
}
for (const overrides of [{ isComposing: true }, { isComposing: false, keyCode: 229 }]) {
  const fixture = multiselectFixture();
  const [keydown] = fixture.press('Escape', overrides);
  assert.equal(keydown.defaultPrevented, false, 'IME cancellation remains unconsumed by the dropdown');
  assert.equal(keydown.propagationStopped, false);
  assert.equal(fixture.dropdown.showSearchDropdown.value, true);
  fixture.unmount();
}
{
  const fixture = multiselectFixture();
  const [keydown] = fixture.press('Enter');
  assert.equal(keydown.defaultPrevented, false, 'ordinary keys retain native input behavior');
  assert.equal(fixture.dropdown.showSearchDropdown.value, true);
  const selected = { id: 7, name: 'Agent' };
  fixture.dropdown.onClickSelectItem(selected);
  assert.equal(fixture.dropdown.showSearchDropdown.value, false);
  assert.deepEqual(fixture.selected, [['select', selected]], 'ordinary selection retains its existing event and closes');
  fixture.unmount();
}

for (const childFirst of [false, true]) {
  const fixture = sidebarFixture();
  fixture.mount();
  const popover = fixture.childOverlay('[data-popover-content]', { teleported: true });
  popover.input.focus();
  const target = popover.input;
  // Popover's native document Escape handler hides without preventDefault.
  // Preserve the original event target even if that listener ran first.
  if (childFirst) popover.close();
  assert.deepEqual(fixture.key({ target }), { prevented: 0, stopped: 0 }, 'a teleported popover owns Escape in either document-listener order');
  assert.equal(fixture.updates.length, 0, 'hiding the popover must not collapse its inspector on the same Escape');
  if (!childFirst) popover.close();
  assert.deepEqual(fixture.key(), { prevented: 1, stopped: 1 });
  fixture.unmount();
  assert.equal(fixture.document.activeElement, fixture.trigger);
}

for (const [selector, teleported] of [
  ['.fixed.z-50', false],
  ['.modal-container', true],
  ['dialog.ProseMirror-prompt-backdrop', true],
  ['[data-popover-backdrop]', true],
]) {
  const fixture = sidebarFixture();
  fixture.mount();
  const modal = fixture.childOverlay(selector, { teleported });
  assert.deepEqual(fixture.key(), { prevented: 0, stopped: 0 }, `${selector} keeps priority even when focus remains in the inspector`);
  assert.equal(fixture.updates.length, 0);
  modal.close();
  assert.deepEqual(fixture.key(), { prevented: 1, stopped: 1 });
  fixture.unmount();
  assert.equal(fixture.document.activeElement, fixture.trigger);
}

{
  const fixture = sidebarFixture();
  fixture.mount();
  for (const selector of ['.dropdown-wrap', '.label-wrap > .absolute', '.fixed.z-50']) {
    fixture.childOverlay(selector, { shown: false });
  }
  for (const selector of ['[data-popover-content]', '[data-popover-backdrop]', 'dialog.ProseMirror-prompt-backdrop', '.modal-container']) {
    fixture.childOverlay(selector, { teleported: true, shown: false });
  }
  assert.deepEqual(fixture.key(), { prevented: 1, stopped: 1 }, 'hidden child shells must not block inspector Escape');
  fixture.unmount();
  assert.equal(fixture.document.activeElement, fixture.trigger);
}

for (const options of [{ width: 1280 }, { width: 1440 }, { width: 390, visible: false }]) {
  const fixture = sidebarFixture(options);
  fixture.mount();
  assert.equal(fixture.focusCalls.length, 0, 'desktop and hidden contact panels must not steal focus');
  assert.deepEqual(fixture.key(), { prevented: 0, stopped: 0 }, 'desktop and hidden panels must not consume Escape');
  assert.equal(fixture.updates.length, 0);
  fixture.unmount();
  assert.equal(fixture.focusCalls.length, 0, 'unmount must leave externally owned focus alone');
}

{
  const fixture = sidebarFixture();
  fixture.mount();
  fixture.outsideInput.focus();
  fixture.native.closeContactPanel();
  fixture.unmount();
  assert.equal(fixture.document.activeElement, fixture.outsideInput, 'outside-click dismissal must preserve the input selected by that click');
  assert.equal(fixture.focusCalls.length, 2, 'outside dismissal must not refocus the original trigger');
}

{
  const fixture = sidebarFixture();
  fixture.mount();
  fixture.document.activeElement = fixture.body;
  fixture.native.closeContactPanel();
  fixture.unmount();
  assert.equal(fixture.document.activeElement, fixture.body, 'outside-click dismissal on the page must not activate keyboard-only focus restoration');
  assert.equal(fixture.focusCalls.length, 1);
}

{
  const fixture = sidebarFixture();
  fixture.mount();
  fixture.document.activeElement = fixture.body;
  fixture.key();
  fixture.outsideInput.focus();
  fixture.unmount();
  assert.equal(fixture.document.activeElement, fixture.outsideInput, 'an input selected after Escape but before unmount must retain focus');
  assert.equal(fixture.focusCalls.length, 2);
}

{
  const fixture = sidebarFixture();
  fixture.mount();
  fixture.trigger.isConnected = false;
  fixture.key();
  fixture.unmount();
  assert.equal(fixture.focusCalls.length, 1, 'a trigger removed by navigation must not receive focus');
  assert.equal(fixture.document.activeElement, fixture.body);
}

{
  const fixture = sidebarFixture({ hasCloseButton: false });
  fixture.mount();
  assert.equal(fixture.document.activeElement, fixture.panel, 'the focusable panel remains a fallback while its close control is unavailable');
  fixture.unmount();
  assert.equal(fixture.document.activeElement, fixture.trigger);
}

{
  const fixture = sidebarFixture();
  fixture.mount({ flush: false });
  fixture.unmount();
  assert.equal(fixture.focusCalls.length, 0, 'unmounting before the next tick must not focus a removed panel');
}
for (const ignore of ['dialog.ProseMirror-prompt-backdrop', '[data-popover-content]', '[data-popover-backdrop]']) {
  assert.ok(sidebar.includes(`'${ignore}'`), 'editing contact details inside an existing popover must not close the panel');
}
assert.match(sidebar, /:conversation-id="currentChat.id"/);
assert.match(sidebar, /:inbox-id="currentChat.inbox_id"/);
assert.match(sidebar, /ref="contactPanel"/);
assert.match(sidebar, /tabindex="-1"/);
assert.match(sidebar, /:role="isSmallScreen \? 'dialog' : 'complementary'"/);
const actionsHeader = fs.readFileSync(path.join(overlayRoot, 'app/javascript/dashboard/components-next/SidebarActionsHeader.vue'), 'utf8');
assert.match(actionsHeader, /data-sidebar-close\s+:aria-label="\$t\('GENERAL.CLOSE'\)"/);
const sidepanelSwitch = fs.readFileSync(path.join(overlayRoot, 'app/javascript/dashboard/components-next/Conversation/SidepanelSwitch.vue'), 'utf8');
assert.match(sidepanelSwitch, /:aria-label="\$t\('CONVERSATION.SIDEBAR.CONTACT'\)"\s+:aria-expanded="isContactSidebarOpen"/);

console.log('TOYBACO_CHATWOOT_REPLY_BOX=PASS ime=guarded enter-and-command-enter=preserved contact-panel=overlay-below-xl contact-keyboard=escape-and-focus-restoration dropdown-keyboard=keydown-close-and-trigger-focus');
