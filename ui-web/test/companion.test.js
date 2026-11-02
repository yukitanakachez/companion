import { createCompanion } from '../src/companion.js';
let root, post, c;
beforeEach(() => { document.body.innerHTML = '<div id="thread"></div>'; root = document.getElementById('thread');
  post = vi.fn(); c = createCompanion(root, { post }); vi.useFakeTimers(); });
afterEach(() => vi.useRealTimers());
const msg = (id, role, markdown, isStreaming) => ({ id, role, markdown, isStreaming });
test('render builds one element per message and reports height', () => {
  c.render(JSON.stringify([msg('u', 'user', 'why?', false), msg('a', 'assistant', '', true)]));
  expect(root.querySelectorAll('.msg').length).toBe(2); expect(root.querySelector('.msg.user .q').textContent.trim()).toBe('why?');
  expect(root.querySelector('[data-id="a"] .typing')).not.toBeNull();
  expect(post).toHaveBeenCalledWith(expect.objectContaining({ type: 'height' }));
});
test('appendDelta is throttled to one render per 33 ms', () => {
  c.render([msg('a', 'assistant', '', true)]); const r0 = c.renderCount();
  for (let i = 0; i < 1000; i++) c.appendDelta('a', 'x ');
  expect(c.renderCount()).toBe(r0); vi.advanceTimersByTime(33); expect(c.renderCount()).toBe(r0 + 1);
  expect(root.textContent.match(/x/g).length).toBe(1000);
  for (let i = 0; i < 300; i++) { c.appendDelta('a', '$y$ '); vi.advanceTimersByTime(5); }
  vi.advanceTimersByTime(33);
  expect(c.renderCount() - r0 - 1).toBeLessThanOrEqual(Math.ceil(1500 / 33) + 2); expect(c.debugMarkdown('a').length).toBe(3200);
  c.appendDelta('zzz', 'x'); expect(c.debugMarkdown('zzz')).toBeNull();   // unknown ids are ignored
});
