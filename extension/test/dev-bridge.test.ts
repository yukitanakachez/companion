import { afterEach, describe, expect, it, vi } from "vitest";
import { startDevBridge } from "../tools/dev-bridge-lib.mjs";
import { BridgeClient } from "../src/background/bridge-client";
import { encodeBinaryFrame } from "../src/shared/binary-frame";
import { encodeMessage, isAppToExtension, okResponse } from "../src/shared/protocol-codec";

const TOKEN = "ab".repeat(32);
const hello = (over: object = {}) => JSON.stringify({ v: 1, type: "hello", token: TOKEN, extensionVersion: "0.1.0", browserName: "Node", ...over });

describe("dev bridge", () => {
  let bridge: Awaited<ReturnType<typeof startDevBridge>>;
  const open: WebSocket[] = [];
  const start = async () => {
    bridge = await startDevBridge({ port: 0, token: TOKEN, log: () => {} });
    return bridge;
  };
  const connect = () => new Promise<WebSocket>((resolve) => {
    const ws = new WebSocket(`ws://127.0.0.1:${bridge.port}`);
    ws.binaryType = "arraybuffer";
    open.push(ws);
    ws.onopen = () => resolve(ws);
  });
  const closed = (ws: WebSocket) => new Promise<number>((r) => { ws.onclose = (e) => r(e.code); });
  afterEach(async () => {
    open.splice(0).forEach((w) => w.close());
    await bridge?.close();
  });

  it("closes with 4001 on a wrong token", async () => {
    await start();
    const ws = await connect();
    const code = closed(ws);
    ws.send(hello({ token: "00".repeat(32) }));
    expect(await code).toBe(4001);
  });
  it("closes with 4001 when the first message isn't hello", async () => {
    await start();
    const ws = await connect();
    const code = closed(ws);
    ws.send(JSON.stringify({ v: 1, type: "tabClosed", tabId: 1 }));
    expect(await code).toBe(4001);
  });
  it("closes with 4002 on a v:2 hello", async () => {
    await start();
    const ws = await connect();
    const code = closed(ws);
    ws.send(hello({ v: 2 }));
    expect(await code).toBe(4002);
  });
  it("replies helloAck then config to a good hello", async () => {
    await start();
    const ws = await connect();
    const got: any[] = [];
    ws.onmessage = (e) => got.push(JSON.parse(e.data as string));
    ws.send(hello());
    await vi.waitFor(() => expect(got).toHaveLength(2));
    expect(got.map((m) => m.type)).toEqual(["helloAck", "config"]);
    expect(got.every(isAppToExtension)).toBe(true);
    expect(got[0].appVersion).toBe("dev");
  });
  it("a real BridgeClient connects and reports connected", async () => {
    await start();
    let token: string | null = TOKEN;
    const onConnected = vi.fn();
    const client = new BridgeClient({
      createSocket: (u) => new WebSocket(u) as never,
      getToken: async () => token,
      extensionVersion: "0.1.0",
      browserName: "Node",
      ports: [bridge.port],
      onAppMessage: () => {},
      onConnected,
      onDisconnected: () => {},
      onStatus: () => {},
    });
    await client.start();
    await vi.waitFor(() => expect(onConnected).toHaveBeenCalledWith(bridge.port, "dev"));
    expect(client.connected).toBe(true);
    token = null;
    await client.restart();
  });
  it("request('fetchDrivePdf') reassembles binary frames", async () => {
    await start();
    const ws = await connect();
    const original = new Uint8Array(2_621_440).map((_, i) => i % 251);
    ws.onmessage = (e) => {
      const m = JSON.parse(e.data as string);
      if (m.type !== "request") return;
      const M = 1048576;
      ws.send(encodeBinaryFrame({ id: m.id, seq: 0, last: false }, original.subarray(0, M)) as Uint8Array<ArrayBuffer>);
      ws.send(encodeBinaryFrame({ id: m.id, seq: 1, last: false }, original.subarray(M, 2 * M)) as Uint8Array<ArrayBuffer>);
      ws.send(encodeBinaryFrame({ id: m.id, seq: 2, last: true }, original.subarray(2 * M)) as Uint8Array<ArrayBuffer>);
      ws.send(encodeMessage(okResponse(m.id, { fileId: m.params.fileId, title: "t.pdf", byteLength: original.length })));
    };
    ws.send(hello());
    await vi.waitFor(() => expect(bridge.connected()).toBe(true));
    const { response, bytes } = await bridge.request("fetchDrivePdf", { fileId: "f" });
    expect(Buffer.compare(bytes!, Buffer.from(original))).toBe(0);
    expect(response.result.byteLength).toBe(2621440);
  });
  it("kick closes the client with the given code", async () => {
    await start();
    const ws = await connect();
    const code = closed(ws);
    ws.send(hello());
    await vi.waitFor(() => expect(bridge.connected()).toBe(true));
    bridge.kick(4001);
    expect(await code).toBe(4001);
  });
  it("request without a client rejects", async () => {
    await start();
    await expect(bridge.request("getTabContext", { tabId: null })).rejects.toThrow(/no extension/i);
  });
  it("logs a one-line summary of a tabContext", async () => {
    const log = vi.fn();
    bridge = await startDevBridge({ port: 0, token: TOKEN, log });
    const ws = await connect();
    ws.send(hello());
    await vi.waitFor(() => expect(bridge.connected()).toBe(true));
    ws.send(JSON.stringify({ v: 1, type: "tabContext", context: { tabId: 7, url: "https://x.test/", title: "", capturedAtMs: 1, blocked: true } }));
    await vi.waitFor(() => expect(log.mock.calls.some((c) => /tabContext tab=7 .*blocked=true/.test(c[0]))).toBe(true));
  });
});
