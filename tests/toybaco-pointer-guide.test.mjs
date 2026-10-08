import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  GuideRegistry,
  PointerGuide,
  guidePosition,
  slotPlacement,
  waitingPosition,
} from '../overlay/app/public/brand-assets/toybaco-pointer-guide.mjs';

const target = (left, top, width, height) => ({
  left,
  top,
  width,
  height,
  right: left + width,
  bottom: top + height,
});
const panel = { width: 280, height: 100 };

test('guide stays above a bottom action without covering the control', () => {
  const action = target(250, 610, 160, 48);
  const position = guidePosition(action, panel, { width: 800, height: 700 });
  assert(position.top + panel.height < action.top);
  assert(position.left + panel.width <= 784);
});

test('mobile keyboard offset constrains both axes inside the visible viewport', () => {
  const action = target(30, 180, 280, 44);
  const position = guidePosition(action, panel, {
    left: 0,
    top: 100,
    width: 360,
    height: 300,
  });
  assert(position.top >= 116);
  assert(position.top + panel.height <= 384);
  assert(position.left >= 16);
  assert(position.left + panel.width <= 344);
});

test('crowded viewport yields no floating prompt instead of covering input', () => {
  assert.equal(
    guidePosition(target(20, 30, 280, 80), panel, { width: 320, height: 140 }),
    null
  );
});

test('guide avoids adjacent AI and send buttons while explaining an editor', () => {
  const editor = target(360, 300, 550, 100);
  const actions = [target(360, 430, 180, 48), target(840, 430, 70, 48)];
  const position = guidePosition(
    editor,
    panel,
    { width: 1280, height: 720 },
    actions
  );
  assert(position.top + panel.height < editor.top);
});

test('targets must be visible, enabled, registered and unique in their own document', () => {
  const doc = {
    defaultView: {
      getComputedStyle: () => ({ visibility: 'visible', display: 'block' }),
    },
  };
  const element = () => ({
    isConnected: true,
    ownerDocument: doc,
    disabled: false,
    getAttribute: () => null,
    getBoundingClientRect: () => target(20, 20, 100, 40),
  });
  const registry = new GuideRegistry();
  const first = element();
  const remove = registry.register('connection.google', first);
  assert.equal(registry.find('invented.action', doc), null);
  assert.equal(registry.find('connection.google', doc), first);
  const second = element();
  const removeSecond = registry.register('connection.google', second);
  assert.equal(registry.find('connection.google', doc), null);
  removeSecond();
  first.disabled = true;
  assert.equal(registry.find('connection.google', doc), null);
  first.disabled = false;
  assert.equal(registry.find('connection.google', {}), null);
  remove();
  assert.equal(registry.find('connection.google', doc), null);
  assert.throws(() => registry.register('#billing button', first));
});

test('actual staging full-width reply toolbar leaves room above the editor center', () => {
  const editor = target(193, 719, 1582, 96);
  const prompt = { width: 281, height: 83 };
  const actions = [target(193, 606, 37, 20), target(238, 604, 100, 44),
    target(394, 603, 57, 26), target(456, 603, 57, 26),
    target(195, 688, 178, 28), target(1713, 688, 28, 28), target(1749, 688, 28, 28),
    editor, target(193, 823, 136, 28), target(1670, 823, 105, 28)];
  const position = guidePosition(editor, prompt, { width: 1800, height: 872 }, actions);
  assert(position, 'a visible editor must not remain waiting when its center has room');
  assert.equal(position.top, 620);
  assert(position.left > 513);
  assert(position.left + prompt.width < 1713);
  for (const box of actions) {
    assert(position.left >= box.right + 4 || position.left + prompt.width <= box.left - 4 ||
      position.top >= box.bottom + 4 || position.top + prompt.height <= box.top - 4);
  }
});

test('right aligned space remains available when left and middle are occupied', () => {
  const editor = target(100, 600, 1100, 100);
  const position = guidePosition(editor, panel, { width: 1280, height: 750 }, [target(100, 480, 700, 104)]);
  assert.deepEqual(position, { left: 920, top: 484 });
});

test('a prompt wider than the visible mobile viewport never escapes its bounds', () => {
  assert.equal(guidePosition(target(16, 200, 180, 40), panel, { width: 260, height: 700 }), null);
});

const intersects = (a, b) =>
  a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top;
const WAITING = '対象の画面に戻ると案内を再開します。';

test('the reserved place puts the prompt under the heading and keeps its height', () => {
  assert.deepEqual(slotPlacement(target(353, 272, 574, 0), { width: 574, height: 82.4 }),
    { left: 353, top: 272, width: 574, reserve: 99 });
  // The staging purpose step: eyebrow y188, heading y216-255, first choice y271 (before the place is kept).
  for (const [width, h1] of [[1280, target(353, 216.8, 574, 39)], [390, target(37, 168.8, 316, 33)]]) {
    const slot = target(h1.left, h1.bottom + 16, h1.width, 0);
    const place = slotPlacement(slot, { width: h1.width, height: 105 });
    const prompt = target(place.left, place.top, place.width, 105);
    const choice = target(slot.left, slot.top + place.reserve, slot.width, 83);
    assert(!intersects(prompt, h1), `${width}: prompt below the heading`);
    assert(!intersects(prompt, choice), `${width}: prompt above the first choice`);
    assert(choice.top - prompt.bottom >= 16, `${width}: one gap before the choices`);
  }
});

