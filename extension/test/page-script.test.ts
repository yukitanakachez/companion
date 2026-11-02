import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { debounce, watchNavigation } from "../src/content/navigation";
import { startPageScript } from "../src/content/page";
import { domFrom } from "./helpers/fixtures";
import { fakeDeps } from "./helpers/content-deps";

const U = "https://example.org/q";

describe("page script", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("blocked host: nothing is read or sent", async () => {
    const dom = domFrom("pages/katex.html", U);
    const { deps } = fakeDeps(dom, true);
    const spy = vi.spyOn(dom.window.document, "querySelectorAll");
    const stop = startPageScript(deps);
    await vi.advanceTimersByTimeAsync(5000);
    dom.window.dispatchEvent(new dom.window.Event("scroll"));
    await vi.advanceTimersByTimeAsync(5000);
    expect(spy).not.toHaveBeenCalled();
    expect(deps.send).not.toHaveBeenCalled();
    stop();
  });
  it("pushes once on start and once 1,000 ms after the last of several scrolls", async () => {
    const dom = domFrom("pages/plain.html", U);
    const { deps, sent } = fakeDeps(dom);
    const stop = startPageScript(deps);
    await vi.advanceTimersByTimeAsync(0);
    expect(sent).toEqual([{ kind: "contextPart", pageUrl: U, pageTitle: "Plain page", capturedAtMs: 1000,
      part: { page: { url: U, title: "Plain page", visibleText: "Hello there world", math: [] } } }]);
    for (let i = 0; i < 3; i++) {
      dom.window.dispatchEvent(new dom.window.Event("scroll"));
      await vi.advanceTimersByTimeAsync(400);
    }
    expect(sent).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(599);
    expect(sent).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(sent).toHaveLength(2);
    stop();
  });
  it("asks the guard before every extraction, not only the first", async () => {
    const dom = domFrom("pages/plain.html", U);
    const { deps, sent, extractNow } = fakeDeps(dom);
    const stop = startPageScript(deps);
    await vi.advanceTimersByTimeAsync(0);
    deps.askBlocked.mockResolvedValue(true);
    extractNow();
    await vi.advanceTimersByTimeAsync(0);
    expect(deps.askBlocked).toHaveBeenCalledTimes(2);
    expect(sent).toHaveLength(1);
    stop();
  });
  it("pushes on SPA navigation (title or URL change)", async () => {
    const dom = domFrom("pages/plain.html", U);
    const { deps, sent } = fakeDeps(dom);
    const stop = startPageScript(deps);
    await vi.advanceTimersByTimeAsync(0);
    dom.window.history.pushState({}, "", "/other");
    await vi.advanceTimersByTimeAsync(1000);
    expect(sent).toHaveLength(2);
    expect(sent[1]).toMatchObject({ pageUrl: "https://example.org/other" });
    dom.window.document.title = "New title";
    await vi.advanceTimersByTimeAsync(0);
    expect(sent).toHaveLength(3);
    expect(sent[2]).toMatchObject({ pageTitle: "New title" });
    stop();
  });
  it("extractNow pushes a fresh part", async () => {
    const dom = domFrom("pages/plain.html", U);
    const { deps, sent, extractNow } = fakeDeps(dom);
    const stop = startPageScript(deps);
    await vi.advanceTimersByTimeAsync(0);
    dom.window.document.body.innerHTML = "<p>changed</p>";
    extractNow();
    await vi.advanceTimersByTimeAsync(0);
    expect(sent.at(-1)).toMatchObject({ part: { page: { visibleText: "changed" } } });
    stop();
  });
  it("stop() ends scroll and navigation pushes", async () => {
    const dom = domFrom("pages/plain.html", U);
    const { deps, sent } = fakeDeps(dom);
    const stop = startPageScript(deps);
    await vi.advanceTimersByTimeAsync(0);
    stop();
    dom.window.dispatchEvent(new dom.window.Event("scroll"));
    dom.window.history.pushState({}, "", "/other");
    await vi.advanceTimersByTimeAsync(5000);
    expect(sent).toHaveLength(1);
  });
});

describe("navigation helpers", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());
  it("debounce fires once after the quiet period", () => {
    const f = vi.fn();
    const d = debounce(f, 100);
    d(1); d(2);
    vi.advanceTimersByTime(100);
    expect(f.mock.calls).toEqual([[2]]);
  });
  it("watchNavigation doesn't fire without a change", async () => {
    const dom = domFrom("pages/plain.html", U);
    const f = vi.fn();
    const stop = watchNavigation(dom.window as unknown as Window, f);
    await vi.advanceTimersByTimeAsync(5000);
    expect(f).not.toHaveBeenCalled();
    dom.window.history.pushState({}, "", "/b");
    dom.window.dispatchEvent(new dom.window.PopStateEvent("popstate"));
    expect(f).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1000);
    expect(f).toHaveBeenCalledTimes(1);
    stop();
  });
});
