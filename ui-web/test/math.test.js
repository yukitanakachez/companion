import { renderMarkdown, renderAssistant } from '../src/markdown.js';
const dom = (md, f = renderMarkdown) => { const d = document.createElement('div'); d.innerHTML = f(md); return d; };
const katexCount = (md) => dom(md).querySelectorAll('.katex').length;
test('math renders with KaTeX', () => {
  expect(katexCount('$x^2$')).toBe(1); expect(dom('$$\\int x\\,dx$$').querySelector('.katex-display')).not.toBeNull();
  expect(katexCount('\\(a\\) and \\[b\\]')).toBe(2);
  const d = dom('$a_1 + b_1$ and $c_2$'); expect(d.querySelectorAll('.katex').length).toBe(2); expect(d.querySelector('em')).toBeNull();
});
test('dollar signs that are not math stay literal', () => {
  for (const s of ['It costs $5 and $6 today.', "That's $5.", 'costs $5\n\nthen $6', '\\$x\\$', '$$\\int x']) expect(katexCount(s)).toBe(0);
  expect(dom('It costs $5 and $6 today.').textContent).toContain('$5 and $6');
  expect(dom('\\$x\\$').textContent).toContain('$x$'); expect(dom('$$\\int x').textContent).toContain('$$\\int x');   // unclosed while streaming
  expect(dom('`echo $HOME $PATH`').querySelector('code').textContent).toBe('echo $HOME $PATH');
  expect(dom('```\n$x$\n```').querySelector('pre').textContent).toContain('$x$'); expect(katexCount('```\n$x$\n```')).toBe(0);
});
test('malformed LaTeX never throws and keeps the rest', () => {
  const d = dom('before $\\frac{1}{$ after'); expect(d.querySelector('.katex-error')).not.toBeNull(); expect(d.textContent).toContain('after');
});
test('raw HTML and images from the model are not rendered', () => {
  expect(dom('<script>alert(1)</script> ![x](http://example.com/a.png)').querySelector('script, img')).toBeNull();
});
test('Reading line', () => {
  const d = dom('Reading: $x^2-5x+6=0$\n\nAt 12:20 he factored it.', renderAssistant);
  expect(d.querySelector('.reading .katex')).not.toBeNull(); expect(d.querySelector('.reading').textContent).not.toContain('12:20');
});
test('dollars never pair across code', () => {
  const a = dom('Set $PATH with `export PATH=$PATH:/x` now'); expect(a.querySelector('code').textContent).toBe('export PATH=$PATH:/x'); expect(a.querySelector('.katex')).toBeNull();
  const b = dom('Price $5\n```sh\nA=$B\n```'); expect(b.querySelector('pre').textContent).toContain('A=$B'); expect(b.querySelector('.katex')).toBeNull();
  const c = dom('Costs $$ then\n\n```\n$$\n```'); expect(c.querySelector('pre').textContent).toContain('$$'); expect(c.querySelector('.katex')).toBeNull();
});
test('tables get a scrolling wrapper', () => {
  expect(dom('| a | b |\n|---|---|\n| 1 | 2 |').querySelector('.table-scroll > table')).not.toBeNull();
});