test('a paused prompt goes top right below the header link instead of over the logo', () => {
  const logo = target(192, 28, 152, 67.4);
  const later = target(1010, 50.7, 78, 22.1);
  const header = target(160, 0, 960, 123.4);
  const position = waitingPosition(panel, { width: 1280, height: 800 }, [header, logo], [later]);
  assert.deepEqual(position, { left: 984, top: 139.4 });
  const prompt = target(position.left, position.top, panel.width, panel.height);
  for (const box of [logo, later, header]) assert(!intersects(prompt, box));
  assert(intersects(target(16, 16, panel.width, panel.height), logo), 'the former top-left place covered the logo');
});

// A10-3: full-width headers and rows of full-width links must not hide the paused prompt.
test('a paused prompt stays visible under a full-width header over full-width rows of links', () => {
  const header = target(0, 0, 1280, 64);
  const rows = Array.from({ length: 14 }, (_, index) => target(0, 64 + index * 48, 1280, 48));
  const position = waitingPosition(panel, { width: 1280, height: 800 }, [header], rows);
  assert.deepEqual(position, { left: 984, top: 80 });
  assert(!intersects(target(position.left, position.top, panel.width, panel.height), header));
  // 390 wide: the same list on a phone keeps the prompt visible under the header as well.
  const phone = waitingPosition(panel, { width: 390, height: 844 }, [target(0, 0, 390, 96)],
    Array.from({ length: 16 }, (_, index) => target(0, 96 + index * 48, 390, 48)));
  assert.deepEqual(phone, { left: 94, top: 112 });
});

test('a paused prompt takes the free middle column when controls fill the right column', () => {
  // Conversation screen with the contact panel open: the right column is links and buttons from top to bottom.
  const sidebar = target(0, 0, 200, 96);
  const contact = Array.from({ length: 20 }, (_, index) => target(960, index * 40, 320, 36));
  const conversationId = target(560, 30, 40, 14);
  const actions = target(880, 10, 70, 30);
  const position = waitingPosition(panel, { width: 1280, height: 800 }, [sidebar], [...contact, conversationId, actions]);
  assert.deepEqual(position, { left: 500, top: 60 });
  const prompt = target(position.left, position.top, panel.width, panel.height);
  for (const box of [sidebar, ...contact, conversationId, actions]) assert(!intersects(prompt, box));
});

test('a paused prompt is hidden only when the viewport cannot hold it under the logo and the header', () => {
  assert.deepEqual(waitingPosition(panel, { width: 1280, height: 800 }), { left: 984, top: 16 });
  assert.equal(waitingPosition(panel, { width: 260, height: 700 }), null, 'wider than the viewport');
  assert.equal(waitingPosition({ width: 0, height: 0 }, { width: 1280, height: 800 }), null, 'no size to place');
  assert.equal(waitingPosition(panel, { width: 390, height: 300 }, [target(0, 0, 390, 200)]), null, 'under the header there is no room');
  // Controls alone never hide it: with no free place it stays at the right under the logo and the header.
  assert.deepEqual(waitingPosition(panel, { width: 390, height: 300 }, [], [target(0, 40, 390, 240)]), { left: 94, top: 16 });
});

test('a paused prompt ignores broken boxes and stops on a huge stack of controls', () => {
  const broken = [target(NaN, 0, 100, 100), target(0, Infinity, 100, 100), target(900, 16, 0, 40), target(900, 16, 300, 0)];
  assert.deepEqual(waitingPosition(panel, { width: 1280, height: 800 }, broken, broken), { left: 984, top: 16 });
  const stack = Array.from({ length: 10000 }, (_, index) => target(0, index * 0.08, 1280, 0.5));
  const started = Date.now();
  assert.deepEqual(waitingPosition(panel, { width: 1280, height: 800 }, [], stack), { left: 984, top: 16 });
  assert(Date.now() - started < 2000, 'bounded work');
});

