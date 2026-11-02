import type { MathSnippet, WebPageContext } from "../../../contracts/ts/protocol";

export const VISIBLE_TEXT_CAP = 20_000;
export const MATH_CAP = 50;
const TEX_ANNOTATION = 'annotation[encoding="application/x-tex"]';
const SHOW_TEXT = 4;
const FILTER_ACCEPT = 1;
const FILTER_REJECT = 2;

const collapse = (s: string) => s.replace(/\s+/g, " ").trim();

export function visibleText(doc: Document): string {
  const body = doc.body as HTMLElement | null;
  if (!body) return "";
  const inner: unknown = body.innerText;
  if (typeof inner === "string") return collapse(inner).slice(0, VISIBLE_TEXT_CAP);
  const walker = doc.createTreeWalker(body, SHOW_TEXT, {
    acceptNode: (n) => (n.parentElement?.closest("script,style,noscript,template,[hidden]") ? FILTER_REJECT : FILTER_ACCEPT),
  });
  const parts: string[] = [];
  while (walker.nextNode()) parts.push(walker.currentNode.nodeValue ?? "");
  return collapse(parts.join(" ")).slice(0, VISIBLE_TEXT_CAP);
}

export function extractMath(doc: Document): MathSnippet[] {
  const out: MathSnippet[] = [];
  const seen = new Set<string>();
  const add = (format: MathSnippet["format"], raw: string | null) => {
    const source = (raw ?? "").trim();
    const key = `${format}:${source}`;
    if (!source || seen.has(key)) return;
    seen.add(key);
    out.push({ format, source });
  };
  for (const el of doc.querySelectorAll(`${TEX_ANNOTATION}, script[type^="math/tex"], math`)) {
    if (out.length >= MATH_CAP) break;
    const name = el.localName;
    if (name === "annotation" || name === "script") add("latex", el.textContent);
    else if (!el.querySelector(TEX_ANNOTATION) && !el.closest(".MJX_Assistive_MathML")) add("mathml", el.outerHTML);
  }
  return out;
}

export function extractPage(doc: Document): WebPageContext {
  return { url: doc.location.href, title: doc.title, visibleText: visibleText(doc), math: extractMath(doc) };
}
