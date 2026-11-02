import katex from 'katex';
import MarkdownIt from 'markdown-it';
import { protectMath, restoreMath } from './math.js';

const md = new MarkdownIt({ html: false, linkify: false });
md.disable('image');
md.renderer.rules.table_open = () => '<div class="table-scroll"><table>\n';
md.renderer.rules.table_close = () => '</table></div>\n';

// Re-rendering a streaming message must not re-typeset math that hasn't changed.
const memo = new Map();
function renderTex(tex, displayMode) {
  const key = `${displayMode ? 'D' : 'I'}${tex}`;
  const hit = memo.get(key);
  if (hit !== undefined) return hit;
  const html = katex.renderToString(tex, { displayMode, throwOnError: false });
  if (memo.size >= 500) memo.clear();
  memo.set(key, html);
  return html;
}

export function renderMarkdown(markdown) {
  const { text, spans } = protectMath(markdown);
  return restoreMath(md.render(text), spans, renderTex);
}

function renderInline(markdown) {
  const { text, spans } = protectMath(markdown);
  return restoreMath(md.renderInline(text), spans, renderTex);
}

export function renderAssistant(markdown) {
  if (!markdown.startsWith('Reading:')) return renderMarkdown(markdown);
  const end = markdown.indexOf('\n');
  const first = end === -1 ? markdown : markdown.slice(0, end);
  const rest = end === -1 ? '' : markdown.slice(end + 1);
  return `<div class="reading">${renderInline(first)}</div>${renderMarkdown(rest)}`;
}
