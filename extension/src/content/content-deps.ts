import { askBlocked } from "../shared/guard";
import type { BackgroundToContent, ContentToBackground } from "../shared/messages";

export interface ContentDeps {
  doc: Document;
  win: Window;
  send(msg: ContentToBackground): void;
  askBlocked(url: string): Promise<boolean>;
  onExtractNow(cb: () => void): void;
  now(): number;
}

/** Wires the real window and chrome.runtime sendMessage/onMessage. */
export function liveContentDeps(): ContentDeps {
  return {
    doc: document,
    win: window,
    send: (msg) => {
      chrome.runtime.sendMessage(msg).catch(() => {
        // The worker is restarting or the extension was reloaded; the next push or resync recovers.
      });
    },
    askBlocked: (url) => askBlocked(url),
    onExtractNow: (cb) => {
      chrome.runtime.onMessage.addListener((msg: BackgroundToContent) => {
        if (msg.kind === "extractNow") cb();
      });
    },
    now: () => Date.now(),
  };
}