test('a paused prompt never covers the logo or the header and stays inside the viewport', () => {
  let seed = 7;
  const random = () => ((seed = (seed * 48271) % 2147483647) / 2147483647);
  const boxes = (viewport, count) => Array.from({ length: count }, () =>
    target(random() * viewport.width, viewport.top + random() * viewport.height, 20 + random() * 400, 10 + random() * 120));
  for (let round = 0; round < 300; round += 1) {
    const viewport = { left: 0, top: random() * 80, width: 320 + random() * 1500, height: 300 + random() * 700 };
    const marks = boxes(viewport, Math.floor(random() * 3));
    const controls = boxes(viewport, Math.floor(random() * 10));
    const position = waitingPosition(panel, viewport, marks, controls);
    // Visible whenever the right column has room under the logo and the header (landmark-only candidates).
    const right = viewport.width - 16 - panel.width;
    const room = [viewport.top + 16, ...marks.map((box) => box.bottom + 16)].some((top) =>
      top + panel.height <= viewport.top + viewport.height - 16 &&
      !marks.some((box) => intersects(target(right - 4, top - 4, panel.width + 8, panel.height + 8), box)));
    if (room) assert(position, JSON.stringify({ viewport, marks }));
    if (!position) continue;
    const prompt = target(position.left, position.top, panel.width, panel.height);
    assert([right, (viewport.width - panel.width) / 2].includes(position.left));
    assert(prompt.top >= viewport.top + 16 && prompt.bottom <= viewport.top + viewport.height - 16);
    for (const box of marks) assert(!intersects(prompt, box), JSON.stringify({ viewport, box, position }));
  }
});

// A small document for PointerGuide: each page element has a box, the prompt's box follows its own style and text,
// and hit testing follows the boxes the way the browser does.
function fakeDocument(width, height) {
  const frames = [];
  const resizers = [];
  const win = {
    innerWidth: width,
    innerHeight: height,
    requestAnimationFrame: (callback) => frames.push(callback),
    cancelAnimationFrame() {},
    addEventListener() {},
    removeEventListener() {},
    matchMedia: () => ({ matches: false }),
    getComputedStyle: (element) => ({
      visibility: 'visible', display: 'block', opacity: '1', minHeight: `${element.minHeight || 0}px`,
    }),
    MutationObserver: class { observe() {} disconnect() {} },
    ResizeObserver: class {
      constructor(callback) { Object.assign(this, { callback, targets: new Set(), disconnected: false }); resizers.push(this); }
      observe(element) { this.targets.add(element); }
      unobserve(element) { this.targets.delete(element); }
      disconnect() { this.targets.clear(); this.disconnected = true; }
    },
  };
  // fontScale stands for a web font that draws wider than the fallback font it replaces.
  const doc = { defaultView: win, activeElement: null, fontScale: 1, addEventListener() {}, removeEventListener() {} };
  class Element {
    constructor(tag, attributes = {}, box = () => target(0, 0, 0, 0)) {
      Object.assign(this, { tagName: tag, attributes, box, ownerDocument: doc, parent: null, children: [],
        style: {}, hidden: false, disabled: false, textContent: '', className: '', id: '' });
    }
    get isConnected() {
      for (let node = this; node; node = node.parent) if (node === doc.body) return true;
      return false;
    }
    get shown() {
      for (let node = this; node; node = node.parent) if (node.hidden) return false;
      return true;
    }
    get parentElement() { return this.parent; }
    // Controls drawn invisible until hover (opacity 0) report false, like Element.checkVisibility.
    checkVisibility() { return !this.faded; }
    append(...nodes) { nodes.forEach((node) => { node.parent = this; this.children.push(node); }); }
    remove() { this.parent?.children.splice(this.parent.children.indexOf(this), 1); this.parent = null; }
    contains(node) { for (; node; node = node.parent) if (node === this) return true; return false; }
    setAttribute(name, value) { this.attributes[name] = String(value); }
    getAttribute(name) { return this.attributes[name] ?? null; }
    removeAttribute(name) { delete this.attributes[name]; }
    addEventListener() {}
    getBoundingClientRect() {
      if (!this.shown) return target(0, 0, 0, 0);
      if (this.className !== 'toybaco-guide__panel') return this.box();
      // 14px text in a 12px/14px padded box: one line is 82.4px high, like the staging prompt.
      const text = [...this.children[0].textContent].length * 14 * doc.fontScale;
      const boxWidth = this.style.width ? parseFloat(this.style.width) : Math.min(parseFloat(this.style.maxWidth), text + 30);
      const lines = Math.max(1, Math.ceil(text / (boxWidth - 30)));
      return target(parseFloat(this.style.left) || 0, parseFloat(this.style.top) || 0, boxWidth, 60 + 22.4 * lines);
    }
  }
  const all = () => {
    const nodes = [];
    const walk = (node) => node.children.forEach((child) => { nodes.push(child); walk(child); });
    walk(doc.body);
    return nodes;
  };
  const matches = (node, selector) => selector.split(',').some((part) => {
    const [, tag, rest] = part.trim().match(/^([a-z0-9]*)(.*)$/);
    return (!tag || node.tagName === tag) && [...rest.matchAll(/\[([^\]=]+)(?:="([^"]*)")?\]/g)].every(
      ([, name, value]) => name in node.attributes && (value === undefined || node.attributes[name] === value));
  });
  Object.assign(doc, {
    body: new Element('body'),
    createElement: (tag) => new Element(tag),
    querySelectorAll: (selector) => all().filter((node) => matches(node, selector)),
    // Like the browser, a point outside the viewport hits nothing.
    elementsFromPoint: (x, y) => x < 0 || y < 0 || x >= width || y >= height ? [] : all().filter((node) => {
      const box = node.getBoundingClientRect();
      return box.width > 0 && box.height > 0 && x >= box.left && x < box.right && y >= box.top && y < box.bottom;
    }).reverse(),
  });
  const flush = () => {
    for (let round = 0; frames.length; round += 1) {
      assert(round < 20, 'the guide settles instead of scheduling itself forever');
      frames.splice(0).forEach((callback) => callback());
    }
  };
  // The browser reports size changes of observed elements; here every observer hears about all of them.
  const resize = () => resizers.filter((observer) => observer.targets.size).forEach((observer) => observer.callback([]));
  return { doc, Element, flush, resize, resizers };
}

