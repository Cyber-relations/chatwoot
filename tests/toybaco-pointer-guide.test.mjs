import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  GuideRegistry,
  guidePosition,
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
