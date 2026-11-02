import { renderAssistant, renderMarkdown } from './markdown.js';

const TYPING = '<div class="typing"><span></span><span></span><span></span></div>';
const STICK_TO_BOTTOM_PX = 24;

export function createCompanion(root, { post = () => {}, minIntervalMs = 33 } = {}) {
  const doc = root.ownerDocument;
  const scroller = () => doc.scrollingElement ?? doc.documentElement;
  let messages = [];
  let dirty = new Set();
  let timer = null;
  let renders = 0;

  const reportHeight = () => post({ type: 'height', value: Math.ceil(root.scrollHeight) });

  function fill(el, m) {
    if (m.role === 'user') {
      el.innerHTML = `<div class="q">${renderMarkdown(m.markdown)}</div>`;
    } else if (m.markdown === '' && m.isStreaming) {
      el.innerHTML = TYPING;
    } else {
      el.innerHTML = renderAssistant(m.markdown);
    }
  }

  function elementFor(id) {
    for (const el of root.children) if (el.dataset.id === id) return el;
    return null;
  }

  // Runs one DOM update, keeping a streaming answer pinned to the bottom if it already was.
  function update(change) {
    const s = scroller();
    const atBottom = s.scrollHeight - s.scrollTop - s.clientHeight <= STICK_TO_BOTTOM_PX;
    change();
    renders++;
    if (atBottom && messages.some((m) => m.isStreaming)) s.scrollTop = s.scrollHeight;
    reportHeight();
  }

  function flush() {
    timer = null;
    const ids = dirty;
    dirty = new Set();
    update(() => {
      for (const id of ids) {
        const m = messages.find((x) => x.id === id);
        const el = elementFor(id);
        if (m && el) fill(el, m);
      }
    });
  }

  if (typeof ResizeObserver !== 'undefined') new ResizeObserver(reportHeight).observe(root);

  return {
    render(thread) {
      if (timer !== null) { clearTimeout(timer); timer = null; }
      dirty = new Set();
      messages = (typeof thread === 'string' ? JSON.parse(thread) : thread).map((m) => ({ ...m }));
      update(() => {
        root.replaceChildren(...messages.map((m) => {
          const el = doc.createElement('div');
          el.className = `msg ${m.role}`;
          el.dataset.id = m.id;
          fill(el, m);
          return el;
        }));
      });
    },
    appendDelta(id, text) {
      const m = messages.find((x) => x.id === id);
      if (!m) return;
      m.markdown += text;
      dirty.add(id);
      if (timer === null) timer = setTimeout(flush, minIntervalMs);
    },
    debugMarkdown(id) {
      return messages.find((x) => x.id === id)?.markdown ?? null;
    },
    renderCount() {
      return renders;
    },
  };
}
