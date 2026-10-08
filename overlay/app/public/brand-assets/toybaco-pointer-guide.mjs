const SAFE_ID = /^[a-z][a-z0-9_.:-]{1,79}$/;
const GAP = 16;
const CONTROLS =
  'button, input, textarea, select, [contenteditable="true"], [role="button"], a[href], summary';
// A page can keep a place for the prompt right under its heading (the first-run
// guide screen). The prompt then sits in that place instead of floating near the
// target, and the place keeps the prompt's height, so the heading and the choices
// stay uncovered at every width.
const SLOT = '[data-toybaco-guide-slot]';
// A paused prompt never covers the logo or the header: the page header and the
// dashboard sidebar heading, which holds the logo.
const LANDMARKS = 'header, [data-toybaco-sidebar-header]';
const WAITING = '対象の画面に戻ると案内を再開します。';
// The first-run tour card (ToybacoTour) carries the words and the buttons; the guide
// only lights the target then. soft uses --toybaco-dim, strong --toybaco-spotlight-dim.
const SPOTLIGHT_DIMS = ['soft', 'strong'];

export function guidePosition(target, panel, viewport, occupied = []) {
  const left = viewport.left || 0;
  const top = viewport.top || 0;
  const right = left + viewport.width;
  const bottom = top + viewport.height;
  if (panel.width + GAP * 2 > viewport.width || panel.height + GAP * 2 > viewport.height)
    return null;
  const clampX = (x) => Math.min(Math.max(x, left + GAP), right - panel.width - GAP);
  // Wide editors have toolbars near their edges. Try the empty space above or
  // below the middle/right as well, without covering or scrolling a control.
  const horizontal = [...new Set([
    target.left,
    target.left + (target.width - panel.width) / 2,
    target.right - panel.width,
  ].map(clampX))];
  const below = target.bottom + GAP;
  const above = target.top - panel.height - GAP;
  const candidates = [];
  if (below + panel.height <= bottom - GAP)
    horizontal.forEach(x => candidates.push({ left: x, top: below }));
  if (above >= top + GAP)
    horizontal.forEach(x => candidates.push({ left: x, top: above }));
  if (target.right + panel.width + GAP * 2 <= right) {
    candidates.push({
      left: target.right + GAP,
      top: Math.max(
        top + GAP,
        Math.min(target.top, bottom - panel.height - GAP)
      ),
    });
  }
  if (target.left - panel.width - GAP >= left + GAP) {
    candidates.push({
      left: target.left - panel.width - GAP,
      top: Math.max(
        top + GAP,
        Math.min(target.top, bottom - panel.height - GAP)
      ),
    });
  }
  return (
    candidates.find(
      (position) => !occupied.some((box) => overlaps(position, panel, box))
    ) || null
  );
}

// The prompt takes the reserved place from its top-left corner at the place's
// full width. The place keeps the prompt's height and one gap, so the content
// after the place starts below the prompt instead of under it.
export function slotPlacement(slot, panel) {
  return {
    left: slot.left,
    top: slot.top,
    width: slot.width,
    reserve: Math.ceil(panel.height) + GAP,
  };
}

const usable = (box) =>
  [box.left, box.top, box.right, box.bottom].every(Number.isFinite) &&
  box.right > box.left &&
  box.bottom > box.top;

