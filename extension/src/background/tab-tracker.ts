import { PROTOCOL_VERSION, type ExtensionToApp } from "../../../contracts/ts/protocol";
import type { BlocklistStore } from "./blocklist-store";
import type { TabStore } from "./tab-store";

export interface TabTrackerDeps {
  chrome: Pick<typeof chrome, "tabs" | "windows">;
  store: TabStore;
  blocklist: BlocklistStore;
  send(msg: ExtensionToApp): void;
}

export class TabTracker {
  private active: number | null = null;
  private lastAnnounced: string | null = null;
  /** Bumped by every activation; an announce that lost the race to a newer one is dropped. */
  private latest = 0;

  constructor(private readonly deps: TabTrackerDeps) {}

  /** Synchronously registers every listener. */
  attach(): void {
    const { tabs, windows } = this.deps.chrome;
    tabs.onActivated.addListener(({ tabId }) => {
      this.active = tabId;
      void this.announceTabId(tabId);
    });
    windows.onFocusChanged.addListener((windowId) => {
      if (windowId !== windows.WINDOW_ID_NONE) void this.announceWindow(windowId);
    });
    tabs.onUpdated.addListener((tabId, change, tab) => {
      if (change.url) this.deps.store.dropIfUrlChanged(tabId, change.url);
      if (tabId === this.active && (change.url || change.title !== undefined)) void this.announce(tab, false);
    });
    tabs.onRemoved.addListener((tabId) => {
      this.deps.store.delete(tabId);
      if (this.active === tabId) this.active = null;
      this.deps.send({ v: PROTOCOL_VERSION, type: "tabClosed", tabId });
    });
  }

  activeTabId(): number | null {
    return this.active;
  }

  /** Sends tabActivated for the focused window's active tab, even if it repeats the last one. */
  async announceActive(): Promise<number | null> {
    try {
      const win = await this.deps.chrome.windows.getLastFocused();
      return win.id === undefined ? null : await this.announceWindow(win.id);
    } catch {
      return null;
    }
  }

  private async announceWindow(windowId: number): Promise<number | null> {
    const turn = ++this.latest;
    const [tab] = await this.deps.chrome.tabs.query({ active: true, windowId });
    if (tab?.id === undefined || turn !== this.latest) return tab?.id ?? null;
    this.active = tab.id;
    await this.announce(tab, true);
    return tab.id;
  }

  private async announceTabId(tabId: number): Promise<void> {
    const turn = ++this.latest;
    try {
      const tab = await this.deps.chrome.tabs.get(tabId);
      if (turn === this.latest) await this.announce(tab, false);
    } catch {
      // The tab closed before it could be read.
    }
  }

  private async announce(tab: chrome.tabs.Tab, force: boolean): Promise<void> {
    const { blocklist, send, store } = this.deps;
    if (tab.id === undefined) return;
    const tabId = tab.id;
    const url = tab.url ?? tab.pendingUrl ?? "";
    const turn = this.latest;
    const blocked = await blocklist.isUrlBlocked(url);
    if (turn !== this.latest) return;
    const title = blocked ? "" : tab.title ?? "";
    const key = JSON.stringify([tabId, tab.windowId, url, title]);
    if (!force && key === this.lastAnnounced) return;
    this.lastAnnounced = key;
    send({ v: PROTOCOL_VERSION, type: "tabActivated", tabId, windowId: tab.windowId, url, title });
    // No content script reports a tab it can't reach, so the app learns "blocked" from here too.
    if (blocked) send({ v: PROTOCOL_VERSION, type: "tabContext", context: store.setBlocked(tabId, url, Date.now()) });
  }
}
