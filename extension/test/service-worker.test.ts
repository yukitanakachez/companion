import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { FakeWebSocket } from "./helpers/fake-websocket";
import { CHASE, ORG, TOKEN, YT, flush, harness } from "./helpers/worker-harness";

const part = (over: object = {}) => ({ kind: "contextPart", pageUrl: ORG, pageTitle: "Org", capturedAtMs: 7,
  part: { page: { url: ORG, title: "Org", visibleText: "x", math: [] } }, ...over });
const senderOrg = { tab: { id: 21, url: ORG, title: "Org" }, frameId: 0 };

describe("service worker", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("registers every listener synchronously", () => {
    const { c } = harness();
    for (const e of [c.runtime.onMessage, c.tabs.onActivated, c.tabs.onUpdated, c.tabs.onRemoved, c.windows.onFocusChanged, c.storage.onChanged, c.runtime.onInstalled]) {
      expect(e.hasListeners()).toBe(true);
    }
  });
  it("contextPart is merged and forwarded as tabContext", async () => {
    const h = harness();
    await h.connect();
    await h.c.deliver(part(), senderOrg);
    await flush();
    const ctx = h.frames().filter((m) => m.type === "tabContext" && m.context.tabId === 21).at(-1).context;
    expect(ctx).toMatchObject({ tabId: 21, url: ORG, title: "Org", capturedAtMs: 7, blocked: false, page: { visibleText: "x" } });
    expect(h.sw.store.get(21)?.page?.visibleText).toBe("x");
  });
  it("a subframe's part takes url and title from the tab", async () => {
    const h = harness();
    await h.connect();
    await h.c.deliver(part({ pageUrl: "https://drive.google.com/file/d/x", pageTitle: "Frame", part: { drive: { file: { fileId: "f", title: "x" } } } }), { ...senderOrg, frameId: 3 });
    await flush();
    expect(h.sw.store.get(21)).toMatchObject({ url: ORG, title: "Org", drive: { file: { fileId: "f" } } });
  });
  it("parts from a blocked tab are dropped", async () => {
    const h = harness();
    await h.connect();
    const before = h.frames().length;
    await h.c.deliver(part({ pageUrl: "https://drive.google.com/file/d/x", part: { drive: { file: { fileId: "f", title: "x" } } } }),
      { tab: { id: 40, url: CHASE, title: "Bank" }, frameId: 3 });
    await flush();
    expect(h.sw.store.get(40)).toBeUndefined();
    expect(h.frames()).toHaveLength(before);
  });
  it("isBlocked answers and forwards a blocked context", async () => {
    const h = harness();
    await h.connect();
    expect(await h.c.deliver({ kind: "isBlocked", url: ORG }, senderOrg)).toEqual({ blocked: false });
    const answer = h.c.deliver({ kind: "isBlocked", url: CHASE }, { tab: { id: 40, url: CHASE, title: "Bank" }, frameId: 0 });
    await flush();
    expect(await answer).toEqual({ blocked: true });
    expect(h.frames().at(-1)).toEqual({ v: 1, type: "tabContext", context: { tabId: 40, url: CHASE, title: "", capturedAtMs: 5000, blocked: true } });
  });
  it("an allowed iframe in a blocked tab is told it's blocked", async () => {
    const h = harness();
    await h.connect();
    expect(await h.c.deliver({ kind: "isBlocked", url: "https://drive.google.com/file/d/x" }, { tab: { id: 40, url: CHASE }, frameId: 3 })).toEqual({ blocked: true });
  });
  it("a blocked iframe in an allowed tab doesn't mark the whole tab", async () => {
    const h = harness();
    await h.connect();
    expect(await h.c.deliver({ kind: "isBlocked", url: CHASE }, { ...senderOrg, frameId: 3 })).toEqual({ blocked: true });
    expect(h.sw.store.get(21)?.blocked).not.toBe(true);
  });
  it("a sleeping worker's isBlocked waits for the stored blocklist", async () => {
    const h = harness({}, { storage: { pairingToken: TOKEN, blocklist: { bundleIDs: [], domains: ["example.org"] } }, storageGetDelayMs: 50 });
    let answer: unknown;
    void h.c.deliver({ kind: "isBlocked", url: ORG }, senderOrg).then((r) => { answer = r; });
    await flush(49);
    expect(answer).toBeUndefined();
    await flush(1);
    expect(answer).toEqual({ blocked: true });
  });
  it("playhead → youtubePlayhead with the sender tab id; snapshot updated", async () => {
    const h = harness();
    await h.connect();
    const youtube = { videoId: "abc", title: "t", playheadSeconds: 0, transcriptStatus: "loading", transcript: [] };
    await h.c.deliver(part({ pageUrl: YT, part: { youtube } }), { tab: { id: 12, url: YT }, frameId: 0 });
    await flush();
    await h.c.deliver({ kind: "playhead", videoId: "abc", playheadSeconds: 99, chapter: null }, { tab: { id: 12, url: YT }, frameId: 0 });
    await flush();
    expect(h.frames().at(-1)).toEqual({ v: 1, type: "youtubePlayhead", tabId: 12, videoId: "abc", playheadSeconds: 99, chapter: null });
    expect(h.sw.store.get(12)?.youtube?.playheadSeconds).toBe(99);
  });
  it("a playhead from a blocked tab is dropped", async () => {
    const h = harness();
    await h.connect();
    const before = h.frames().length;
    await h.c.deliver({ kind: "playhead", videoId: "abc", playheadSeconds: 99, chapter: null }, { tab: { id: 40, url: CHASE }, frameId: 0 });
    await flush();
    expect(h.frames()).toHaveLength(before);
  });
  it("new config purges cached snapshots", async () => {
    const h = harness();
    await h.connect();
    await h.c.deliver(part(), senderOrg);
    await flush();
    const config = { bundleIDs: [], domains: ["example.org"] };
    h.ws().serverSend({ v: 1, type: "config", blocklist: config });
    await flush();
    expect(h.frames().at(-1)).toEqual({ v: 1, type: "tabContext", context: { tabId: 21, url: ORG, title: "", capturedAtMs: 5000, blocked: true } });
    expect(h.c._data.blocklist).toEqual(config);
    expect(h.sw.store.get(21)?.page).toBeUndefined();
  });
  it("resyncs after helloAck and config", async () => {
    const h = harness();
    await h.c.deliver(part(), senderOrg); // A snapshot from before the connection.
    await flush();
    await h.connect(false);
    expect(h.frames().filter((m) => m.type === "tabActivated")).toEqual([]);
    expect(h.c.tabs.sendMessage).not.toHaveBeenCalled();
    h.ws().serverSend({ v: 1, type: "config", blocklist: { bundleIDs: [], domains: [] } });
    await flush();
    const types = h.frames().map((m) => m.type);
    expect(types[0]).toBe("tabActivated");
    expect(h.frames()[0]).toMatchObject({ tabId: 12, url: YT });
    expect(h.frames().find((m) => m.type === "tabContext").context.tabId).toBe(21);
    expect(h.c.tabs.sendMessage).toHaveBeenCalledWith(12, { kind: "extractNow" });
    h.ws().serverSend({ v: 1, type: "config", blocklist: { bundleIDs: [], domains: [] } });
    await flush();
    expect(h.frames().filter((m) => m.type === "tabActivated")).toHaveLength(1);
  });
  it("resync doesn't ask a blocked active tab to extract", async () => {
    const h = harness({}, { tabs: [{ id: 40, windowId: 3, active: true, url: CHASE, title: "Bank" }] });
    await h.connect();
    expect(h.c.tabs.sendMessage).not.toHaveBeenCalled();
    expect(h.frames()[0]).toMatchObject({ type: "tabActivated", tabId: 40, title: "" });
    expect(h.frames().find((m) => m.type === "tabContext").context.blocked).toBe(true);
  });
  it("a reconnect resyncs again", async () => {
    const h = harness();
    await h.connect();
    h.ws().serverClose(1006);
    await flush(500);
    h.ws().serverOpen();
    h.ws().serverSend({ v: 1, type: "helloAck", appVersion: "0.1.0" });
    h.ws().serverSend({ v: 1, type: "config", blocklist: { bundleIDs: [], domains: [] } });
    await flush();
    expect(h.frames()[0]).toMatchObject({ type: "tabActivated", tabId: 12 });
  });
  it("pairingToken change and reconnectNow restart the client", async () => {
    const h = harness();
    await h.connect();
    const n = FakeWebSocket.instances.length;
    await h.c.storage.local.set({ pairingToken: "ee".repeat(32) });
    await flush();
    expect(FakeWebSocket.instances.length).toBe(n + 1);
    h.ws().serverOpen();
    expect(h.ws().sentJson()[0].token).toBe("ee".repeat(32));
    await h.c.deliver({ kind: "reconnectNow" }, {});
    await flush();
    expect(FakeWebSocket.instances.length).toBe(n + 2);
  });
  it("status changes are written to bridgeStatus", async () => {
    const h = harness();
    await h.connect();
    expect(h.c._data.bridgeStatus).toMatchObject({ state: "connected", port: 47823, appVersion: "0.1.0" });
    h.ws().serverClose(4001);
    expect(h.c._data.bridgeStatus).toMatchObject({ state: "tokenRejected" });
  });
  it("onInstalled injects matching content scripts into open tabs", async () => {
    const h = harness({}, { tabs: [
      { id: 12, windowId: 3, active: true, url: YT, title: "Video" },
      { id: 21, windowId: 3, active: false, url: ORG, title: "Org" },
      { id: 30, windowId: 3, active: false, url: "chrome://settings", title: "S" },
      { id: 34, windowId: 3, active: false, url: "https://drive.google.com/file/d/x/view", title: "D" },
      { id: 40, windowId: 3, active: false, url: CHASE, title: "Bank" },
    ] });
    h.c.runtime.onInstalled.fire({ reason: "install" });
    await flush();
    const calls = h.c.scripting.executeScript.mock.calls.map((a) => a[0]) as any[];
    const on = (id: number) => calls.filter((x) => x.target.tabId === id);
    expect(on(12).map((x) => [x.files[0], x.world])).toEqual([["content-youtube.js", undefined], ["content-youtube-main.js", "MAIN"]]);
    expect(on(21).map((x) => x.files[0])).toEqual(["content-page.js"]);
    expect(on(30)).toEqual([]);
    expect(on(34)[0].target.allFrames).toBe(true);
    expect(on(40)).toEqual([]);
  });
  it("a tab refusing injection doesn't stop the others", async () => {
    const h = harness();
    h.c.scripting.executeScript.mockRejectedValueOnce(new Error("Cannot access"));
    h.c.runtime.onInstalled.fire({ reason: "install" });
    await flush();
    expect(h.c.scripting.executeScript.mock.calls.length).toBeGreaterThan(1);
  });
  it("disconnecting aborts an in-flight download", async () => {
    let signal: AbortSignal | undefined;
    const fetchFn = vi.fn((_u: string, o: RequestInit) => { signal = o.signal ?? undefined; return new Promise<Response>(() => {}); });
    const h = harness({ fetch: fetchFn as unknown as typeof fetch });
    await h.connect();
    await h.request("r-2", "fetchDrivePdf", { fileId: "f" });
    await flush();
    expect(signal?.aborted).toBe(false);
    h.ws().serverClose(1006);
    expect(signal?.aborted).toBe(true);
  });
});