// A paused prompt stays visible and never covers the logo or the header. It
// takes the first free place, moving down past the logo, the header and the
// controls in its column: the right column first, then the middle one. When
// controls fill both, it stays at the right just under the logo and the header,
// over the controls. It is hidden only when the viewport cannot hold it.
export function waitingPosition(panel, viewport, landmarks = [], controls = []) {
  const left = viewport.left || 0;
  const top = viewport.top || 0;
  const bottom = top + viewport.height;
  if (
    !(panel.width > 0 && panel.height > 0) ||
    panel.width + GAP * 2 > viewport.width ||
    panel.height + GAP * 2 > viewport.height
  )
    return null;
  const marks = landmarks.filter(usable);
  const parts = controls.filter(usable);
  const columns = [
    left + viewport.width - panel.width - GAP,
    left + (viewport.width - panel.width) / 2,
  ];
  const slide = (x, boxes) => {
    const position = { left: x, top: top + GAP };
    const column = boxes.filter((box) => box.left - 4 < x + panel.width && box.right + 4 > x);
    // Every round moves below at least one more box, so the rounds are bounded.
    for (let round = 0; round <= column.length; round += 1) {
      const covered = column.filter((box) => overlaps(position, panel, box));
      if (!covered.length) return position;
      position.top = Math.max(...covered.map((box) => box.bottom)) + GAP;
      if (position.top + panel.height > bottom - GAP) return null;
    }
    return null;
  };
  for (const x of columns) {
    const position = slide(x, [...marks, ...parts]);
    if (position) return position;
  }
  return slide(columns[0], marks);
}

function overlaps(position, panel, box) {
  return (
    position.left < box.right + 4 &&
    position.left + panel.width > box.left - 4 &&
    position.top < box.bottom + 4 &&
    position.top + panel.height > box.top - 4
  );
}

// An AI or tour can request only a registered action. It cannot invent a CSS
// selector, absolute coordinate, click, input or scroll operation.
export class GuideRegistry {
  constructor() {
    this.targets = new Map();
  }

  register(id, element, available = () => true) {
    if (!SAFE_ID.test(id) || !element || typeof available !== 'function')
      throw new TypeError('invalid guide target');
    const entry = { element, available };
    const entries = this.targets.get(id) || new Set();
    entries.add(entry);
    this.targets.set(id, entries);
    return () => {
      entries.delete(entry);
      if (!entries.size) this.targets.delete(id);
    };
  }

  find(id, doc) {
    const entries = [...(this.targets.get(id) || [])].filter(
      ({ element, available }) => {
        if (
          !element.isConnected ||
          element.ownerDocument !== doc ||
          !available()
        )
          return false;
        if (
          element.disabled ||
          element.getAttribute('aria-disabled') === 'true'
        )
          return false;
        const box = element.getBoundingClientRect();
        const style = doc.defaultView.getComputedStyle(element);
        return (
          box.width > 0 &&
          box.height > 0 &&
          style.visibility !== 'hidden' &&
          style.display !== 'none' &&
          style.opacity !== '0'
        );
      }
    );
    return entries.length === 1 ? entries[0].element : null;
  }
}

