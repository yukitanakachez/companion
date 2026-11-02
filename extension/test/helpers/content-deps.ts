import { vi } from "vitest";
import type { JSDOM } from "jsdom";
import type { ContentDeps } from "../../src/content/content-deps";
import type { ContentToBackground } from "../../src/shared/messages";

export function fakeDeps(dom: JSDOM, blocked = false) {
  const sent: ContentToBackground[] = [];
  const extract: (() => void)[] = [];
  const deps = {
    doc: dom.window.document,
    win: dom.window as unknown as Window,
    send: vi.fn((m: ContentToBackground) => { sent.push(m); }),
    askBlocked: vi.fn(async (_u: string) => blocked),
    onExtractNow: (cb: () => void) => { extract.push(cb); },
    now: () => 1000,
  } satisfies ContentDeps;
  return { deps, sent, extractNow: () => extract.forEach((f) => f()) };
}
