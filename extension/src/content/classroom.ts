import type { ClassroomContext, DriveFileRef } from "../../../contracts/ts/protocol";
import type { ContentDeps } from "./content-deps";
import { debounce, watchNavigation } from "./navigation";

const REPARSE_DEBOUNCE_MS = 500;
const TYPE_LABELS = new Set(["PDF", "Google Docs", "Google Slides", "Google Sheets", "Image", "Video", "Word", "PowerPoint"]);
const SHOW_TEXT = 4;

export function driveFileIdFromUrl(url: string): string | null {
  return /\/file\/d\/([A-Za-z0-9_-]{10,})/.exec(url)?.[1] ?? null;
}

function textLines(el: Element): string[] {
  const walker = el.ownerDocument.createTreeWalker(el, SHOW_TEXT);
  const lines: string[] = [];
  while (walker.nextNode()) {
    const line = (walker.currentNode.nodeValue ?? "").trim();
    if (line) lines.push(line);
  }
  return lines;
}

/** "Attachment: PDF: Book.pdf" → "Book.pdf". Only a known label goes, so "Chapter 3: Limits.pdf" stays intact. */
function titleFromLabel(label: string): string {
  const title = label.replace(/^Attachment:\s*/, "");
  const colon = title.indexOf(": ");
  return colon > 0 && TYPE_LABELS.has(title.slice(0, colon)) ? title.slice(colon + 2) : title;
}

function attachmentFrom(a: HTMLAnchorElement, fileId: string): DriveFileRef {
  const attr = a.getAttribute("aria-label")?.trim() || a.getAttribute("title")?.trim() || "";
  const lines = textLines(a);
  const named = titleFromLabel(attr) || lines.find((l) => !TYPE_LABELS.has(l)) || "";
  const title = named.replace(/\s+/g, " ");
  const isPdf = /\.pdf$/i.test(title) || lines.includes("PDF");
  return { fileId, title, mimeType: isPdf ? "application/pdf" : null };
}

/** Deduplicated by fileId, in document order. */
export function parseAttachments(root: ParentNode): DriveFileRef[] {
  const byId = new Map<string, DriveFileRef>();
  for (const a of root.querySelectorAll<HTMLAnchorElement>('a[href*="/file/d/"]')) {
    const fileId = driveFileIdFromUrl(a.getAttribute("href") ?? "");
    if (!fileId) continue;
    const found = attachmentFrom(a, fileId);
    const known = byId.get(fileId);
    // A card often has a bare thumbnail anchor too, in either order; the named one wins.
    if (!known || !known.title) byId.set(fileId, found);
  }
  return [...byId.values()].map((f) => ({ ...f, title: f.title || f.fileId }));
}

export function parseAssignmentTitle(doc: Document): string | null {
  const h1 = doc.querySelector('[role="main"] h1') ?? doc.querySelector("h1");
  return h1?.textContent?.trim() || null;
}

/** MutationObserver + 500 ms debounce; sends only when the result changes. */
export function startClassroomScript(deps: ContentDeps): () => void {
  const { doc, win } = deps;
  let last: string | null = null;
  let stopped = false;
  const parseAndSend = async (force: boolean) => {
    const url = doc.location.href;
    if (await deps.askBlocked(url)) return;
    if (stopped) return;
    const classroom: ClassroomContext = { assignmentTitle: parseAssignmentTitle(doc), attachments: parseAttachments(doc) };
    const key = JSON.stringify([url, classroom]);
    if (!force && key === last) return;
    last = key;
    deps.send({ kind: "contextPart", pageUrl: url, pageTitle: doc.title, capturedAtMs: deps.now(), part: { classroom } });
  };
  const schedule = debounce(() => void parseAndSend(false), REPARSE_DEBOUNCE_MS);
  void parseAndSend(false);

  const Observer = (win as unknown as { MutationObserver: typeof MutationObserver }).MutationObserver;
  const observer = new Observer(schedule);
  observer.observe(doc.documentElement, { childList: true, subtree: true });
  // Waits out the debounce so the old assignment's cards are gone before the new page is read.
  const stopNav = watchNavigation(win, schedule);
  deps.onExtractNow(() => void parseAndSend(true));
  return () => {
    stopped = true;
    observer.disconnect();
    stopNav();
  };
}
