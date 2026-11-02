import { PROTOCOL_VERSION, type ExtensionToApp, type ViewerInfo, type ViewerPageResult } from "../../../contracts/ts/protocol";
import type { ViewerReply } from "../content/drive-viewer";
import type { BackgroundToContent } from "../shared/messages";
import { RequestError } from "../shared/protocol-codec";
import type { ViewerHandler } from "./requests";

export const CAPTURE_MIN_INTERVAL_MS = 500;

export function cropRect(
  rect: { x: number; y: number; width: number; height: number },
  dpr: number,
  image: { width: number; height: number },
): { sx: number; sy: number; sw: number; sh: number } {
  const left = Math.max(0, Math.round(rect.x * dpr));
  const top = Math.max(0, Math.round(rect.y * dpr));
  const right = Math.min(image.width, Math.round((rect.x + rect.width) * dpr));
  const bottom = Math.min(image.height, Math.round((rect.y + rect.height) * dpr));
  return { sx: left, sy: top, sw: Math.max(0, right - left), sh: Math.max(0, bottom - top) };
}

export interface ImageOps {
  size(dataUrl: string): Promise<{ width: number; height: number }>;
  /** Returns base64 PNG. */
  crop(dataUrl: string, r: { sx: number; sy: number; sw: number; sh: number }): Promise<string>;
}

export class ViewerDriver implements ViewerHandler {
  private lastCaptureMs: number | null = null;

  constructor(private readonly deps: { tabs: typeof chrome.tabs; images: ImageOps; send(msg: ExtensionToApp): void; now(): number }) {}

  async info(tabId: number): Promise<ViewerInfo> {
    const reply = await this.ask(tabId, { kind: "viewer", op: "info" });
    if (!("pageCount" in reply) || reply.pageCount === 0) throw new RequestError("noViewer", "This tab has no Drive viewer.");
    return { pageCount: reply.pageCount, currentIndex: reply.currentIndex };
  }

  async capturePage(requestId: string, tabId: number, pageIndex: number): Promise<ViewerPageResult> {
    const { deps } = this;
    const tab = await deps.tabs.get(tabId);
    if (!tab.active) throw new RequestError("noViewer", "Viewer tab must be visible");
    const { pageCount } = await this.info(tabId);
    if (pageIndex < 0 || pageIndex >= pageCount) throw new RequestError("notFound", `The viewer has ${pageCount} pages; there's no page ${pageIndex + 1}.`);
    deps.send({ v: PROTOCOL_VERSION, type: "progress", id: requestId, step: `Viewer page ${pageIndex + 1} of ${pageCount}` });
    const placed = await this.ask(tabId, { kind: "viewer", op: "scrollTo", index: pageIndex });
    if (!("rect" in placed)) throw new RequestError("internal", "The viewer gave no page position.");

    // Chromium rate-limits captureVisibleTab.
    if (this.lastCaptureMs !== null) {
      const wait = this.lastCaptureMs + CAPTURE_MIN_INTERVAL_MS - deps.now();
      if (wait > 0) await new Promise((r) => setTimeout(r, wait));
    }
    const shot = await deps.tabs.captureVisibleTab(tab.windowId, { format: "png" });
    this.lastCaptureMs = deps.now();
    const crop = cropRect(placed.rect, placed.devicePixelRatio, await deps.images.size(shot));
    return { pageIndex, pngBase64: await deps.images.crop(shot, crop) };
  }

  async restore(tabId: number, pageIndex: number): Promise<void> {
    await this.ask(tabId, { kind: "viewer", op: "scrollTo", index: pageIndex });
  }

  /** Top frame only: a viewer inside a Classroom iframe is out of scope and answers noViewer. */
  private async ask(tabId: number, msg: BackgroundToContent): Promise<Extract<ViewerReply, { ok: true }>> {
    let reply: ViewerReply | undefined;
    try {
      reply = (await this.deps.tabs.sendMessage(tabId, msg, { frameId: 0 })) as ViewerReply | undefined;
    } catch {
      throw new RequestError("noViewer", "This tab has no Drive viewer.");
    }
    if (!reply) throw new RequestError("noViewer", "This tab has no Drive viewer.");
    if (!reply.ok) throw new RequestError(reply.code, reply.message);
    return reply;
  }
}

async function bitmapOf(dataUrl: string): Promise<ImageBitmap> {
  return createImageBitmap(await (await fetch(dataUrl)).blob());
}

export const offscreenImageOps: ImageOps = {
  async size(dataUrl) {
    const bitmap = await bitmapOf(dataUrl);
    const size = { width: bitmap.width, height: bitmap.height };
    bitmap.close();
    return size;
  },
  async crop(dataUrl, { sx, sy, sw, sh }) {
    const bitmap = await bitmapOf(dataUrl);
    const canvas = new OffscreenCanvas(sw, sh);
    canvas.getContext("2d")!.drawImage(bitmap, sx, sy, sw, sh, 0, 0, sw, sh);
    bitmap.close();
    const bytes = new Uint8Array(await (await canvas.convertToBlob({ type: "image/png" })).arrayBuffer());
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(binary);
  },
};
