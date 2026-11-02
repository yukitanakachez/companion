import { beforeEach, describe, expect, it, vi } from "vitest";
import { BlocklistStore } from "../src/background/blocklist-store";
import { TabStore } from "../src/background/tab-store";
import { TabTracker } from "../src/background/tab-tracker";
import { isExtensionToApp } from "../src/shared/protocol-codec";
import { asChrome, createChromeMock, type ChromeMock } from "./helpers/chrome-mock";

const YT = "https://www.youtube.com/watch?v=abc";
const flush = () => vi.waitFor(async () => { await new Promise((r) => setTimeout(r, 0)); });

describe("TabTracker", () => {
  let c: ChromeMock, store: TabStore, sent: any[], tracker: TabTracker;
  beforeEach(() => {
    c = createChromeMock({
      focusedWindowId: 3,
      tabs: [
        { id: 12, windowId: 3, active: true, url: YT, title: "Video" },
        { id: 13, windowId: 3, active: false, url: "https://secure.chase.com/a", title: "Bank secrets" },
        { id: 20, windowId: 4, active: true, url: "https://example.org/", title: "Other" },
      ],
    });
    store = new TabStore();
    sent = [];
    tracker = new TabTracker({
      chrome: asChrome(c),
      store,
      blocklist: new BlocklistStore(asChrome(c).storage.local),
      send: (m) => { expect(isExtensionToApp(m)).toBe(true); sent.push(m); },
    });
    tracker.attach();
  });
  const activated = () => sent.filter((m) => m.type === "tabActivated");

  it("tabs.onActivated sends tabActivated", async () => {
    c.tabs.onActivated.fire({ tabId: 12, windowId: 3 });
    expect(tracker.activeTabId()).toBe(12);
    await flush();
    expect(sent).toEqual([{ v: 1, type: "tabActivated", tabId: 12, windowId: 3, url: YT, title: "Video" }]);
  });
  it("window focus re-announces that window's active tab; WINDOW_ID_NONE is ignored", async () => {
    c.windows.onFocusChanged.fire(-1);
    await flush();
    expect(sent).toEqual([]);
    c.windows.onFocusChanged.fire(4);
    await flush();
    expect(activated().map((m) => m.tabId)).toEqual([20]);
    c.windows.onFocusChanged.fire(4);
    await flush();
    expect(activated().map((m) => m.tabId)).toEqual([20, 20]);
    expect(tracker.activeTabId()).toBe(20);
  });
  it("URL or title change of the active tab re-announces it and drops the stale snapshot", async () => {
    c.tabs.onActivated.fire({ tabId: 12, windowId: 3 });
    await flush();
    store.applyPart(12, YT, "Video", 1, {});
    const next = "https://www.youtube.com/watch?v=def";
    c._tabs[0].url = next;
    c.tabs.onUpdated.fire(12, { url: next }, c._tabs[0]);
    expect(store.get(12)).toBeUndefined();
    await flush();
    expect(activated().at(-1)).toMatchObject({ tabId: 12, url: next });
    c._tabs[0].title = "New";
    c.tabs.onUpdated.fire(12, { title: "New" }, c._tabs[0]);
    await flush();
    expect(activated().at(-1)).toMatchObject({ title: "New" });
    expect(activated()).toHaveLength(3);
  });
  it("changes to a background tab drop its snapshot without announcing", async () => {
    c.tabs.onActivated.fire({ tabId: 12, windowId: 3 });
    await flush();
    store.applyPart(20, "https://example.org/", "Other", 1, {});
    c.tabs.onUpdated.fire(20, { url: "https://example.org/x" }, c._tabs[2]);
    await flush();
    expect(store.get(20)).toBeUndefined();
    expect(activated()).toHaveLength(1);
  });
  it("identical consecutive activations are sent once", async () => {
    c.tabs.onActivated.fire({ tabId: 12, windowId: 3 });
    await flush();
    c.tabs.onActivated.fire({ tabId: 12, windowId: 3 });
    await flush();
    expect(activated()).toHaveLength(1);
  });
  it("blocked tab activation has an empty title", async () => {
    c.tabs.onActivated.fire({ tabId: 13, windowId: 3 });
    await flush();
    expect(activated()).toEqual([{ v: 1, type: "tabActivated", tabId: 13, windowId: 3, url: "https://secure.chase.com/a", title: "" }]);
  });
  it("blocked tab activation also caches and sends the blocked context, title free", async () => {
    c.tabs.onActivated.fire({ tabId: 13, windowId: 3 });
    await flush();
    const ctx = sent.find((m) => m.type === "tabContext").context;
    expect(ctx).toMatchObject({ tabId: 13, title: "", blocked: true });
    expect(JSON.stringify(sent)).not.toContain("Bank secrets");
    expect(store.get(13)?.blocked).toBe(true);
  });
  it("a slower earlier activation can't overwrite a newer one", async () => {
    let release: (t: any) => void = () => {};
    c.tabs.get.mockImplementationOnce(() => new Promise((r) => { release = r; }));
    c.tabs.onActivated.fire({ tabId: 20, windowId: 4 });
    c.tabs.onActivated.fire({ tabId: 12, windowId: 3 });
    await flush();
    release(c._tabs[2]);
    await flush();
    expect(activated().map((m) => m.tabId)).toEqual([12]);
  });
  it("tab removal deletes the snapshot and sends tabClosed", async () => {
    c.tabs.onActivated.fire({ tabId: 12, windowId: 3 });
    await flush();
    store.applyPart(12, YT, "Video", 1, {});
    c.tabs.onRemoved.fire(12, {});
    expect(store.get(12)).toBeUndefined();
    expect(sent.at(-1)).toEqual({ v: 1, type: "tabClosed", tabId: 12 });
    expect(tracker.activeTabId()).toBeNull();
  });
  it("announceActive sends the focused window's active tab even if it repeats", async () => {
    expect(await tracker.announceActive()).toBe(12);
    expect(await tracker.announceActive()).toBe(12);
    expect(activated()).toHaveLength(2);
  });
  it("a tab that vanished mid-activation sends nothing", async () => {
    c.tabs.onActivated.fire({ tabId: 999, windowId: 3 });
    await flush();
    expect(sent).toEqual([]);
  });
});
