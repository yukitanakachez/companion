import type { TabContext } from "../../../contracts/ts/protocol";
import type { ContextPart } from "../shared/messages";

const withoutFragment = (url: string) => url.split("#", 1)[0];

interface Waiter {
  tabId: number;
  resolve(c: TabContext | null): void;
}

/** The latest TabContext per tab, merged from per-script parts. */
export class TabStore {
  private readonly tabs = new Map<number, TabContext>();
  private waiters: Waiter[] = [];

  /** A new URL (ignoring #fragment) starts fresh. */
  applyPart(tabId: number, url: string, title: string, capturedAtMs: number, part: ContextPart): TabContext {
    const old = this.tabs.get(tabId);
    const keep = old && !old.blocked && withoutFragment(old.url) === withoutFragment(url) ? old : undefined;
    const next: TabContext = { ...keep, tabId, url, title, capturedAtMs, blocked: false };
    for (const key of ["page", "youtube", "classroom", "drive"] as const) {
      const value = part[key];
      if (value === null) delete next[key];
      else if (value !== undefined) (next as unknown as Record<string, unknown>)[key] = value;
    }
    this.tabs.set(tabId, next);
    const [ready, waiting] = partition(this.waiters, (w) => w.tabId === tabId);
    this.waiters = waiting;
    for (const w of ready) w.resolve(next);
    return next;
  }

  setBlocked(tabId: number, url: string, capturedAtMs: number): TabContext {
    const blocked: TabContext = { tabId, url, title: "", capturedAtMs, blocked: true };
    this.tabs.set(tabId, blocked);
    return blocked;
  }

  /** Only if youtube.videoId matches. */
  updatePlayhead(tabId: number, videoId: string, playheadSeconds: number, chapter: string | null): void {
    const c = this.tabs.get(tabId);
    if (c?.youtube?.videoId !== videoId) return;
    this.tabs.set(tabId, { ...c, youtube: { ...c.youtube, playheadSeconds, chapter } });
  }

  get(tabId: number): TabContext | undefined {
    return this.tabs.get(tabId);
  }
  delete(tabId: number): void {
    this.tabs.delete(tabId);
  }
  all(): TabContext[] {
    return [...this.tabs.values()];
  }

  dropIfUrlChanged(tabId: number, url: string): void {
    const c = this.tabs.get(tabId);
    if (c && withoutFragment(c.url) !== withoutFragment(url)) this.tabs.delete(tabId);
  }

  /** Replaces matching contexts with blocked ones and returns them. */
  purge(isBlocked: (url: string) => boolean, nowMs: number): TabContext[] {
    return this.all()
      .filter((c) => !c.blocked && isBlocked(c.url))
      .map((c) => this.setBlocked(c.tabId, c.url, nowMs));
  }

  /** Resolves on that tab's next applyPart, or null on timeout. */
  waitFor(tabId: number, timeoutMs: number): Promise<TabContext | null> {
    return new Promise((resolve) => {
      const waiter: Waiter = {
        tabId,
        resolve: (c) => {
          clearTimeout(timer);
          resolve(c);
        },
      };
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((w) => w !== waiter);
        resolve(null);
      }, timeoutMs);
      this.waiters.push(waiter);
    });
  }
}

function partition<T>(items: T[], pred: (t: T) => boolean): [T[], T[]] {
  return [items.filter(pred), items.filter((t) => !pred(t))];
}
