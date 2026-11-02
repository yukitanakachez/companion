import type { BridgeErrorCode } from "../../../contracts/ts/protocol";
import type { BackgroundToContent } from "../shared/messages";
import { RequestError } from "../shared/protocol-codec";

/**
 * PROVISIONAL: written from memory of Drive's markup, not recorded from a live viewer (plan Task 14 Step 1).
 * If it's wrong, viewerPages finds nothing and requests answer noViewer. Drive's class names can also change.
 */
export const VIEWER_PAGE_SELECTOR = ".ndfHFb-c4YZDc-cYSp0e-DARUcf";
const RENDER_TIMEOUT_MS = 3000;
const RENDER_POLL_MS = 100;

export function viewerPages(doc: Document): HTMLElement[] {
  return [...doc.querySelectorAll<HTMLElement>(VIEWER_PAGE_SELECTOR)];
}

/** The page with the largest visible area. */
export function currentPageIndex(pages: HTMLElement[], viewportHeight: number): number {
  let best = 0;
  let bestVisible = -1;
  pages.forEach((page, i) => {
    const r = page.getBoundingClientRect();
    const visible = Math.max(0, Math.min(r.bottom, viewportHeight) - Math.max(r.top, 0));
    if (visible > bestVisible) {
      best = i;
      bestVisible = visible;
    }
  });
  return best;
}

function isRendered(page: HTMLElement): boolean {
  if (page.querySelector("canvas")) return true;
  const img = page.querySelector("img");
  return img !== null && img.complete && img.naturalWidth > 0;
}

export function scrollToPage(doc: Document, index: number, timeoutMs = RENDER_TIMEOUT_MS):
  Promise<{ rect: { x: number; y: number; width: number; height: number }; devicePixelRatio: number }> {
  const page = viewerPages(doc)[index];
  if (!page) return Promise.reject(new RequestError("notFound", `The viewer has no page ${index + 1}.`));
  page.scrollIntoView({ block: "center" });
  return new Promise((resolve, reject) => {
    const finish = (settle: () => void) => {
      clearInterval(poll);
      clearTimeout(timer);
      settle();
    };
    const check = () => {
      if (!isRendered(page)) return;
      const r = page.getBoundingClientRect();
      finish(() => resolve({ rect: { x: r.x, y: r.y, width: r.width, height: r.height }, devicePixelRatio: doc.defaultView?.devicePixelRatio ?? 1 }));
    };
    // An <img> finishing its load changes no DOM, so this polls rather than observing mutations.
    const poll = setInterval(check, RENDER_POLL_MS);
    const timer = setTimeout(() => finish(() => reject(new RequestError("timeout", `Viewer page ${index + 1} didn't render in time.`))), timeoutMs);
    check();
  });
}

export type ViewerReply =
  | { ok: true; pageCount: number; currentIndex: number }
  | { ok: true; rect: { x: number; y: number; width: number; height: number }; devicePixelRatio: number }
  | { ok: false; code: BridgeErrorCode; message: string };

export async function handleViewerMessage(msg: Extract<BackgroundToContent, { kind: "viewer" }>, doc: Document): Promise<ViewerReply> {
  try {
    if (msg.op === "info") {
      const pages = viewerPages(doc);
      return { ok: true, pageCount: pages.length, currentIndex: currentPageIndex(pages, doc.defaultView?.innerHeight ?? 0) };
    }
    return { ok: true, ...(await scrollToPage(doc, msg.index)) };
  } catch (e) {
    return e instanceof RequestError
      ? { ok: false, code: e.code, message: e.message }
      : { ok: false, code: "internal", message: String(e) };
  }
}
