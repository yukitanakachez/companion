import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { driveViewerContext, startDriveScript } from "../src/content/drive";
import { contractFixture, domFrom } from "./helpers/fixtures";
import { fakeDeps } from "./helpers/content-deps";

const want = contractFixture("ext-tabContext-drive.json").context;
const page = (url = want.url, title = want.title) => domFrom(`<!doctype html><head><title>${title}</title></head><body></body>`, url);

describe("driveViewerContext", () => {
  it("matches the drive fixture", () => expect(driveViewerContext(want.url, want.title)).toEqual(want.drive));
  it("non-file Drive URLs give null", () => {
    expect(driveViewerContext("https://drive.google.com/drive/folders/1AbCdEfGhIjKl", "x")).toBeNull();
    expect(driveViewerContext("https://drive.google.com/drive/my-drive", "x")).toBeNull();
    expect(driveViewerContext("not a url", "x")).toBeNull();
  });
  it("a non-PDF file has a null mimeType", () =>
    expect(driveViewerContext("https://drive.google.com/file/d/1AbCdEfGhIjKl/view", "pic.png - Google Drive")).toEqual({ file: { fileId: "1AbCdEfGhIjKl", title: "pic.png", mimeType: null } }));
});

describe("startDriveScript", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("sends the file on start and re-sends on extractNow", async () => {
    const { deps, sent, extractNow } = fakeDeps(page());
    const stop = startDriveScript({ ...deps, isTopFrame: true });
    await vi.advanceTimersByTimeAsync(0);
    expect(sent).toEqual([{ kind: "contextPart", pageUrl: want.url, pageTitle: want.title, capturedAtMs: 1000, part: { drive: want.drive } }]);
    extractNow();
    await vi.advanceTimersByTimeAsync(0);
    expect(sent).toHaveLength(2);
    stop();
  });
  it("a folder page sends nothing", async () => {
    const { deps, sent } = fakeDeps(page("https://drive.google.com/drive/my-drive", "My Drive"));
    const stop = startDriveScript({ ...deps, isTopFrame: true });
    await vi.advanceTimersByTimeAsync(1000);
    expect(sent).toEqual([]);
    stop();
  });
  it("leaving a file for a folder clears the part", async () => {
    const dom = page();
    const { deps, sent } = fakeDeps(dom);
    const stop = startDriveScript({ ...deps, isTopFrame: true });
    await vi.advanceTimersByTimeAsync(0);
    dom.window.history.pushState({}, "", "/drive/my-drive");
    await vi.advanceTimersByTimeAsync(1000);
    expect(sent.at(-1)).toMatchObject({ part: { drive: null } });
    stop();
  });
  it("a Drive subframe clears its part on pagehide", async () => {
    const dom = page();
    const { deps, sent } = fakeDeps(dom);
    const stop = startDriveScript({ ...deps, isTopFrame: false });
    await vi.advanceTimersByTimeAsync(0);
    dom.window.dispatchEvent(new dom.window.Event("pagehide"));
    expect(sent.at(-1)).toMatchObject({ part: { drive: null } });
    stop();
  });
  it("the top frame doesn't clear on pagehide", async () => {
    const dom = page();
    const { deps, sent } = fakeDeps(dom);
    const stop = startDriveScript({ ...deps, isTopFrame: true });
    await vi.advanceTimersByTimeAsync(0);
    dom.window.dispatchEvent(new dom.window.Event("pagehide"));
    expect(sent).toHaveLength(1);
    stop();
  });
  it("blocked host: drive script sends nothing", async () => {
    const dom = page();
    const { deps, sent } = fakeDeps(dom, true);
    const stop = startDriveScript({ ...deps, isTopFrame: false });
    await vi.advanceTimersByTimeAsync(1000);
    dom.window.dispatchEvent(new dom.window.Event("pagehide"));
    expect(sent).toEqual([]);
    stop();
  });
});
