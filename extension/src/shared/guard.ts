import type { ContentToBackground } from "./messages";

export const ASK_BLOCKED_TIMEOUT_MS = 1000;

/** Fails closed: anything but an explicit `{ blocked: false }` within the timeout counts as blocked. */
export function askBlocked(
  url: string,
  sendMessage: (m: ContentToBackground) => Promise<unknown> = (m) => chrome.runtime.sendMessage(m),
): Promise<boolean> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(true), ASK_BLOCKED_TIMEOUT_MS);
    const finish = (blocked: boolean) => {
      clearTimeout(timer);
      resolve(blocked);
    };
    try {
      sendMessage({ kind: "isBlocked", url }).then(
        (r) => finish((r as { blocked?: unknown } | undefined)?.blocked !== false),
        () => finish(true),
      );
    } catch {
      finish(true);
    }
  });
}