// The first-run guide screen's column (ToybacoStart.vue CSS at 1280 and 390 wide). Page boxes read the height the
// guide keeps in the place, so the choices move down exactly as the real page does.
function guideScreen({ width, height, scroll = 0, cards = 2, kept = 0 }) {
  const { doc, Element, flush, resize, resizers } = fakeDocument(width, height);
  const page = { scroll };
  const wide = width > 680;
  const at = (left, top, boxWidth, boxHeight) => () => target(left, top - page.scroll, boxWidth, boxHeight);
  const headerLeft = wide ? Math.max(0, (width - 960) / 2) : 0;
  const headerWidth = Math.min(width, 960);
  const pad = wide ? [32, 28] : [20, 20];
  const headerHeight = pad[1] * 2 + 67.4;
  const mainLeft = wide ? (width - 640) / 2 : 12;
  const inset = (wide ? 32 : 24) + 1;
  const contentLeft = mainLeft + inset;
  const contentWidth = (wide ? 640 : width - 24) - inset * 2;
  const eyebrowTop = headerHeight + (wide ? 32 : 8) + inset;
  const h1Top = eyebrowTop + 20.4 + 8;
  const h1Height = wide ? 39 : 33;
  const slotTop = h1Top + h1Height + 16;
  // Like CSS: the place is as tall as the larger of the page's min-height and the height the guide added.
  const reserved = () => Math.max(slot.minHeight, parseFloat(slot.style.height) || 0);
  const cardTop = (index) => slotTop + reserved() + index * 95;
  const section = new Element('section', {}, () => target(0, 0, width, height));
  const header = new Element('header', {}, at(headerLeft, 0, headerWidth, headerHeight));
  const logo = new Element('img', { alt: 'トイバコ' }, at(headerLeft + pad[0], pad[1], 152, 67.4));
  const later = new Element('a', { href: '/app' }, at(headerLeft + headerWidth - pad[0] - 78, pad[1] + 22.6, 78, 22.1));
  const main = new Element('main', {}, at(mainLeft, eyebrowTop - inset, contentWidth + inset * 2, 4000));
  const eyebrow = new Element('p', {}, at(contentLeft, eyebrowTop, contentWidth, 20.4));
  const h1 = new Element('h1', {}, at(contentLeft, h1Top, contentWidth, h1Height));
  const place = () => {
    const element = new Element('div', { 'data-toybaco-guide-slot': '' }, () =>
      target(contentLeft, slotTop - page.scroll, contentWidth, reserved()));
    element.minHeight = kept;
    return element;
  };
  let slot = place();
  const choices = Array.from({ length: cards }, (_, index) =>
    new Element('button', {}, () => target(contentLeft, cardTop(index) - page.scroll, contentWidth, 83)));
  const skip = new Element('button', {}, () => target(contentLeft, cardTop(cards) + 8 - page.scroll, 150, 22.1));
  doc.body.append(section);
  section.append(header, main);
  header.append(logo, later);
  main.append(eyebrow, h1, slot, ...choices, skip);
  const registry = new GuideRegistry();
  const guide = new PointerGuide({ registry, document: doc });
  const prompt = () => guide.panel.getBoundingClientRect();
  // The next step renders its own place (Vue swaps the block); the old one leaves the document.
  const swapPlace = () => {
    const previous = slot;
    slot = place();
    main.children.splice(main.children.indexOf(previous), 1, slot);
    slot.parent = main;
    previous.parent = null;
    screen.slot = slot;
    return previous;
  };
  const screen = { doc, page, flush, resize, resizers, registry, guide, prompt, header, logo, later, eyebrow, h1, slot,
    choices, skip, main, swapPlace };
  return screen;
}

