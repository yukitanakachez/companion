// A stand-in for the Companion app's bridge server, for trying the extension without the app.
import { WebSocketServer } from "ws";
import { STARTER_BLOCKED_DOMAINS } from "../../contracts/ts/protocol.ts";

const HELLO_TIMEOUT_MS = 5000;
const PING_MS = 20000;
const REQUEST_TIMEOUT_MS = 120000;

function summarize(m) {
  switch (m.type) {
    case "tabContext": {
      const c = m.context;
      const bits = [`tab=${c.tabId}`, `url=${c.url}`, `blocked=${c.blocked}`];
      if (c.page) bits.push(`text=${c.page.visibleText.length}`, `math=${c.page.math.length}`);
      if (c.youtube) bits.push(`status=${c.youtube.transcriptStatus}`, `segments=${c.youtube.transcript.length}`, `playhead=${c.youtube.playheadSeconds}`, `video=${c.youtube.videoId}`);
      if (c.classroom) bits.push(`attachments=${c.classroom.attachments.length}`);
      if (c.drive) bits.push(`driveFile=${c.drive.file.fileId}`);
      return `tabContext ${bits.join(" ")}`;
    }
    case "tabActivated": return `tabActivated tab=${m.tabId} window=${m.windowId} url=${m.url} title=${JSON.stringify(m.title)}`;
    case "youtubePlayhead": return `youtubePlayhead tab=${m.tabId} video=${m.videoId} t=${m.playheadSeconds} chapter=${JSON.stringify(m.chapter ?? null)}`;
    case "tabClosed": return `tabClosed tab=${m.tabId}`;
    case "progress": return `progress id=${m.id} ${m.step}`;
    case "response": return `response id=${m.id} ok=${m.ok}${m.error ? ` error=${m.error.code}: ${m.error.message}` : ""}`;
    default: return m.type;
  }
}

function decodeFrame(buf) {
  const n = buf.readUInt32BE(0);
  return { header: JSON.parse(buf.subarray(4, 4 + n).toString("utf8")), payload: buf.subarray(4 + n) };
}

/** @param {{ port?: number, token?: string, blocklist?: { bundleIDs: string[], domains: string[] }, appVersion?: string, log?: (line: string) => void }} [options] */
export async function startDevBridge({ port = 47823, token, blocklist, appVersion = "dev", log = console.log } = {}) {
  let config = blocklist ?? { bundleIDs: [], domains: [...STARTER_BLOCKED_DOMAINS] };
  let client = null;
  let nextId = 1;
  const pending = new Map();
  const wss = new WebSocketServer({ host: "127.0.0.1", port });
  await new Promise((resolve, reject) => {
    wss.once("listening", resolve);
    wss.once("error", reject);
  });
  const sendJson = (ws, obj) => ws.send(JSON.stringify(obj));

  wss.on("connection", (ws) => {
    let authed = false;
    let ping = null;
    const helloTimer = setTimeout(() => ws.close(4001, "no hello"), HELLO_TIMEOUT_MS);
    ws.on("message", (data, isBinary) => {
      if (isBinary) {
        const { header, payload } = decodeFrame(data);
        const p = pending.get(header.id);
        if (p) p.chunks[header.seq] = Buffer.from(payload);
        log(`binary id=${header.id} seq=${header.seq} last=${header.last} bytes=${payload.length}`);
        return;
      }
      let m;
      try {
        m = JSON.parse(data.toString("utf8"));
      } catch {
        log("malformed frame");
        return;
      }
      if (!authed) {
        clearTimeout(helloTimer);
        if (m.v !== 1) return ws.close(4002, "version");
        if (m.type !== "hello" || m.token !== token) return ws.close(4001, "unauthorized");
        authed = true;
        client = ws;
        log(`hello browser=${m.browserName} extension=${m.extensionVersion}`);
        sendJson(ws, { v: 1, type: "helloAck", appVersion });
        sendJson(ws, { v: 1, type: "config", blocklist: config });
        ping = setInterval(() => sendJson(ws, { v: 1, type: "ping" }), PING_MS);
        return;
      }
      log(summarize(m));
      if (m.type === "response") {
        const p = pending.get(m.id);
        if (!p) return;
        pending.delete(m.id);
        clearTimeout(p.timer);
        p.resolve({ response: m, bytes: p.chunks.length > 0 ? Buffer.concat(p.chunks) : null });
      }
    });
    ws.on("close", (code) => {
      clearTimeout(helloTimer);
      clearInterval(ping);
      log(`closed code=${code}`);
      if (client !== ws) return;
      client = null;
      for (const [id, p] of pending) {
        pending.delete(id);
        clearTimeout(p.timer);
        p.reject(new Error("extension disconnected"));
      }
    });
  });

  return {
    port: wss.address().port,
    connected: () => client !== null,
    request(method, params) {
      if (!client) return Promise.reject(new Error("no extension connected"));
      const id = `r-${nextId++}`;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(new Error(`${method} timed out`));
        }, REQUEST_TIMEOUT_MS);
        pending.set(id, { resolve, reject, timer, chunks: [] });
        sendJson(client, { v: 1, type: "request", id, method, params });
      });
    },
    sendConfig(domains) {
      config = { ...config, domains };
      if (client) sendJson(client, { v: 1, type: "config", blocklist: config });
    },
    kick(code) {
      client?.close(code);
    },
    close() {
      for (const ws of wss.clients) ws.terminate();
      return new Promise((resolve) => wss.close(() => resolve()));
    },
  };
}
