import { afterEach, describe, expect, it, vi } from "vitest";
import { TabStore } from "../src/background/tab-store";
import { contractFixture } from "./helpers/fixtures";

const yt = () => contractFixture("ext-tabContext-youtube.json").context;
const page = (url: string) => ({ url, title: "t", visibleText: "x", math: [] });
const U = "https://example.org/a";

describe("TabStore", () => {
  afterEach(() => vi.useRealTimers());

  it("merges page and classroom parts into the classroom fixture", () => {
    const s = new TabStore();
    const want = contractFixture("ext-tabContext-classroom.json").context;
    s.applyPart(33, want.url, want.title, 1, { page: want.page });
    expect(s.applyPart(33, want.url, want.title, want.capturedAtMs, { classroom: want.classroom })).toEqual(want);
  });
  it("a part for a different URL starts a fresh context", () => {
    const s = new TabStore();
    s.applyPart(1, U, "t", 1, { page: page(U) });
    const c = s.applyPart(1, "https://example.org/b", "t2", 2, { drive: { file: { fileId: "f", title: "x" } } });
    expect(c.page).toBeUndefined();
    expect(c.url).toBe("https://example.org/b");
  });
  it("a fragment-only URL change keeps the context", () => {
    const s = new TabStore();
    s.applyPart(1, U, "t", 1, { page: page(U) });
    expect(s.applyPart(1, U + "#sec", "t", 2, {}).page).toEqual(page(U));
  });
  it("drive: null clears the drive field", () => {
    const s = new TabStore();
    s.applyPart(1, U, "t", 1, { drive: { file: { fileId: "f", title: "x" } } });
    expect("drive" in s.applyPart(1, U, "t", 2, { drive: null })).toBe(false);
  });
  it("updatePlayhead only touches a matching videoId", () => {
    const s = new TabStore();
    const c = yt();
    s.applyPart(12, c.url, c.title, 1, { youtube: c.youtube });
    s.updatePlayhead(12, "other", 1, null);
    expect(s.get(12)?.youtube?.playheadSeconds).toBe(761);
    s.updatePlayhead(12, c.youtube.videoId, 800, "Ch");
    expect(s.get(12)?.youtube).toMatchObject({ playheadSeconds: 800, chapter: "Ch" });
    expect(s.get(12)?.youtube?.transcript).toHaveLength(3);
  });
  it("setBlocked matches the blocked fixture", () => {
    const want = contractFixture("ext-tabContext-blocked.json").context;
    expect(new TabStore().setBlocked(want.tabId, want.url, want.capturedAtMs)).toEqual(want);
  });
  it("dropIfUrlChanged drops only on a real change", () => {
    const s = new TabStore();
    s.applyPart(1, U, "t", 1, {});
    s.dropIfUrlChanged(1, U + "#x");
    expect(s.get(1)).toBeDefined();
    s.dropIfUrlChanged(1, U + "?q");
    expect(s.get(1)).toBeUndefined();
  });
  it("purge replaces snapshots of newly blocked hosts", () => {
    const s = new TabStore();
    s.applyPart(1, U, "secret title", 1, { page: page(U) });
    s.applyPart(2, "https://keep.org/", "k", 1, {});
    const replaced = s.purge((u) => u.includes("example.org"), 99);
    expect(replaced).toEqual([{ tabId: 1, url: U, title: "", capturedAtMs: 99, blocked: true }]);
    expect(s.get(1)?.page).toBeUndefined();
    expect(s.get(2)?.blocked).toBe(false);
    expect(s.purge((u) => u.includes("example.org"), 100)).toEqual([]);
  });
  it("delete and all", () => {
    const s = new TabStore();
    s.applyPart(1, U, "t", 1, {});
    s.applyPart(2, U, "t", 1, {});
    s.delete(1);
    expect(s.all().map((c) => c.tabId)).toEqual([2]);
  });
  it("waitFor resolves on the next part, or null after the timeout", async () => {
    vi.useFakeTimers();
    const s = new TabStore();
    const p = s.waitFor(1, 250);
    s.applyPart(2, U, "t", 1, {});
    s.applyPart(1, U, "t", 1, { page: page(U) });
    expect((await p)?.tabId).toBe(1);
    const q = s.waitFor(1, 250);
    await vi.advanceTimersByTimeAsync(250);
    expect(await q).toBeNull();
  });
});
