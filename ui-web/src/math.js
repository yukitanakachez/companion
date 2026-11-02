// Finds math in Markdown before markdown-it sees it, so underscores and backslashes in
// TeX survive, and puts it back afterwards. Tokens use private-use characters, which
// markdown-it passes through untouched.
const OPEN = '';
const CLOSE = '';
const TOKEN = /(\d+)/g;

const isSpace = (c) => c === ' ' || c === '\t' || c === '\n' || c === '\r';
const isDigit = (c) => c >= '0' && c <= '9';

// Index of the closing delimiter, skipping backslash escapes inside the TeX; -1 if none.
function findClosing(s, from, closer) {
  for (let i = from; i < s.length; i++) {
    if (s.startsWith(closer, i)) return i;
    if (s[i] === '\\') i++;
  }
  return -1;
}

// Closing `$` of an inline span opened just before `from`, or -1. The first `$` decides:
// if it can't close, the opening one was a price, not math.
function findInlineClosing(s, from) {
  if (from >= s.length || isSpace(s[from])) return -1;
  for (let i = from; i < s.length; i++) {
    const c = s[i];
    if (c === '\\') { i++; continue; }
    if (c === '\n' && /^[ \t]*(\r?\n|$)/.test(s.slice(i + 1))) return -1;
    if (c === '$') {
      if (isSpace(s[i - 1]) || isDigit(s[i + 1] ?? '')) return -1;
      return i;
    }
  }
  return -1;
}

// End of the fenced block opening at `lineStart`, or -1 if that line is not a fence.
function fenceEnd(s, lineStart) {
  const lineEnd = s.indexOf('\n', lineStart);
  const line = s.slice(lineStart, lineEnd === -1 ? s.length : lineEnd);
  const open = /^ {0,3}(`{3,}|~{3,})/.exec(line);
  if (!open) return -1;
  if (lineEnd === -1) return s.length;
  const marker = open[1];
  const closing = new RegExp(`^ {0,3}${marker[0]}{${marker.length},}[ \\t]*$`);
  let at = lineEnd + 1;
  while (at < s.length) {
    let next = s.indexOf('\n', at);
    if (next === -1) next = s.length;
    if (closing.test(s.slice(at, next))) return next;
    at = next + 1;
  }
  return s.length;   // unclosed fence: still code while it streams
}

export function protectMath(markdown) {
  const s = markdown;
  const spans = [];
  let text = '';
  let i = 0;
  const emit = (tex, display) => {
    text += `${OPEN}${spans.length}${CLOSE}`;
    spans.push({ tex, display });
  };

  while (i < s.length) {
    if (i === 0 || s[i - 1] === '\n') {
      const end = fenceEnd(s, i);
      if (end !== -1) { text += s.slice(i, end); i = end; continue; }
    }
    const c = s[i];
    if (c === '`') {
      let n = 1;
      while (s[i + n] === '`') n++;
      let at = i + n;
      let close = -1;
      while (at < s.length) {
        const found = s.indexOf('`', at);
        if (found === -1) break;
        let m = 1;
        while (s[found + m] === '`') m++;
        if (m === n) { close = found; break; }
        at = found + m;
      }
      const end = close === -1 ? i + n : close + n;
      text += s.slice(i, end);
      i = end;
      continue;
    }
    if (c === '\\') {
      const next = s[i + 1];
      if (next === '(' || next === '[') {
        const closer = next === '(' ? '\\)' : '\\]';
        const close = findClosing(s, i + 2, closer);
        if (close !== -1) {
          emit(s.slice(i + 2, close), next === '[');
          i = close + 2;
        } else {
          text += `\\\\${next}`;   // unclosed: keep the backslash visible
          i += 2;
        }
        continue;
      }
      text += s.slice(i, i + 2);
      i += 2;
      continue;
    }
    if (c === '$') {
      if (s[i + 1] === '$') {
        const close = findClosing(s, i + 2, '$$');
        if (close !== -1) {
          emit(s.slice(i + 2, close), true);
          i = close + 2;
        } else {
          text += '$$';
          i += 2;
        }
        continue;
      }
      const close = findInlineClosing(s, i + 1);
      if (close !== -1) {
        emit(s.slice(i + 1, close), false);
        i = close + 1;
        continue;
      }
    }
    text += c;
    i++;
  }
  return { text, spans };
}

export function restoreMath(html, spans, renderTex) {
  return html.replace(TOKEN, (whole, n) => {
    const span = spans[Number(n)];
    return span ? renderTex(span.tex, span.display) : whole;
  });
}
