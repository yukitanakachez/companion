#!/usr/bin/env node
// Usage: COMPANION_TOKEN=<64 hex> npm run dev-bridge. Reads commands from stdin; see HELP.
import { randomBytes } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { createInterface } from "node:readline";
import { startDevBridge } from "./dev-bridge-lib.mjs";

const HELP = `commands:
  getTabContext [tabId]
  fetchDrivePdf <fileId>
  viewerInfo <tabId>
  capture <tabId> <pageIndex>
  restore <tabId> <pageIndex>
  config <d1,d2,...>
  kick <code>`;

const token = process.env.COMPANION_TOKEN ?? randomBytes(32).toString("hex");
if (!process.env.COMPANION_TOKEN) console.log(`pairing token: ${token}`);
const bridge = await startDevBridge({ token });
console.log(`dev bridge on ws://127.0.0.1:${bridge.port}\n${HELP}`);

const safe = (s) => s.replace(/[^A-Za-z0-9_-]/g, "_");
const show = ({ response }) => console.log(JSON.stringify(response.ok ? response.result : response.error));

async function run(cmd, args) {
  switch (cmd) {
    case "getTabContext":
      return show(await bridge.request("getTabContext", { tabId: args[0] ? Number(args[0]) : null }));
    case "fetchDrivePdf": {
      const out = await bridge.request("fetchDrivePdf", { fileId: args[0] });
      show(out);
      if (!out.bytes) return;
      const path = `/tmp/companion-${safe(args[0])}.pdf`;
      await writeFile(path, out.bytes);
      return console.log(`${path}: ${out.bytes.length} bytes, starts with %PDF-: ${out.bytes.subarray(0, 5).toString() === "%PDF-"}`);
    }
    case "viewerInfo":
      return show(await bridge.request("viewerInfo", { tabId: Number(args[0]) }));
    case "capture": {
      const pageIndex = Number(args[1]);
      const { response } = await bridge.request("viewerCapturePage", { tabId: Number(args[0]), pageIndex });
      if (!response.ok) return console.log(JSON.stringify(response.error));
      const path = `/tmp/companion-page-${pageIndex}.png`;
      await writeFile(path, Buffer.from(response.result.pngBase64, "base64"));
      return console.log(`wrote ${path}`);
    }
    case "restore":
      return show(await bridge.request("viewerRestore", { tabId: Number(args[0]), pageIndex: Number(args[1]) }));
    case "config":
      return bridge.sendConfig((args[0] ?? "").split(",").filter(Boolean));
    case "kick":
      return bridge.kick(Number(args[0]));
    default:
      return console.log(HELP);
  }
}

createInterface({ input: process.stdin }).on("line", (line) => {
  const [cmd, ...args] = line.trim().split(/\s+/);
  if (cmd) run(cmd, args).catch((e) => console.log(`error: ${e.message}`));
});
