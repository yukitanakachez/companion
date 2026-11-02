import type { WebSocketLike } from "./bridge-client";
import { createServiceWorker } from "./service-worker";

void createServiceWorker({
  chrome,
  createSocket: (url) => new WebSocket(url) as unknown as WebSocketLike,
  fetch: fetch.bind(globalThis),
  now: Date.now,
}).client.start();
