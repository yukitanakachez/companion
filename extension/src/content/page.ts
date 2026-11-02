import type { ContentDeps } from "./content-deps";
import { debounce, watchNavigation } from "./navigation";
import { extractPage } from "./page-extract";

const SCROLL_DEBOUNCE_MS = 1000;

export function startPageScript(deps: ContentDeps): () => void {
  const { doc, win } = deps;
  let stopped = false;
  const push = async () => {
    if (await deps.askBlocked(doc.location.href)) return;
    if (stopped) return;
    const page = extractPage(doc);
    deps.send({ kind: "contextPart", pageUrl: page.url, pageTitle: page.title, capturedAtMs: deps.now(), part: { page } });
  };
  const fire = () => void push();
  const onScroll = debounce(fire, SCROLL_DEBOUNCE_MS);
  fire();
  win.addEventListener("scroll", onScroll, { capture: true, passive: true });
  const stopNav = watchNavigation(win, fire);
  deps.onExtractNow(fire);
  return () => {
    stopped = true;
    win.removeEventListener("scroll", onScroll, { capture: true });
    stopNav();
  };
}