test('guide screen keeps the prompt under the heading and clear of every choice at 1280 and 390 wide', () => {
  for (const [width, height] of [[1280, 800], [390, 844]]) {
    const screen = guideScreen({ width, height });
    screen.registry.register('purpose.inbox', screen.choices[0]);
    screen.guide.show({ actionId: 'purpose.inbox', text: '最初に使いたい仕事を選んでください。' });
    screen.flush();
    const prompt = screen.prompt();
    assert.equal(screen.guide.text.textContent, '最初に使いたい仕事を選んでください。');
    assert.equal(screen.guide.panel.hidden, false);
    assert.deepEqual([prompt.left, prompt.width], [screen.h1.getBoundingClientRect().left, screen.h1.getBoundingClientRect().width]);
    assert(prompt.top >= screen.h1.getBoundingClientRect().bottom, `${width}: the prompt starts below the heading`);
    assert.equal(screen.slot.style.height, `${Math.ceil(prompt.height) + 16}px`);
    for (const box of [screen.header, screen.logo, screen.later, screen.eyebrow, screen.h1, ...screen.choices, screen.skip])
      assert(!intersects(prompt, box.getBoundingClientRect()), `${width}: the prompt covers nothing on the page`);
    // The outline still marks the first choice, which moved down below the kept place.
    const choice = screen.choices[0].getBoundingClientRect();
    assert.equal(screen.guide.outline.hidden, false);
    assert.equal(screen.guide.outline.style.top, `${choice.top - 5}px`);
    assert.equal(screen.choices[0].getAttribute('aria-describedby'), screen.guide.text.id);
  }
});

test('guide screen keeps the step under the heading while its target is below the fold, never the paused text', () => {
  const screen = guideScreen({ width: 1280, height: 600, cards: 4 });
  screen.registry.register('connection.google', screen.choices[3]);
  screen.guide.show({ actionId: 'connection.google', text: 'Googleのアカウントを選んで接続します。' });
  screen.flush();
  assert.equal(screen.guide.text.textContent, 'Googleのアカウントを選んで接続します。');
  assert.equal(screen.guide.panel.hidden, false);
  assert.equal(screen.guide.outline.hidden, true);
  assert.equal(screen.guide.pointer.hidden, true);
  for (const box of [screen.header, screen.logo, screen.later, screen.h1])
    assert(!intersects(screen.prompt(), box.getBoundingClientRect()), 'the step stays clear of the logo and header');
  // Scrolled away, the prompt leaves with its place; the place keeps its height so the page never jumps.
  const kept = screen.slot.style.height;
  screen.page.scroll = 500;
  screen.guide.update();
  assert.equal(screen.guide.panel.hidden, true);
  assert.equal(screen.slot.style.height, kept);
  // The target in view again shows the outline, and hiding the guide gives the place back to the page.
  screen.page.scroll = 200;
  screen.guide.update();
  assert.equal(screen.guide.outline.hidden, false);
  screen.guide.hide();
  assert.equal(screen.slot.style.height, '');
});

// A10-2: the page keeps the usual place (min-height 99px = one line 82.4px + 16px) before the prompt appears.
test('a place kept by the page shows the prompt without a shift and only a wrapped text adds height', () => {
  const screen = guideScreen({ width: 390, height: 844, kept: 99 });
  screen.registry.register('purpose.inbox', screen.choices[0]);
  const before = screen.choices[0].getBoundingClientRect().top;
  screen.guide.show({ actionId: 'purpose.inbox', text: '最初に使いたい仕事を選んでください。' });
  screen.flush();
  assert.equal(screen.choices[0].getBoundingClientRect().top, before, 'the choices stay where they were');
  assert.equal(screen.slot.style.height, '', 'nothing is added on top of the kept place');
  assert(!intersects(screen.prompt(), screen.choices[0].getBoundingClientRect()));
  // Two lines need more than the kept place: only the difference is added. A shorter text later does not
  // shrink it again while the place is in use, so the choices never jump back and forth.
  screen.guide.show({ actionId: 'purpose.inbox', text: 'お店情報を確認して保存してください。あとで変更できます。' });
  screen.flush();
  const grown = `${Math.ceil(screen.prompt().height) + 16}px`;
  assert.equal(screen.slot.style.height, grown);
  assert(screen.choices[0].getBoundingClientRect().top > before);
  assert(!intersects(screen.prompt(), screen.choices[0].getBoundingClientRect()));
  screen.guide.show({ actionId: 'purpose.inbox', text: '最初に使いたい仕事を選んでください。' });
  screen.flush();
  assert.equal(screen.slot.style.height, grown);
  // Hiding gives back only what the guide added; the page's own place stays as it is.
  screen.guide.hide();
  assert.equal(screen.slot.style.height, '');
  assert.equal(screen.choices[0].getBoundingClientRect().top, before);
});

test('reserve never shrinks a place the page keeps taller than the prompt', () => {
  const screen = guideScreen({ width: 1280, height: 800, kept: 140 });
  screen.registry.register('purpose.inbox', screen.choices[0]);
  const before = screen.choices[0].getBoundingClientRect().top;
  screen.guide.show({ actionId: 'purpose.inbox', text: '最初に使いたい仕事を選んでください。' });
  screen.flush();
  assert.equal(screen.slot.style.height, '');
  assert.equal(screen.choices[0].getBoundingClientRect().top, before);
  assert.equal(screen.slot.getBoundingClientRect().height, 140);
});

