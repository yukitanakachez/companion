import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MAX_CHUNK_BYTES } from "../../contracts/ts/protocol";
import { BridgeClient, backoffDelay, detectBrowserName, type BridgeClientDeps } from "../src/background/bridge-client";
import type { ExtensionBridgeStatus } from "../src/shared/messages";
import { isExtensionToApp } from "../src/shared/protocol-codec";
import { contractFixture } from "./helpers/fixtures";
import { FakeWebSocket } from "./helpers/fake-websocket";

const TOKEN = "ab".repeat(32);
const ack = contractFixture("app-helloAck.json");

function make(over: Partial<BridgeClientDeps> = {}) {
  const statuses: ExtensionBridgeStatus[] = [];
  const onAppMessage = vi.fn();
  const onConnected = vi.fn();
  const onDisconnected = vi.fn();
  const client = new BridgeClient({
    createSocket: (u) => new FakeWebSocket(u),
    getToken: async () => TOKEN,
    extensionVersion: "0.1.0",
    browserName: "Dia",
    onAppMessage, onConnected, onDisconnected,
    onStatus: (s) => statuses.push(s),
    ...over,
  });
  return { client, statuses, onAppMessage, onConnected, onDisconnected };
}
const sockets = () => FakeWebSocket.instances;
const lastState = (s: ExtensionBridgeStatus[]) => s[s.length - 1]?.state;
const failAll = () => { for (let i = 0; i < 5; i++) FakeWebSocket.last().fail(); };

