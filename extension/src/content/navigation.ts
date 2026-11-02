const HREF_POLL_MS = 1000;

export function debounce<A extends unknown[]>(fn: (...a: A) => void, ms: number): (...a: A) => void {
  let timer: ReturnType<typeof setTimeout> | undefined;
  return (...a) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...a), ms);
  };
}

/** Calls onChange when the URL or title changes: <title> MutationObserver + popstate + href poll. */
export function watchNavigation(win: Window, onChange: () => void): () => void {
  const doc = win.document;
  let href = win.location.href;
  let title = doc.title;
  const check = () => {
    if (win.location.href === href && doc.title === title) return;
    href = win.location.href;
    title = doc.title;
    onChange();
  };
  const Observer = (win as unknown as { MutationObserver: typeof MutationObserver }).MutationObserver;
  const observer = new Observer(check);
  if (doc.head) observer.observe(doc.head, { subtree: true, childList: true, characterData: true });
  win.addEventListener("popstate", check);
  const poll = setInterval(check, HREF_POLL_MS);
  return () => {
    observer.disconnect();
    win.removeEventListener("popstate", check);
    clearInterval(poll);
  };
}
