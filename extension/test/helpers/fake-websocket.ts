import type { WebSocketLike } from "../../src/background/bridge-client";

export class FakeWebSocket implements WebSocketLike {
  static instances: FakeWebSocket[] = [];
  static reset() { FakeWebSocket.instances = []; }
  static last() { return FakeWebSocket.instances[FakeWebSocket.instances.length - 1]; }

  readyState = 0;
  bufferedAmount = 0;
  binaryType = "blob";
  sent: (string | Uint8Array)[] = [];
  closedWith: number | undefined;
  onopen: (() => void) | null = null;
  onmessage: ((ev: { data: unknown }) => void) | null = null;
  onclose: ((ev: { code: number }) => void) | null = null;
  onerror: (() => void) | null = null;

  constructor(readonly url: string) { FakeWebSocket.instances.push(this); }
  send(data: string | Uint8Array) {
    if (this.readyState !== 1) throw new Error("not open");
    this.sent.push(data);
  }
  close(code?: number) { this.closedWith = code; this.readyState = 3; }
  serverOpen() { this.readyState = 1; this.onopen?.(); }
  serverSend(obj: unknown) { this.onmessage?.({ data: typeof obj === "string" ? obj : JSON.stringify(obj) }); }
  serverClose(code: number) { this.readyState = 3; this.onclose?.({ code }); }
  fail() { this.readyState = 3; this.onerror?.(); this.onclose?.({ code: 1006 }); }
  sentJson(): any[] { return this.sent.filter((s): s is string => typeof s === "string").map((s) => JSON.parse(s)); }
}
