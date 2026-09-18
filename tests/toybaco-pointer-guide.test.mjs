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
