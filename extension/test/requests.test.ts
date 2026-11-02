import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ViewerHandler } from "../src/background/requests";
import { CHASE, ORG, flush, harness } from "./helpers/worker-harness";

const responses = (h: ReturnType<typeof harness>) => h.frames().filter((m) => m.type === "response");
const lastResponse = (h: ReturnType<typeof harness>) => responses(h).at(-1);
const page = { url: ORG, title: "Org", visibleText: "x", math: [] };

describe("handleRequest", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("getTabContext(null) returns the active tab's snapshot", async () => {
    const h = harness();
    await h.connect();
    h.sw.store.applyPart(12, "https://www.youtube.com/watch?v=abc", "Video", 1, {});
    await h.request("r-1", "getTabContext", { tabId: null });
    await flush();
    expect(lastResponse(h)).toMatchObject({ id: "r-1", ok: true, result: { context: { tabId: 12 } } });
  });
  it("getTabContext(null) with no known active tab finds the focused one", async () => {
    const h = harness();
    await h.connect();
    h.sw.tracker.activeTabId = () => null;
    h.sw.store.applyPart(12, "https://www.youtube.com/watch?v=abc", "Video", 1, {});
    await h.request("r-1", "getTabContext", { tabId: null });
    await flush();
    expect(lastResponse(h)).toMatchObject({ result: { context: { tabId: 12 } } });
  });
  it("getTabContext waits 250 ms for an extract-now part", async () => {
    const h = harness();
    await h.connect();
    h.c.tabs.sendMessage.mockClear();
    await h.request("r-1", "getTabContext", { tabId: 21 });
    await flush(100);
    expect(h.c.tabs.sendMessage).toHaveBeenCalledWith(21, { kind: "extractNow" });
    expect(responses(h)).toEqual([]);
    h.sw.store.applyPart(21, ORG, "Org", 1, { page });
    await flush();
    expect(lastResponse(h)).toMatchObject({ result: { context: { tabId: 21, page } } });
  });
  it("getTabContext answers context null after 250 ms; a rejected extractNow doesn't matter", async () => {
    const h = harness();
    await h.connect();
    h.c.tabs.sendMessage.mockRejectedValueOnce(new Error("no receiver"));
    await h.request("r-1", "getTabContext", { tabId: 21 });
    await flush(249);
    expect(responses(h)).toEqual([]);
    await flush(1);
    expect(lastResponse(h)).toEqual({ v: 1, type: "response", id: "r-1", ok: true, result: { context: null } });
  });
  it("blocked tab is never asked to extract", async () => {
    const h = harness();
    await h.connect();
    h.c.tabs.sendMessage.mockClear();
    await h.request("r-1", "getTabContext", { tabId: 40 });
    await flush();
    expect(h.c.tabs.sendMessage).not.toHaveBeenCalled();
    expect(lastResponse(h)).toMatchObject({ result: { context: { tabId: 40, title: "", blocked: true, url: CHASE } } });
  });
  it("a stale blocked snapshot of a now-allowed site isn't served", async () => {
    const h = harness();
    await h.connect();
    h.sw.store.setBlocked(21, ORG, 1);
    await h.request("r-1", "getTabContext", { tabId: 21 });
    await flush(250);
    expect(lastResponse(h)).toMatchObject({ result: { context: null } });
  });
  it("a tab that doesn't exist answers notFound", async () => {
    const h = harness();
    await h.connect();
    await h.request("r-1", "getTabContext", { tabId: 999 });
    await flush();
    expect(lastResponse(h)).toMatchObject({ ok: false, error: { code: "notFound" } });
  });
  it("fetchDrivePdf streams frames then the response; failures map to error codes", async () => {
    const bytes = new Uint8Array(1048576 + 10);
    bytes.set(new TextEncoder().encode("%PDF-"));
    const fetchFn = vi.fn(async () => new Response(bytes, { headers: { "content-type": "application/pdf", "content-disposition": 'attachment; filename="B.pdf"' } }));
    const h = harness({ fetch: fetchFn as unknown as typeof fetch });
    await h.connect();
    await h.request("r-2", "fetchDrivePdf", { fileId: "f1" });
    await vi.waitFor(async () => { await flush(); expect(responses(h)).toHaveLength(1); });
    expect(h.binaries().map((b) => [b.header, b.payload.length])).toEqual([[{ id: "r-2", seq: 0, last: false }, 1048576], [{ id: "r-2", seq: 1, last: true }, 10]]);
    expect(lastResponse(h)).toMatchObject({ id: "r-2", ok: true, result: { fileId: "f1", title: "B.pdf", byteLength: 1048586 } });
    const last = h.ws().sent.at(-1);
    expect(typeof last).toBe("string");

    fetchFn.mockImplementationOnce(async () => new Response("", { status: 403 }));
    await h.request("r-3", "fetchDrivePdf", { fileId: "f2" });
    await vi.waitFor(async () => { await flush(); expect(responses(h)).toHaveLength(2); });
    expect(lastResponse(h)).toMatchObject({ id: "r-3", ok: false, error: { code: "downloadBlocked" } });

    fetchFn.mockImplementationOnce(async () => { throw new TypeError("network"); });
    await h.request("r-4", "fetchDrivePdf", { fileId: "f3" });
    await vi.waitFor(async () => { await flush(); expect(responses(h)).toHaveLength(3); });
    expect(lastResponse(h)).toMatchObject({ id: "r-4", ok: false, error: { code: "internal" } });
  });
  it("fetchDrivePdf answers blocked when Drive itself is on the blocklist", async () => {
    const fetchFn = vi.fn();
    const h = harness({ fetch: fetchFn as unknown as typeof fetch });
    await h.connect();
    h.ws().serverSend({ v: 1, type: "config", blocklist: { bundleIDs: [], domains: ["drive.google.com"] } });
    await flush();
    await h.request("r-2", "fetchDrivePdf", { fileId: "f1" });
    await flush();
    expect(lastResponse(h)).toMatchObject({ ok: false, error: { code: "blocked" } });
    expect(fetchFn).not.toHaveBeenCalled();
  });
  it("viewer requests answer noViewer without a handler", async () => {
    const h = harness();
    await h.connect();
    await h.request("r-4", "viewerInfo", { tabId: 21 });
    await h.request("r-5", "viewerCapturePage", { tabId: 21, pageIndex: 1 });
    await h.request("r-6", "viewerRestore", { tabId: 21, pageIndex: 1 });
    await flush();
    expect(responses(h).map((r) => r.error.code)).toEqual(["noViewer", "noViewer", "noViewer"]);
  });
  it("viewer requests reach the handler", async () => {
    const viewer: ViewerHandler = {
      info: vi.fn(async () => ({ pageCount: 412, currentIndex: 87 })),
      capturePage: vi.fn(async () => ({ pageIndex: 246, pngBase64: "AA" })),
      restore: vi.fn(async () => {}),
    };
    const h = harness({ viewer });
    await h.connect();
    await h.request("r-4", "viewerInfo", { tabId: 21 });
    await flush();
    await h.request("r-5", "viewerCapturePage", { tabId: 21, pageIndex: 246 });
    await flush();
    await h.request("r-6", "viewerRestore", { tabId: 21, pageIndex: 87 });
    await flush();
    expect(responses(h).map((r) => r.result)).toEqual([{ pageCount: 412, currentIndex: 87 }, { pageIndex: 246, pngBase64: "AA" }, {}]);
    expect(viewer.capturePage).toHaveBeenCalledWith("r-5", 21, 246);
  });
  it("a viewer request on a blocked tab answers blocked without touching it", async () => {
    const viewer: ViewerHandler = { info: vi.fn(), capturePage: vi.fn(), restore: vi.fn() };
    const h = harness({ viewer });
    await h.connect();
    await h.request("r-4", "viewerInfo", { tabId: 40 });
    await flush();
    expect(lastResponse(h)).toMatchObject({ ok: false, error: { code: "blocked" } });
    expect(viewer.info).not.toHaveBeenCalled();
  });
  it("an unexpected viewer exception answers internal", async () => {
    const viewer: ViewerHandler = { info: vi.fn(async () => { throw new Error("boom"); }), capturePage: vi.fn(), restore: vi.fn() };
    const h = harness({ viewer });
    await h.connect();
    await h.request("r-4", "viewerInfo", { tabId: 21 });
    await flush();
    expect(lastResponse(h)).toMatchObject({ ok: false, error: { code: "internal" } });
  });
});