test('a paused prompt on other screens stays clear of the sidebar logo and the header', () => {
  const { doc, Element, flush } = fakeDocument(1280, 720);
  const sidebar = new Element('section', { 'data-toybaco-sidebar-header': '' }, () => target(0, 0, 200, 96));
  const account = new Element('button', {}, () => target(8, 8, 184, 32));
  // The header bar reaches below its buttons, so the prompt must clear the header itself, not only its controls.
  const header = new Element('header', {}, () => target(200, 0, 1080, 72));
  const resolve = new Element('button', {}, () => target(1150, 14, 110, 36));
  const editor = new Element('div', { contenteditable: 'true' }, () => target(220, 690, 1040, 96));
  doc.body.append(sidebar, header, editor);
  sidebar.append(account);
  header.append(resolve);
  const registry = new GuideRegistry();
  registry.register('reply.editor', editor);
  const guide = new PointerGuide({ registry, document: doc });
  guide.show({ actionId: 'reply.editor', text: 'ここに返信を入力してください。' });
  flush();
  const prompt = guide.panel.getBoundingClientRect();
  assert.equal(guide.text.textContent, WAITING);
  assert.equal(guide.panel.hidden, false);
  assert.equal(prompt.right, 1280 - 16);
  for (const box of [sidebar, account, header, resolve, editor])
    assert(!intersects(prompt, box.getBoundingClientRect()), 'the paused prompt covers no logo, header or control');
});

// A10-3: sizes change after the first measure (web font swap, wrapped text): the kept place follows.
test('a font swap that makes the prompt taller grows the kept place before it covers the choices', () => {
  const screen = guideScreen({ width: 390, height: 844, kept: 99 });
  screen.registry.register('purpose.inbox', screen.choices[0]);
  screen.guide.show({ actionId: 'purpose.inbox', text: '最初に使いたい仕事を選んでください。' });
  screen.flush();
  assert.equal(screen.slot.style.height, '');
  assert(screen.resizers.some((observer) => observer.targets.has(screen.guide.panel)), 'the prompt size is watched');
  assert(screen.resizers.some((observer) => observer.targets.has(screen.main)), 'the page around the place is watched');
  screen.doc.fontScale = 1.4;
  assert(intersects(screen.prompt(), screen.choices[0].getBoundingClientRect()), 'without a new measure it would cover');
  screen.resize();
  screen.flush();
  assert.equal(screen.slot.style.height, `${Math.ceil(screen.prompt().height) + 16}px`);
  for (const box of [screen.h1, ...screen.choices]) assert(!intersects(screen.prompt(), box.getBoundingClientRect()));
});

test('the place of the next step is found and the previous place is given back', () => {
  const screen = guideScreen({ width: 390, height: 844 });
  screen.registry.register('purpose.inbox', screen.choices[0]);
  screen.guide.show({ actionId: 'purpose.inbox', text: '最初に使いたい仕事を選んでください。' });
  screen.flush();
  const first = screen.slot;
  assert.equal(screen.guide.slotElement, first);
  const previous = screen.swapPlace();
  screen.guide.update();
  assert.equal(previous.style.height, '', 'the removed place is given back');
  assert.equal(screen.guide.slotElement, screen.slot, 'the new place is used');
  assert.equal(screen.slot.style.height, `${Math.ceil(screen.prompt().height) + 16}px`);
  assert(!screen.resizers.some((observer) => observer.targets.has(previous)));
  // A place removed with no successor is dropped as well; the prompt floats again.
  screen.main.children.splice(screen.main.children.indexOf(screen.slot), 1);
  const gone = screen.slot;
  gone.parent = null;
  screen.guide.update();
  assert.equal(screen.guide.slotElement, null);
  assert.equal(gone.style.height, '');
});

test('destroy gives the place back and stops watching sizes', () => {
  const screen = guideScreen({ width: 390, height: 844 });
  screen.registry.register('purpose.inbox', screen.choices[0]);
  screen.guide.show({ actionId: 'purpose.inbox', text: 'お店情報を確認して保存してください。あとで変更できます。' });
  screen.flush();
  assert.notEqual(screen.slot.style.height, '');
  screen.guide.destroy();
  assert.equal(screen.slot.style.height, '');
  assert.equal(screen.guide.slotElement, null);
  assert(screen.resizers.every((observer) => observer.disconnected));
  assert(!screen.doc.body.contains(screen.guide.panel));
});

