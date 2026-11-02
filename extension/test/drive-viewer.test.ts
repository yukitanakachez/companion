import { afterEach, describe, expect, it, vi } from "vitest";
import { VIEWER_PAGE_SELECTOR, currentPageIndex, handleViewerMessage, scrollToPage, viewerPages } from "../src/content/drive-viewer";
import { domFrom } from "./helpers/fixtures";

const U = "https://drive.google.com/file/d/1AbCdEfGhIjKl/view";
const load = () => {
  const dom = domFrom("drive/viewer.html", U);
  (dom.window.HTMLElement.prototype as any).scrollIntoView = vi.fn();
  return dom.window.document;
};
const box = (el: Element, top: number, height: number) => {
  el.getBoundingClientRect = () => ({ x: 10, y: top, left: 10, top, width: 800, height, right: 810, bottom: top + height, toJSON() {} }) as DOMRect;
};

describe("drive viewer", () => {
  afterEach(() => vi.useRealTimers());

  it("viewerPages and currentPageIndex on the fixture", () => {
    const pages = viewerPages(load());
    expect(VIEWER_PAGE_SELECTOR).toBeTruthy();
    expect(pages).toHaveLength(3);
    box(pages[0], -900, 1000);
    box(pages[1], 100, 1000);
    box(pages[2], 1100, 1000);
    expect(currentPageIndex(pages, 800)).toBe(1);
    box(pages[0], -100, 1000);
    box(pages[1], 900, 1000);
    expect(currentPageIndex(pages, 800)).toBe(0);
    expect(currentPageIndex([], 800)).toBe(0);
  });
  it("scrollToPage centers the page and returns its rect once rendered", async () => {
    const doc = load();
    const page = viewerPages(doc)[1];
    box(page, 50, 900);
    Object.defineProperty(page.querySelector("img"), "complete", { value: true });
    Object.defineProperty(page.querySelector("img"), "naturalWidth", { value: 800 });
    const out = await scrollToPage(doc, 1);
    expect(page.scrollIntoView).toHaveBeenCalledWith({ block: "center" });
    expect(out.rect).toEqual({ x: 10, y: 50, width: 800, height: 900 });
    expect(out.devicePixelRatio).toBe(doc.defaultView!.devicePixelRatio);
  });
  it("scrollToPage waits for a canvas that renders late", async () => {
    const doc = load();
    const page = viewerPages(doc)[2];
    box(page, 0, 10);
    const p = scrollToPage(doc, 2);
    page.appendChild(doc.createElement("canvas"));
    expect((await p).rect.height).toBe(10);
  });
  it("scrollToPage rejects with timeout if the page never renders", async () => {
    vi.useFakeTimers();
    const doc = load();
    const p = scrollToPage(doc, 2).catch((e) => e);
    await vi.advanceTimersByTimeAsync(3000);
    expect((await p).code).toBe("timeout");
  });
  it("scrollToPage rejects an out-of-range index", async () => {
    await expect(scrollToPage(load(), 9)).rejects.toMatchObject({ code: "notFound" });
  });
  it("handleViewerMessage answers info and maps errors into the reply", async () => {
    const doc = load();
    expect(await handleViewerMessage({ kind: "viewer", op: "info" }, doc)).toEqual({ ok: true, pageCount: 3, currentIndex: expect.any(Number) });
    expect(await handleViewerMessage({ kind: "viewer", op: "scrollTo", index: 9 }, doc)).toMatchObject({ ok: false, code: "notFound" });
  });
});
