import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { CAPTURE_MIN_INTERVAL_MS, ViewerDriver, cropRect } from "../src/background/viewer-driver";
import { RequestError, isExtensionToApp } from "../src/shared/protocol-codec";
import { asChrome, createChromeMock } from "./helpers/chrome-mock";

const rect = { x: 10, y: 20, width: 100, height: 200 };

function setup(active = true) {
  const c = createChromeMock({ tabs: [{ id: 34, windowId: 3, active, url: "https://drive.google.com/file/d/x/view" }] });
  c.tabs.sendMessage.mockImplementation(async (_id: number, m: any) =>
    m.op === "info" ? { ok: true, pageCount: 412, currentIndex: 87 } : { ok: true, rect, devicePixelRatio: 2 });
  const sent: any[] = [];
  const images = { size: vi.fn(async () => ({ width: 1000, height: 1000 })), crop: vi.fn(async () => "CROPPED") };
  let now = 10_000;
  const d = new ViewerDriver({ tabs: asChrome(c).tabs, images, send: (m) => { expect(isExtensionToApp(m)).toBe(true); sent.push(m); }, now: () => now });
  return { c, sent, images, d, tick: (ms: number) => { now += ms; } };
}

describe("cropRect", () => {
  it("scales by devicePixelRatio and clamps", () => {
    expect(cropRect({ x: 10, y: 20, width: 100, height: 200 }, 2, { width: 1000, height: 1000 })).toEqual({ sx: 20, sy: 40, sw: 200, sh: 400 });
    expect(cropRect({ x: -5, y: 900, width: 100, height: 200 }, 1, { width: 1000, height: 1000 })).toEqual({ sx: 0, sy: 900, sw: 95, sh: 100 });
  });
});

describe("ViewerDriver", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("info asks frame 0", async () => {
    const { d, c } = setup();
    expect(await d.info(34)).toEqual({ pageCount: 412, currentIndex: 87 });
    expect(c.tabs.sendMessage).toHaveBeenCalledWith(34, { kind: "viewer", op: "info" }, { frameId: 0 });
  });
  it("capturePage sends progress, scrolls, captures and returns the cropped PNG", async () => {
    const { d, c, sent, images } = setup();
    const p = d.capturePage("r-5", 34, 246);
    await vi.advanceTimersByTimeAsync(0);
    expect(await p).toEqual({ pageIndex: 246, pngBase64: "CROPPED" });
    expect(sent).toEqual([{ v: 1, type: "progress", id: "r-5", step: "Viewer page 247 of 412" }]);
    expect(c.tabs.sendMessage).toHaveBeenCalledWith(34, { kind: "viewer", op: "scrollTo", index: 246 }, { frameId: 0 });
    expect(c.tabs.captureVisibleTab).toHaveBeenCalledWith(3, { format: "png" });
    expect(images.crop).toHaveBeenCalledWith("data:image/png;base64,AAAA", { sx: 20, sy: 40, sw: 200, sh: 400 });
  });
  it("captures are at least 500 ms apart", async () => {
    const { d, c, tick } = setup();
    await d.capturePage("a", 34, 1);
    tick(100);
    let done = false;
    const p = d.capturePage("b", 34, 2).then(() => { done = true; });
    await vi.advanceTimersByTimeAsync(399);
    expect(c.tabs.captureVisibleTab).toHaveBeenCalledTimes(1);
    expect(done).toBe(false);
    await vi.advanceTimersByTimeAsync(1);
    await p;
    expect(c.tabs.captureVisibleTab).toHaveBeenCalledTimes(2);
    expect(CAPTURE_MIN_INTERVAL_MS).toBe(500);
  });
  it("inactive tab → noViewer; out-of-range index → notFound", async () => {
    const inactive = await setup(false).d.capturePage("a", 34, 1).catch((e) => e);
    expect(inactive).toBeInstanceOf(RequestError);
    expect(inactive).toMatchObject({ code: "noViewer", message: "Viewer tab must be visible" });
    const range = await setup().d.capturePage("a", 34, 412).catch((e) => e);
    expect(range).toMatchObject({ code: "notFound" });
    expect((await setup().d.capturePage("a", 34, -1).catch((e) => e)).code).toBe("notFound");
  });
  it("no receiver or zero pages → noViewer", async () => {
    const a = setup();
    a.c.tabs.sendMessage.mockRejectedValue(new Error("Receiving end does not exist"));
    expect((await a.d.info(34).catch((e) => e)).code).toBe("noViewer");
    const b = setup();
    b.c.tabs.sendMessage.mockResolvedValue({ ok: true, pageCount: 0, currentIndex: 0 });
    expect((await b.d.info(34).catch((e) => e)).code).toBe("noViewer");
  });
  it("a page that doesn't render → timeout", async () => {
    const { d, c } = setup();
    c.tabs.sendMessage.mockImplementation(async (_i: number, m: any) => m.op === "info"
      ? { ok: true, pageCount: 5, currentIndex: 0 } : { ok: false, code: "timeout", message: "slow" });
    expect((await d.capturePage("a", 34, 1).catch((e) => e)).code).toBe("timeout");
  });
  it("viewerRestore scrolls back and answers {}", async () => {
    const { d, c } = setup();
    await d.restore(34, 87);
    expect(c.tabs.sendMessage).toHaveBeenCalledWith(34, { kind: "viewer", op: "scrollTo", index: 87 }, { frameId: 0 });
  });
});