// A10-3: the conversation screen of Chatwoot v4.18 with the contact panel open. The conversation header is a div
// with its actions on the right; the contact panel fills the right column with links and buttons.
function conversationScreen(width, height, { contactPanel = true } = {}) {
  const { doc, Element, flush } = fakeDocument(width, height);
  const wide = width >= 1280;
  const add = (parent, tag, attributes, box) => {
    const element = new Element(tag, attributes, () => box);
    parent.append(element);
    return element;
  };
  const marks = [];
  const controls = [];
  const app = add(doc.body, 'div', {}, target(0, 0, width, height));
  if (wide) {
    const sidebar = add(app, 'section', { 'data-toybaco-sidebar-header': '' }, target(0, 0, 200, 96));
    marks.push(sidebar);
    controls.push(add(sidebar, 'button', {}, target(8, 8, 184, 32)), add(sidebar, 'a', { href: '/search' }, target(8, 48, 184, 32)));
    controls.push(add(app, 'h1', {}, target(212, 16, 120, 24)));
  }
  const left = wide ? 540 : 0;
  const right = wide && contactPanel ? width - 320 : width;
  const headerHeight = wide ? 48 : 96;
  controls.push(add(app, 'button', {}, target(left + 12, wide ? 12 : 30, 24, 24)));
  controls.push(add(app, 'button', {}, target(left + 90, wide ? 30 : 46, 44, 14)));
  controls.push(add(app, 'button', {}, target(wide ? right - 80 : 12, wide ? 10 : 60, 32, 32)));
  controls.push(add(app, 'button', {}, target(wide ? right - 44 : 52, wide ? 10 : 60, 32, 32)));
  controls.push(add(app, 'button', {}, target(right - 44, wide ? 96 : 144, 36, 72)));
  if (contactPanel && wide) {
    for (let index = 0; index < 20; index += 1)
      controls.push(add(app, index % 2 ? 'a' : 'button', index % 2 ? { href: '#' } : {}, target(width - 320, index * 40, 320, 36)));
  }
  const editor = add(app, 'div', { contenteditable: 'true' }, target(left + 12, height - 150, right - left - 24, 96));
  // A popover over the editor (emoji picker, mention list): the target is found but cannot be pointed at.
  add(app, 'div', {}, target((left + right) / 2 - 160, height - 260, 320, 200));
  const registry = new GuideRegistry();
  registry.register('reply.editor', editor);
  const guide = new PointerGuide({ registry, document: doc });
  guide.show({ actionId: 'reply.editor', text: 'ここに返信を入力してください。' });
  flush();
  return { guide, marks, controls, prompt: guide.panel.getBoundingClientRect() };
}

test('the paused prompt stays visible on the conversation screen and at 390 wide, clear of the logo and header', () => {
  for (const [width, height, contactPanel] of [[1280, 720, true], [1280, 720, false], [390, 844, false]]) {
    const screen = conversationScreen(width, height, { contactPanel });
    const label = `${width}x${height} contact panel ${contactPanel}`;
    assert.equal(screen.guide.text.textContent, WAITING, label);
    assert.equal(screen.guide.panel.hidden, false, `${label}: visible`);
    for (const mark of screen.marks) assert(!intersects(screen.prompt, mark.getBoundingClientRect()), `${label}: logo and header`);
    for (const control of screen.controls) assert(!intersects(screen.prompt, control.getBoundingClientRect()), `${label}: controls`);
    assert(screen.prompt.left >= 16 && screen.prompt.right <= width - 16 && screen.prompt.top >= 16 && screen.prompt.bottom <= height - 16);
  }
});

test('only the logo and the header push the paused prompt down, not a full-width page title', () => {
  const { doc, Element, flush } = fakeDocument(1280, 720);
  const title = new Element('h1', {}, () => target(240, 16, 1016, 40));
  const editor = new Element('div', { contenteditable: 'true' }, () => target(40, 600, 1200, 96));
  const cover = new Element('div', {}, () => target(500, 560, 300, 160));
  doc.body.append(title, editor, cover);
  const registry = new GuideRegistry();
  registry.register('reply.editor', editor);
  const guide = new PointerGuide({ registry, document: doc });
  guide.show({ actionId: 'reply.editor', text: 'ここに返信を入力してください。' });
  flush();
  assert.equal(guide.text.textContent, WAITING);
  assert.equal(guide.panel.getBoundingClientRect().top, 16, 'a block-level title spans the width; it is not a landmark');
});

test('a control drawn only on hover does not push the paused prompt away', () => {
  const { doc, Element, flush } = fakeDocument(1280, 720);
  const menu = new Element('button', {}, () => target(1000, 16, 264, 84));
  const editor = new Element('div', { contenteditable: 'true' }, () => target(40, 600, 1200, 96));
  const cover = new Element('div', {}, () => target(500, 560, 300, 160));
  doc.body.append(menu, editor, cover);
  menu.faded = true;
  const registry = new GuideRegistry();
  registry.register('reply.editor', editor);
  const guide = new PointerGuide({ registry, document: doc });
  guide.show({ actionId: 'reply.editor', text: 'ここに返信を入力してください。' });
  flush();
  assert.equal(guide.text.textContent, WAITING);
  assert.equal(guide.panel.getBoundingClientRect().top, 16, 'an invisible control is not a reason to move');
  menu.faded = false;
  guide.update();
  assert.equal(guide.panel.getBoundingClientRect().top, 116, 'a visible control is');
});