export class PointerGuide {
  constructor({ registry, document: doc = document, onDismiss = () => {} }) {
    this.doc = doc;
    this.win = doc.defaultView;
    this.registry = registry;
    this.onDismiss = onDismiss;
    this.listeners = [];
    this.position = null;
    this.frame = null;
    this.slotElement = null;
    this.slotParent = null;
    this.create();
    // A font swap or a wrapped text changes the prompt's height and the page
    // around the place after the first measure; measure again when sizes change.
    this.resizer = this.win.ResizeObserver
      ? new this.win.ResizeObserver(() => this.schedule())
      : null;
    this.resizer?.observe(this.panel);
    this.listen(this.win, 'resize', () => this.schedule());
    this.listen(this.doc, 'scroll', () => this.schedule(), true);
    this.listen(this.doc, 'pointermove', (event) => this.interact(event), true);
    this.listen(this.doc, 'focusin', () => this.suppress(), true);
    this.listen(this.doc, 'input', () => this.suppress(), true);
    this.listen(
      this.doc,
      'keydown',
      (event) => {
        // The tour card handles Escape itself while the guide only lights a target.
        if (event.key === 'Escape' && this.step && !this.step.spotlight)
          this.dismiss();
      },
      true
    );
    if (this.win.visualViewport) {
      this.listen(this.win.visualViewport, 'resize', () => this.schedule());
      this.listen(this.win.visualViewport, 'scroll', () => this.schedule());
    }
    this.observer = new this.win.MutationObserver((records) => {
      if (
        this.step &&
        records.some((record) => !this.root.contains(record.target))
      )
        this.schedule();
    });
    this.observer.observe(doc.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: [
        'disabled',
        'aria-disabled',
        'class',
        'style',
        'hidden',
      ],
    });
  }

  create() {
    const element = (tag, className) => {
      const node = this.doc.createElement(tag);
      node.className = className;
      return node;
    };
    this.root = element('div', 'toybaco-guide');
    this.root.hidden = true;
    this.outline = element('div', 'toybaco-guide__outline');
    this.outline.setAttribute('aria-hidden', 'true');
    this.pointer = element('div', 'toybaco-guide__pointer');
    this.pointer.setAttribute('aria-hidden', 'true');
    this.pointer.innerHTML =
      '<svg viewBox="0 0 24 30" width="24" height="30"><path d="M3 2 21 17 13 18 9 26Z" fill="#1F3A5F" stroke="#FCFBF8" stroke-width="2" stroke-linejoin="round"/></svg>';
    this.panel = element('div', 'toybaco-guide__panel');
    this.text = element('p', 'toybaco-guide__text');
    this.text.id = `toybaco-guide-${Math.random().toString(36).slice(2)}`;
    this.text.setAttribute('role', 'status');
    this.text.setAttribute('aria-live', 'polite');
    this.dismissButton = element('button', 'toybaco-guide__dismiss');
    this.dismissButton.type = 'button';
    this.dismissButton.textContent = 'あとで続ける';
    this.dismissButton.addEventListener('click', () => this.dismiss());
    this.panel.append(this.text, this.dismissButton);
    this.root.append(this.outline, this.pointer, this.panel);
    this.doc.body.append(this.root);
  }

  listen(target, type, listener, options) {
    target.addEventListener(type, listener, options);
    this.listeners.push(() =>
      target.removeEventListener(type, listener, options)
    );
  }

  show({ actionId, text }) {
    if (
      !SAFE_ID.test(actionId) ||
      typeof text !== 'string' ||
      !text.trim() ||
      [...text].length > 40
    )
      throw new TypeError('invalid guide step');
    this.detachDescription();
    this.step = { actionId, text };
    this.suppressed = false;
    this.root.removeAttribute('data-spotlight');
    this.text.textContent = text;
    this.root.hidden = false;
    this.schedule();
  }

  // Light the target only: the outline and the dim, without a prompt or a pointer.
  spotlight({ actionId, dim = 'soft' }) {
    if (!SAFE_ID.test(actionId) || !SPOTLIGHT_DIMS.includes(dim))
      throw new TypeError('invalid guide step');
    this.detachDescription();
    this.step = { actionId, spotlight: true };
    this.suppressed = true;
    this.root.setAttribute('data-spotlight', dim);
    this.root.hidden = false;
    this.schedule();
  }

  schedule() {
    if (this.frame !== null || !this.step) return;
    this.frame = this.win.requestAnimationFrame(() => {
      this.frame = null;
      this.update();
    });
  }

  viewport() {
    const view = this.win.visualViewport;
    return view
      ? {
          left: view.offsetLeft,
          top: view.offsetTop,
          width: view.width,
          height: view.height,
        }
      : {
          left: 0,
          top: 0,
          width: this.win.innerWidth,
          height: this.win.innerHeight,
        };
  }

  update() {
    if (!this.step) return;
    if (this.step.spotlight) {
      this.release();
      this.panel.hidden = true;
      const target = this.registry.find(this.step.actionId, this.doc);
      const box = target?.getBoundingClientRect();
      if (target && this.pointable(target, box, this.viewport())) this.point(box);
      else this.unpoint();
      return;
    }
    // The page may have removed the place (another step); find the current one.
    if (this.slotElement && !this.slotElement.isConnected) this.release();
    const target = this.registry.find(this.step.actionId, this.doc);
    const view = this.viewport();
    const slot = this.slot();
    if (slot) {
      this.settle(slot, target, view);
      return;
    }
    this.release();
    this.panel.style.width = '';
    this.panel.style.maxWidth = `${Math.max(160, Math.min(300, view.width - GAP * 2))}px`;
    const box = target?.getBoundingClientRect();
    if (!target || !this.pointable(target, box, view)) {
      this.wait(view);
      return;
    }
    this.say(this.step.text);
    const panelBox = this.panel.getBoundingClientRect();
    const panelPosition = guidePosition(box, panelBox, view, this.occupied());
    if (!panelPosition) {
      this.wait(view);
      return;
    }
    this.attachDescription(target);
    this.panel.style.left = `${panelPosition.left}px`;
    this.panel.style.top = `${panelPosition.top}px`;
    this.point(box);
  }

  // On the first-run guide screen the prompt keeps the step text in the place
  // under the heading while the step lasts; the paused text is never shown there.
  // The outline and the pointer appear only while the target itself is in view.
  settle(slot, target, view) {
    this.panel.style.maxWidth = 'none';
    this.panel.style.width = `${slot.getBoundingClientRect().width}px`;
    this.say(this.step.text);
    const panelBox = this.panel.getBoundingClientRect();
    this.reserve(slot, slotPlacement(slot.getBoundingClientRect(), panelBox).reserve);
    // Keeping the place can move the page (scroll anchoring), so read it again.
    const slotBox = slot.getBoundingClientRect();
    const place = slotPlacement(slotBox, panelBox);
    this.panel.style.left = `${place.left}px`;
    this.panel.style.top = `${place.top}px`;
    this.panel.hidden = !this.visible(slot, slotBox);
    if (!target) {
      this.detachDescription();
      this.unpoint();
      return;
    }
    this.attachDescription(target);
    const box = target.getBoundingClientRect();
    if (this.pointable(target, box, view)) this.point(box);
    else this.unpoint();
  }

  slot() {
    const slots = [...this.doc.querySelectorAll(SLOT)].filter(
      (element) => element.getBoundingClientRect().width > 0
    );
    return slots.length === 1 ? slots[0] : null;
  }

  // The page keeps the usual place already (min-height), so the prompt appears
  // without moving the page. The prompt only adds the height a wrapped text needs,
  // never shrinks the page's own place, and never shrinks what it added while the
  // place is in use; release gives back only that addition.
  reserve(slot, height) {
    if (this.slotElement !== slot) {
      this.release();
      this.slotElement = slot;
      this.slotParent = slot.parentElement;
      if (this.slotParent) this.resizer?.observe(this.slotParent);
    }
    const kept = parseFloat(this.win.getComputedStyle(slot).minHeight) || 0;
    const need = Math.max(height, parseFloat(slot.style.height) || 0);
    const value = need > kept ? `${need}px` : '';
    if (slot.style.height !== value) slot.style.height = value;
  }

  release() {
    if (this.slotParent) this.resizer?.unobserve(this.slotParent);
    this.slotParent = null;
    if (!this.slotElement) return;
    this.slotElement.style.height = '';
    this.slotElement = null;
  }

  say(text) {
    this.panel.hidden = false;
    if (this.text.textContent !== text) this.text.textContent = text;
  }

  pointable(target, box, view) {
    const inView =
      box.top >= view.top &&
      box.bottom <= view.top + view.height &&
      box.left >= view.left &&
      box.right <= view.left + view.width;
    return inView && this.visible(target, box);
  }

  visible(element, box) {
    const center = this.doc
      .elementsFromPoint(box.left + box.width / 2, box.top + box.height / 2)
      .find((node) => !this.root.contains(node));
    return Boolean(center) && (center === element || element.contains(center));
  }

  point(box) {
    this.outline.hidden = false;
    Object.assign(this.outline.style, {
      left: `${box.left - 5}px`,
      top: `${box.top - 5}px`,
      width: `${box.width + 10}px`,
      height: `${box.height + 10}px`,
    });
    this.movePointer(box);
  }

  unpoint() {
    this.outline.hidden = true;
    this.pointer.hidden = true;
  }

  wait(view) {
    this.detachDescription();
    this.unpoint();
    this.say(WAITING);
    const position = waitingPosition(
      this.panel.getBoundingClientRect(),
      view,
      this.boxes(LANDMARKS),
      this.boxes(CONTROLS, true)
    );
    this.panel.hidden = !position;
    if (!position) return;
    this.panel.style.left = `${position.left}px`;
    this.panel.style.top = `${position.top}px`;
  }

  occupied() {
    return this.boxes(CONTROLS);
  }

  // shownOnly skips controls that are drawn invisible until hover (opacity 0 or
  // visibility hidden), so they do not push a paused prompt away.
  boxes(selector, shownOnly = false) {
    return [...this.doc.querySelectorAll(selector)]
      .filter((element) => !this.root.contains(element))
      .filter(
        (element) =>
          !shownOnly ||
          (element.checkVisibility?.({
            opacityProperty: true,
            visibilityProperty: true,
            checkOpacity: true,
            checkVisibilityCSS: true,
          }) ??
            true)
      )
      .map((element) => element.getBoundingClientRect())
      .filter((box) => usable(box) && box.width > 0 && box.height > 0);
  }

  movePointer(box) {
    const touch = this.win.matchMedia('(pointer: coarse)').matches;
    const editing = this.target && this.target.contains(this.doc.activeElement);
    this.pointer.hidden = touch || this.suppressed || editing;
    if (this.pointer.hidden) return;
    const next = {
      x: box.left + Math.max(8, box.width / 2),
      y: box.top + Math.max(8, box.height / 2),
    };
    const previous = this.position || {
      x: Math.max(GAP, next.x - 110),
      y: Math.max(GAP, next.y + 90),
    };
    const duration = this.win.matchMedia('(prefers-reduced-motion: reduce)')
      .matches
      ? 0
      : Math.min(
          700,
          Math.max(450, Math.hypot(next.x - previous.x, next.y - previous.y))
        );
    if (!this.position) {
      this.pointer.style.transition = 'none';
      this.pointer.style.transform = `translate(${previous.x}px, ${previous.y}px)`;
      this.pointer.getBoundingClientRect();
    }
    this.pointer.style.transition = `transform ${duration}ms cubic-bezier(.22,.61,.36,1), opacity 180ms`;
    this.pointer.style.transform = `translate(${next.x}px, ${next.y}px)`;
    this.position = next;
  }

  interact(event) {
    if (!this.target || !this.step) return;
    const box = this.target.getBoundingClientRect();
    const near =
      event.clientX >= box.left - 72 &&
      event.clientX <= box.right + 72 &&
      event.clientY >= box.top - 72 &&
      event.clientY <= box.bottom + 72;
    if (near) this.suppress();
  }

  suppress() {
    if (!this.step) return;
    this.suppressed = true;
    this.pointer.hidden = true;
  }

  attachDescription(target) {
    if (this.target === target) return;
    this.detachDescription();
    this.target = target;
    const ids = (target.getAttribute('aria-describedby') || '')
      .split(/\s+/)
      .filter(Boolean);
    target.setAttribute('aria-describedby', [...ids, this.text.id].join(' '));
  }

  detachDescription() {
    if (!this.target) return;
    const ids = (this.target.getAttribute('aria-describedby') || '')
      .split(/\s+/)
      .filter((id) => id && id !== this.text.id);
    if (ids.length) this.target.setAttribute('aria-describedby', ids.join(' '));
    else this.target.removeAttribute('aria-describedby');
    this.target = null;
  }

  hide() {
    this.step = null;
    this.detachDescription();
    this.release();
    this.root.removeAttribute('data-spotlight');
    this.root.hidden = true;
  }

  dismiss() {
    this.hide();
    this.onDismiss();
  }

  destroy() {
    this.hide();
    this.release();
    if (this.frame !== null) this.win.cancelAnimationFrame(this.frame);
    this.listeners.forEach((remove) => remove());
    this.observer.disconnect();
    this.resizer?.disconnect();
    this.root.remove();
  }
}
