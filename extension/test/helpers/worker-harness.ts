import { expect, vi } from "vitest";
import { createServiceWorker, type SwEnv } from "../../src/background/service-worker";
import { decodeBinaryFrame } from "../../src/shared/binary-frame";
import { isExtensionToApp } from "../../src/shared/protocol-codec";
import { asChrome, createChromeMock } from "./chrome-mock";
import { contractFixture } from "./fixtures";
import { FakeWebSocket } from "./fake-websocket";

export const TOKEN = "cd".repeat(32);
export const YT = "https://www.youtube.com/watch?v=abc";
export const CHASE = "https://secure.chase.com/x";
export const ORG = "https://example.org/a";
export const flush = (ms = 0) => vi.advanceTimersByTimeAsync(ms);

export const MANIFEST = JSON.parse(`{"version":"0.1.0","content_scripts":[
 {"matches":["<all_urls>"],"exclude_matches":["https://www.youtube.com/*","https://drive.google.com/*"],"js":["content-page.js"]},
 {"matches":["https://www.youtube.com/*"],"js":["content-youtube.js"]},
 {"matches":["https://www.youtube.com/*"],"js":["content-youtube-main.js"],"world":"MAIN"},
 {"matches":["https://drive.google.com/*"],"js":["content-drive.js"],"all_frames":true}]}`);

export function harness(over: Partial<SwEnv> = {}, init: Parameters<typeof createChromeMock>[0] = {}) {
  FakeWebSocket.reset();
  const c = createChromeMock({
    focusedWindowId: 3,
    storage: { pairingToken: TOKEN },
    manifest: MANIFEST,
    tabs: [
      { id: 12, windowId: 3, active: true, url: YT, title: "Video" },
      { id: 21, windowId: 3, active: false, url: ORG, title: "Org" },
      { id: 40, windowId: 3, active: false, url: CHASE, title: "Bank" },
    ],
    ...init,
  });
  const sw = createServiceWorker({
    chrome: asChrome(c),
    createSocket: (u) => new FakeWebSocket(u),
    fetch: vi.fn() as unknown as typeof fetch,
    now: () => 5000,
    ...over,
  });
  const ws = () => FakeWebSocket.last();
  /** Every JSON frame the app received; each must satisfy the wire guard. */
  const frames = () => {
    const out = ws().sentJson().filter((m) => m.type !== "hello");
    for (const m of out) expect(isExtensionToApp(m), JSON.stringify(m)).toBe(true);
    return out;
  };
  const binaries = () => ws().sent.filter((s): s is Uint8Array => typeof s !== "string").map(decodeBinaryFrame);
  const connect = async (config = true) => {
    await sw.client.start();
    ws().serverOpen();
    ws().serverSend(contractFixture("app-helloAck.json"));
    if (config) {
      ws().serverSend({ v: 1, type: "config", blocklist: { bundleIDs: [], domains: ["chase.com"] } });
      await flush();
    }
    await flush();
  };
  const request = async (id: string, method: string, params: unknown) => {
    ws().serverSend({ v: 1, type: "request", id, method, params });
  };
  return { c, sw, ws, frames, binaries, connect, request };
}
