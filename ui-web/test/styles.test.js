// @vitest-environment node
import { JSDOM } from 'jsdom'; import fs from 'node:fs';
test('wide blocks scroll inside the answer instead of widening the bubble', () => {
  const { window } = new JSDOM(fs.readFileSync(new URL('../static/index.html', import.meta.url), 'utf8'));
  const d = window.document; d.body.insertAdjacentHTML('beforeend', '<pre>x</pre><span class="katex-display">y</span>');
  for (const sel of ['pre', '.katex-display']) expect(window.getComputedStyle(d.querySelector(sel)).overflowX).toBe('auto');
});
test('long unbroken text wraps and wide tables scroll', () => {
  const { window } = new JSDOM(fs.readFileSync(new URL('../static/index.html', import.meta.url), 'utf8'));
  const d = window.document; d.body.insertAdjacentHTML('beforeend', '<div class="msg">x</div><div class="table-scroll">y</div>');
  expect(window.getComputedStyle(d.querySelector('.msg')).overflowWrap).toBe('anywhere');
  expect(window.getComputedStyle(d.querySelector('.table-scroll')).overflowX).toBe('auto');
});