// 段 1a: on the real dashboard the tour card (ToybacoTour) carries the words and the buttons, and the guide only
// lights the step's target. The page behind stays usable (the dim takes no click) and Escape belongs to the card.
test('spotlight lights the target without a prompt or a pointer and leaves Escape to the tour card', () => {
  const { doc, Element, flush } = fakeDocument(1280, 800);
  const keys = [];
  doc.addEventListener = (type, listener) => { if (type === 'keydown') keys.push(listener); };
  const link = new Element('a', {}, () => target(16, 300, 200, 36));
  doc.body.append(link);
  const registry = new GuideRegistry();
  registry.register('sidebar.store_facts', link);
  let dismissed = 0;
  const guide = new PointerGuide({ registry, document: doc, onDismiss: () => { dismissed += 1; } });
  guide.spotlight({ actionId: 'sidebar.store_facts', dim: 'strong' });
  flush();
  assert.equal(guide.root.hidden, false);
  assert.equal(guide.root.getAttribute('data-spotlight'), 'strong');
  assert.equal(guide.panel.hidden, true, 'no prompt: the card speaks');
  assert.equal(guide.pointer.hidden, true, 'no pointer');
  assert.equal(guide.outline.hidden, false);
  assert.deepEqual(guide.outline.style, { left: '11px', top: '295px', width: '210px', height: '46px' });
  assert.equal(link.getAttribute('aria-describedby'), null, 'no prompt text describes the target');
  keys.forEach((listener) => listener({ key: 'Escape' }));
  assert.equal(dismissed, 0, 'Escape is the card’s「あとで続ける」');
  assert.equal(guide.root.hidden, false);
  // The soft dim is the default; a dim the stylesheet does not know is refused like an unknown target.
  guide.spotlight({ actionId: 'sidebar.store_facts' });
  assert.equal(guide.root.getAttribute('data-spotlight'), 'soft');
  for (const step of [{ actionId: 'sidebar.store_facts', dim: 'dark' }, { actionId: 'sidebar.store_facts', dim: '' },
    { actionId: 'a b', dim: 'strong' }])
    assert.throws(() => guide.spotlight(step), TypeError, JSON.stringify(step));
  // A target that left the screen loses the light (the card stays on its own).
  link.remove();
  guide.update();
  assert.equal(guide.outline.hidden, true);
  // show() is the prompt again, with its own Escape; hide() clears the spotlight.
  doc.body.append(link);
  guide.show({ actionId: 'sidebar.store_facts', text: '店舗情報を開きます。' });
  flush();
  assert.equal(guide.root.getAttribute('data-spotlight'), null);
  assert.equal(guide.panel.hidden, false);
  keys.forEach((listener) => listener({ key: 'Escape' }));
  assert.equal(dismissed, 1, 'the prompt keeps its own Escape');
  guide.spotlight({ actionId: 'sidebar.store_facts', dim: 'strong' });
  guide.hide();
  assert.equal(guide.root.getAttribute('data-spotlight'), null);
  assert.equal(guide.root.hidden, true);
});

test('the strong spotlight only darkens the page more and never takes a click', () => {
  const css = readFileSync(new URL('../overlay/app/public/brand-assets/toybaco-pointer-guide.css', import.meta.url), 'utf8');
  const outline = css.match(/\n\.toybaco-guide__outline \{([^}]*)\}/)?.[1];
  assert(outline?.includes('box-shadow: 0 0 0 9999px var(--toybaco-dim);') && outline.includes('pointer-events: none;'));
  const strong = css.match(/\n\.toybaco-guide\[data-spotlight='strong'\] \.toybaco-guide__outline \{([^}]*)\}/)?.[1];
  assert.equal(strong?.trim(), 'box-shadow: 0 0 0 9999px var(--toybaco-spotlight-dim);');
});

// Reproducible images retain the same Last-Modified timestamp across releases.
// A new byte sequence must request a new URL instead of revalidating the old one.
for (const extension of ['mjs', 'css']) {
  test(`guide ${extension} URL changes with the shipped asset bytes`, () => {
    const asset = new URL(`../overlay/app/public/brand-assets/toybaco-pointer-guide.${extension}`, import.meta.url);
    const hash = createHash('sha256').update(readFileSync(asset)).digest('hex');
    const loader = readFileSync(new URL('../overlay/app/app/javascript/dashboard/components/widgets/ToybacoGrowthGuide.vue', import.meta.url), 'utf8');
    assert(loader.includes(`/brand-assets/toybaco-pointer-guide.${extension}?v=${hash}`));
    assert(!loader.includes(`/brand-assets/toybaco-pointer-guide.${extension}'`));
  });
}
