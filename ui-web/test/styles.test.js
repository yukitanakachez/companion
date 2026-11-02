// @vitest-environment node
import { JSDOM } from 'jsdom'; import fs from 'node:fs';
test('wide blocks scroll inside the answer instead of widening the bubble', () => {
  const { window } = new JSDOM(fs.readFileSync(new URL('../static/index.html', import.meta.url), 'utf8'));
  const d = window.document; d.body.insertAdjacentHTML('beforeend', '<pre>x</pre><span class="katex-display">y</span>');
  for (const sel of ['pre', '.katex-display']) expect(window.getComputedStyle(d.querySelector(sel)).overflowX).toBe('auto');
});
