const SAFE_ID = /^[a-z][a-z0-9_.:-]{1,79}$/;
const GAP = 16;

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
    this.create();
    this.listen(this.win, 'resize', () => this.schedule());
    this.listen(this.doc, 'scroll', () => this.schedule(), true);
    this.listen(this.doc, 'pointermove', (event) => this.interact(event), true);
    this.listen(this.doc, 'focusin', () => this.suppress(), true);
    this.listen(this.doc, 'input', () => this.suppress(), true);
    this.listen(
      this.doc,
      'keydown',
      (event) => {
        if (event.key === 'Escape' && this.step) this.dismiss();
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
    this.text.textContent = text;
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
    const target = this.registry.find(this.step.actionId, this.doc);
    const view = this.viewport();
    this.panel.style.maxWidth = `${Math.max(160, Math.min(300, view.width - GAP * 2))}px`;
    if (!target) {
      this.wait(view);
      return;
    }
    const box = target.getBoundingClientRect();
    const inView =
      box.top >= view.top &&
      box.bottom <= view.top + view.height &&
      box.left >= view.left &&
      box.right <= view.left + view.width;
    const center = this.doc
      .elementsFromPoint(box.left + box.width / 2, box.top + box.height / 2)
      .find((node) => !this.root.contains(node));
    if (!inView || !(center === target || target.contains(center))) {
      this.wait(view);
      return;
    }
    const panelBox = this.panel.getBoundingClientRect();
    const panelPosition = guidePosition(box, panelBox, view, this.occupied());
    if (!panelPosition) {
      this.wait(view);
      return;
    }
    this.attachDescription(target);
    if (this.text.textContent !== this.step.text)
      this.text.textContent = this.step.text;
    this.panel.style.left = `${panelPosition.left}px`;
    this.panel.style.top = `${panelPosition.top}px`;
    this.outline.hidden = false;
    Object.assign(this.outline.style, {
      left: `${box.left - 5}px`,
      top: `${box.top - 5}px`,
      width: `${box.width + 10}px`,
      height: `${box.height + 10}px`,
    });
    this.movePointer(box);
  }

  wait(view) {
    this.detachDescription();
    this.outline.hidden = true;
    this.pointer.hidden = true;
    const waiting = '対象の画面に戻ると案内を再開します。';
    if (this.text.textContent !== waiting) this.text.textContent = waiting;
    this.panel.style.left = `${view.left + GAP}px`;
    this.panel.style.top = `${view.top + GAP}px`;
  }

  occupied() {
    const selector =
      'button, input, textarea, select, [contenteditable="true"], [role="button"], a[href], summary';
    return [...this.doc.querySelectorAll(selector)]
      .filter((element) => !this.root.contains(element))
      .map((element) => element.getBoundingClientRect())
      .filter((box) => box.width > 0 && box.height > 0);
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
    this.root.hidden = true;
  }

  dismiss() {
    this.hide();
    this.onDismiss();
  }

  destroy() {
    this.hide();
    if (this.frame !== null) this.win.cancelAnimationFrame(this.frame);
    this.listeners.forEach((remove) => remove());
    this.observer.disconnect();
    this.root.remove();
  }
}
