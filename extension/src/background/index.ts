import type { WebSocketLike } from "./bridge-client";
import { createServiceWorker } from "./service-worker";
import { ViewerDriver, offscreenImageOps } from "./viewer-driver";

// The driver's sends go through the client, which only exists once the worker is created.
const worker = createServiceWorker({
  chrome,
  createSocket: (url) => new WebSocket(url) as unknown as WebSocketLike,
  fetch: fetch.bind(globalThis),
  now: Date.now,
  viewer: new ViewerDriver({
    tabs: chrome.tabs,
    images: offscreenImageOps,
    send: (msg) => void worker.client.send(msg),
    now: Date.now,
  }),
});
void worker.client.start();