describe("BridgeClient", () => {
  beforeEach(() => { vi.useFakeTimers(); FakeWebSocket.reset(); });
  afterEach(() => vi.useRealTimers());

  async function connected(over: Partial<BridgeClientDeps> = {}) {
    const m = make(over);
    await m.client.start();
    sockets()[0].serverOpen();
    sockets()[0].serverSend(ack);
    return m;
  }

  it("tries 47823 first and sends hello as the first frame", async () => {
    const { client } = make();
    await client.start();
    expect(sockets()[0].url).toBe("ws://127.0.0.1:47823");
    expect(sockets()[0].binaryType).toBe("arraybuffer");
    sockets()[0].serverOpen();
    const first = JSON.parse(sockets()[0].sent[0] as string);
    expect(first).toEqual({ v: 1, type: "hello", token: TOKEN, extensionVersion: "0.1.0", browserName: "Dia" });
    expect(isExtensionToApp(first)).toBe(true);
  });
  it("falls through the ports in order", async () => {
    const { client } = make();
    await client.start();
    sockets()[0].fail();
    sockets()[1].fail();
    expect(sockets()[2].url).toBe("ws://127.0.0.1:47825");
  });
  it("retries a failed round after 500, 1000, 2000, 5000, 5000 ms", async () => {
    const { client, statuses } = make();
    await client.start();
    for (const delay of [500, 1000, 2000, 5000, 5000]) {
      failAll();
      expect(lastState(statuses)).toBe("disconnected");
      const n = sockets().length;
      await vi.advanceTimersByTimeAsync(delay - 1);
      expect(sockets().length).toBe(n);
      await vi.advanceTimersByTimeAsync(1);
      expect(sockets().length).toBe(n + 1);
      expect(FakeWebSocket.last().url).toBe("ws://127.0.0.1:47823");
      expect(lastState(statuses)).toBe("disconnected");
    }
  });
  it("backoffDelay table", () => {
    expect([1, 2, 3, 4, 9].map(backoffDelay)).toEqual([500, 1000, 2000, 5000, 5000]);
  });
  it("helloAck → connected status with port and app version; backoff resets", async () => {
    const { client, statuses, onConnected } = make();
    await client.start();
    failAll();
    await vi.advanceTimersByTimeAsync(500);
    failAll();
    await vi.advanceTimersByTimeAsync(1000);
    FakeWebSocket.last().fail();
    FakeWebSocket.last().serverOpen();
    FakeWebSocket.last().serverSend(ack);
    expect(onConnected).toHaveBeenCalledWith(47824, "0.1.0");
    expect(statuses[statuses.length - 1]).toMatchObject({ state: "connected", port: 47824, appVersion: "0.1.0" });
    expect(client.connected).toBe(true);
    FakeWebSocket.last().serverClose(1006);
    const n = sockets().length;
    await vi.advanceTimersByTimeAsync(499);
    expect(sockets().length).toBe(n);
    await vi.advanceTimersByTimeAsync(1);
    expect(sockets().length).toBe(n + 1);
  });
  it("routes config and request to onAppMessage; ignores ping, malformed and v:2 frames", async () => {
    const { onAppMessage } = await connected();
    const ws = sockets()[0];
    ws.serverSend(contractFixture("app-ping.json"));
    ws.serverSend("not json");
    ws.serverSend({ v: 2, type: "config", blocklist: { bundleIDs: [], domains: [] } });
    ws.serverSend(new Uint8Array(3));
    expect(onAppMessage).not.toHaveBeenCalled();
    ws.serverSend(contractFixture("app-config.json"));
    ws.serverSend(contractFixture("app-request-getTabContext.json"));
    expect(onAppMessage.mock.calls.map((c) => c[0].type)).toEqual(["config", "request"]);
  });
  it("close 4001 → tokenRejected, no retry for 60 s; restart() reconnects", async () => {
    const { client, statuses } = make();
    await client.start();
    sockets()[0].serverOpen();
    sockets()[0].serverClose(4001);
    expect(lastState(statuses)).toBe("tokenRejected");
    await vi.advanceTimersByTimeAsync(60_000);
    expect(sockets().length).toBe(1);
    await client.start();
    expect(sockets().length).toBe(1);
    await client.restart();
    expect(sockets().length).toBe(2);
  });
  it("close 4002 → versionMismatch, no retry", async () => {
    const { client, statuses } = make();
    await client.start();
    sockets()[0].serverOpen();
    sockets()[0].serverClose(4002);
    expect(lastState(statuses)).toBe("versionMismatch");
    await vi.advanceTimersByTimeAsync(60_000);
    expect(sockets().length).toBe(1);
  });
  it("no token → noToken status and no socket", async () => {
    const { client, statuses } = make({ getToken: async () => null });
    await client.start();
    expect(lastState(statuses)).toBe("noToken");
    expect(sockets().length).toBe(0);
  });
  it("start() twice while connecting opens one socket", async () => {
    const { client } = make();
    await Promise.all([client.start(), client.start()]);
    await client.start();
    expect(sockets().length).toBe(1);
  });
  it("a dropped connection calls onDisconnected and retries from 47823 after 500 ms", async () => {
    const { onDisconnected, client } = await connected();
    sockets()[0].serverClose(1006);
    expect(onDisconnected).toHaveBeenCalledTimes(1);
    expect(client.connected).toBe(false);
    await vi.advanceTimersByTimeAsync(499);
    expect(sockets().length).toBe(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(sockets()[1].url).toBe("ws://127.0.0.1:47823");
  });
  it("no helloAck within 5,000 ms closes the socket and tries the next port", async () => {
    const { client } = make();
    await client.start();
    sockets()[0].serverOpen();
    await vi.advanceTimersByTimeAsync(4999);
    expect(sockets().length).toBe(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(sockets()[0].readyState).toBe(3);
    expect(sockets()[1].url).toBe("ws://127.0.0.1:47824");
  });
  it("send() returns false and sends nothing while disconnected", async () => {
    const { client } = make();
    await client.start();
    sockets()[0].serverOpen();
    const before = sockets()[0].sent.length;
    expect(client.send(contractFixture("ext-tabClosed.json"))).toBe(false);
    expect(sockets()[0].sent.length).toBe(before);
  });
  it("sendBinary waits while bufferedAmount exceeds 8 MiB", async () => {
    const { client } = await connected();
    const ws = sockets()[0];
    const before = ws.sent.length;
    ws.bufferedAmount = 8 * MAX_CHUNK_BYTES + 1;
    let done = false;
    const p = client.sendBinary(new Uint8Array(1)).then(() => { done = true; });
    await vi.advanceTimersByTimeAsync(1000);
    expect(done).toBe(false);
    expect(ws.sent.length).toBe(before);
    ws.bufferedAmount = 0;
    await vi.advanceTimersByTimeAsync(1000);
    await p;
    expect(ws.sent.length).toBe(before + 1);
  });
  it("sendBinary rejects when the connection drops while it waits", async () => {
    const { client } = await connected();
    const ws = sockets()[0];
    ws.bufferedAmount = 8 * MAX_CHUNK_BYTES + 1;
    const p = client.sendBinary(new Uint8Array(1));
    const assertion = expect(p).rejects.toThrow();
    ws.serverClose(1006);
    await vi.advanceTimersByTimeAsync(100);
    await assertion;
  });
  it("detectBrowserName", () => {
    expect(detectBrowserName([{ brand: "Not)A;Brand" }, { brand: "Chromium" }, { brand: "Dia" }])).toBe("Dia");
    expect(detectBrowserName([{ brand: "Chromium" }])).toBe("Chromium");
    expect(detectBrowserName(undefined)).toBe("Chromium");
  });
});
