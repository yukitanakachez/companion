# WS3 — Chromium Extension ("Companion Bridge") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read `2026-11-01-companion-00-overview.md`, the spec, and WS0 Task 4 (wire format and every fixture) before starting.

**Goal:** A Manifest V3 extension that keeps the active tab's context ready in memory and pushes it to the Companion app over the token-authenticated localhost WebSocket. The context covers YouTube (transcript, playhead, chapter), page text plus exact LaTeX, Classroom attachments, and the Drive viewer's file. The extension also answers the app's slow-path requests: fresh tab context, Drive PDF download and viewer page capture.

**Architecture:** The service worker owns five pieces:
- `BridgeClient`: ports, hello, backoff and close codes.
- `BlocklistStore`: the persisted config, with the starter list as fallback.
- `TabStore`: the latest `TabContext` per tab, merged from per-script *parts*.
- `TabTracker`: tab activation, focus, URL/title changes and tab close.
- A request router.

Content scripts are thin entries over pure functions that take `doc`/`win` explicitly, so tests run against `JSDOM`. Each content script asks the worker "is my host blocked?" before reading anything. Wire types come only from `contracts/ts/protocol.ts`. Extension-internal message types live in `src/shared/messages.ts`.

**Tech Stack:** TypeScript 5 (strict), esbuild, vitest, jsdom, @types/chrome, `ws` (dev bridge only), Node 24 / npm 11. The test browser is Dia (Chromium); it loads unpacked extensions in Developer mode.

**Spec:** `docs/superpowers/specs/2026-11-01-screen-companion-design.md` (§5.3, §5.5, §5.6). Wire contract: WS0 plan Task 4 and `contracts/`.

## Global Constraints

All of the overview's Global Constraints apply. WS0 must be merged first (tag `contracts-v1`). Work on branch `ws/ws3-extension`, created with `scripts/new-workstream.sh ws3-extension`.

**Paths and types**
- Edit only `extension/`; `contracts/` is read-only.
- Import types, `PROTOCOL_VERSION`, `PORTS`, `MAX_CHUNK_BYTES`, `PING_INTERVAL_MS`, `CLOSE_UNAUTHORIZED`, `CLOSE_VERSION_MISMATCH`, `HELLO_TIMEOUT_MS` and `STARTER_BLOCKED_DOMAINS` from `../contracts/ts/protocol.ts`. Never redeclare a type it exports.
- This plan uses the Swift contract names: `ExtensionToApp`, `AppToExtension`, `TabContext`, `YouTubeContext`, `TranscriptSegment`, `MathSnippet`, `WebPageContext`, `DriveFileRef`, `ClassroomContext`, `DriveViewerContext`, `BlocklistConfig`, `BridgeErrorCode`, `BinaryFrameHeader`, `DrivePdfResult`, `ViewerInfo`, `ViewerPageResult`.
- Select variants with `Extract<…, { type: "…" }>` and fields by indexed access, e.g. `YouTubeContext["transcriptStatus"]`.
- If protocol.ts spells a name differently, use its spelling. If a name is missing, stop and ask (overview rule 2).

**Toolchain**
- `package.json`: `"type": "module"`, `"engines": {"node": ">=24"}`.
- devDependencies only: `typescript@^5`, `esbuild`, `vitest`, `jsdom`, `@types/chrome`, `@types/node`, `ws`. Commit `package-lock.json`.
- Scripts, exactly: `"test": "tsc --noEmit && vitest run"`, `"build": "node tools/build.mjs"`, `"dev-bridge": "node tools/dev-bridge.mjs"`.
- The worker bundles as ESM. Content scripts and options bundle as IIFE, with no `import`/`export` in the output. Target `chrome116`; output to `extension/dist/` (gitignored).

**Bridge**
- Connect to `ws://127.0.0.1:<port>`, trying ports 47823, 47824, 47825, 47826 and 47827 in that order.
- `hello` must be the first frame, and `helloAck` must arrive within 5,000 ms.
- Close **4001** sets `tokenRejected`; close **4002** sets `versionMismatch`. After either, don't retry until the token changes or the user clicks "Test connection".
- The app sends `ping` every 20 s; no reply is needed.
- Backoff is 500 ms, 1,000 ms, 2,000 ms, then every 5,000 ms. It resets after `helloAck`.

**Storage** (`chrome.storage.local`)
- `"pairingToken"`: 64 lowercase hex chars.
- `"blocklist"`: the last `config`'s `BlocklistConfig`.
- `"bridgeStatus"`: an `ExtensionBridgeStatus`.

**Blocklist**
- A host is blocked when `host === d || host.endsWith("." + d)`, using the lowercased hostname with any trailing dot stripped.
- Until a `config` is stored, use WS0's starter domains: `1password.com`, `bitwarden.com`, `lastpass.com`, `dashlane.com`, `chase.com`, `bankofamerica.com`, `wellsfargo.com`, `citi.com`, `capitalone.com`, `usbank.com`, `pnc.com`, `schwab.com`, `fidelity.com`, `paypal.com`, `venmo.com`, `discord.com`, `web.whatsapp.com`, `messages.google.com`.
- Nothing reads a blocked tab's DOM. For a blocked tab, the worker sends only `{tabId, url, title: "", capturedAtMs, blocked: true}` (as in `ext-tabContext-blocked.json`). Its `tabActivated` gets `title: ""` as well.

**Caps and timings**
- `visibleText` is at most 20,000 chars after collapsing whitespace. Math is at most 50 snippets.
- Scroll debounce: 1,000 ms. Classroom re-parse debounce: 500 ms.
- YouTube playhead: every 5,000 ms while playing, and once on `seeked`.
- `getTabContext` waits 250 ms for an extract-now. A content script's `isBlocked` call waits 1,000 ms, then fails closed (treated as blocked).
- Transcript panel wait: 5,000 ms. MAIN-world player data: retry every 500 ms, up to 5,000 ms.
- `captureVisibleTab` calls must be ≥ 500 ms apart.

**PDF transfer**
- Frame layout: a 4-byte big-endian header length N, then N bytes of UTF-8 JSON `{id, seq, last}`, then a payload of at most 1,048,576 bytes.
- `seq` starts at 0, and `last: true` appears only on the final frame.
- The JSON `response` `{fileId, title, byteLength}` follows the last frame.
- The file must start with `%PDF-`.

**Runtime rules**
- Register every `chrome.*` listener synchronously at worker start, before any `await`.
- Content modules use the DOM only via `deps.doc`/`deps.win`, and use global timers so `vi.useFakeTimers()` controls them.
- jsdom has no `innerText` or `scrollIntoView`. Code must handle the missing `innerText`; tests stub `scrollIntoView`.
- Network access is limited to the bridge socket, the YouTube caption `baseUrl` (same origin as the page) and Drive download URLs.

## Review Focus

1. **YouTube transcript missing or wrong.**
   - *Triggers:* the caption `json3` fetch returns 200 with an empty body (common now), the fetch fails, or the user switches videos mid-load.
   - *Expected:* fall back to the transcript panel; never stay stuck at `loading`; never attach video A's transcript to video B.
   - *Pinned:* Task 7 "empty json3 body falls back to the transcript panel" and "panel never renders → unavailable"; Task 8 "stale ytInitialPlayerResponse is ignored" and "late transcript for the previous video is discarded".
2. **Worker asleep or restarted.**
   - *Trigger:* a message wakes a worker that has no socket, an empty store and no blocklist loaded.
   - *Expected:* `isBlocked` waits for the stored blocklist; only one socket opens; after `helloAck` and `config`, the worker re-announces the active tab and asks it to re-extract.
   - *Pinned:* Task 3 "start() twice while connecting opens one socket"; Task 4 "answers wait for the stored blocklist"; Task 11 "resyncs after helloAck and config".
3. **Classroom attachments render late, twice, or change.**
   - *Expected:* a later `classroom` part with deduped attachments; nothing resent when an identical list re-renders; nothing carried over to another assignment.
   - *Pinned:* Task 9 "attachments rendered late are sent once", "duplicate anchors give one ref" and "SPA nav to another assignment starts fresh".
4. **A blocked host is never read.**
   - *Triggers:* the worker doesn't answer; a new `config` blocks a site that is already cached; the app asks for a blocked tab; an allowed iframe sits inside a blocked tab.
   - *Expected:* scripts fail closed; cached snapshots become `blocked: true`; the tab is never asked to extract; parts from a blocked tab are dropped.
   - *Pinned:* Task 4 "askBlocked fails closed"; Task 5 "blocked tab activation has an empty title"; Task 11 "new config purges cached snapshots", "blocked tab is never asked to extract" and "parts from a blocked tab are dropped".
5. **3-hour lecture (~4,000 caption events).**
   - *Expected:* parsed once and sent once per video; playhead ticks never resend it.
   - *Pinned:* Task 7 "parses a 3-hour json3 transcript"; Task 8 "10 minutes of playback: 120 playheads, no context parts".

---

### Task 1: Scaffold, manifest and build

**Files:**
- Create: `extension/package.json`, `package-lock.json`, `tsconfig.json`, `vitest.config.ts`, `manifest.json`, `tools/build.mjs`, and a placeholder `src/options/options.html`.
- Create entry stubs containing only `export {};` (later tasks replace them): `src/background/index.ts`, `src/content/page-entry.ts`, `src/content/youtube/entry.ts`, `src/content/youtube/main-world.ts`, `src/content/classroom-entry.ts`, `src/content/drive-entry.ts`, `src/options/options-entry.ts`.
- Test: `test/manifest.test.ts`, `test/build.test.ts`.

**Interfaces:**
- Produces: `build(outdir = "dist"): Promise<void>` in `tools/build.mjs`, which also runs as a CLI. It emits 9 files: `background.js`, `content-page.js`, `content-youtube.js`, `content-youtube-main.js`, `content-classroom.js`, `content-drive.js` and `options.js`, plus copies of `manifest.json` and `options.html`.

- [ ] **Step 1: Write the configs and the manifest.**
  - `tsconfig.json`: `strict`, `noEmit`, `target: ES2022`, `module: ESNext`, `moduleResolution: Bundler`, `lib: ["ES2022","DOM","DOM.Iterable"]`, `types: ["chrome","node"]`, `allowJs` (tests import `tools/*.mjs`), `skipLibCheck`, `isolatedModules`, `include: ["src","test","vitest.config.ts"]`.
  - `vitest.config.ts`: `include: ["test/**/*.test.ts"]`, `environment: "node"`.
  - `manifest.json`, exactly:

```json
{
  "manifest_version": 3,
  "name": "Companion Bridge",
  "version": "0.1.0",
  "minimum_chrome_version": "116",
  "background": { "service_worker": "background.js", "type": "module" },
  "permissions": ["tabs", "storage", "scripting"],
  "host_permissions": ["<all_urls>"],
  "options_page": "options.html",
  "content_scripts": [
    { "matches": ["<all_urls>"], "exclude_matches": ["https://www.youtube.com/*", "https://drive.google.com/*"],
      "js": ["content-page.js"], "run_at": "document_idle" },
    { "matches": ["https://www.youtube.com/*"], "js": ["content-youtube.js"], "run_at": "document_idle" },
    { "matches": ["https://www.youtube.com/*"], "js": ["content-youtube-main.js"], "run_at": "document_idle", "world": "MAIN" },
    { "matches": ["https://classroom.google.com/*"], "js": ["content-classroom.js"], "run_at": "document_idle" },
    { "matches": ["https://drive.google.com/*"], "js": ["content-drive.js"], "run_at": "document_idle", "all_frames": true }
  ]
}
```

The generic extractor skips YouTube, so scrolling comments never resends the transcript, and Drive, whose UI text is noise. Classroom gets both a `page` and a `classroom` part, as in `ext-tabContext-classroom.json`.

- [ ] **Step 2: Write the failing tests**

```ts
// manifest.test.ts — m = JSON.parse(readFileSync("manifest.json"))
it("declares MV3 basics", () => {
  expect(m.manifest_version).toBe(3); expect(m.name).toBe("Companion Bridge");
  expect(m.background).toEqual({ service_worker: "background.js", type: "module" });
  expect([...m.permissions].sort()).toEqual(["scripting", "storage", "tabs"]);
  expect(m.host_permissions).toEqual(["<all_urls>"]); expect(m.options_page).toBe("options.html"); });
it("youtube has an isolated and a MAIN-world script", ...)   // the "MAIN" entry's js == ["content-youtube-main.js"]
it("drive script runs in all frames", ...)
it("generic extractor excludes youtube and drive", ...)
// build.test.ts — await build(tmpDir)
it("emits every file the manifest references", ...)          // all 9 output files exist
it("content scripts are classic scripts", ...)               // content-*.js and options.js contain no /^(import|export)\b/m
```

- [ ] **Step 3: Run** `cd extension && npm install && npx vitest run`. Expected: FAIL, because `tools/build.mjs` is missing.
- [ ] **Step 4: Implement `build(outdir)`:** one esbuild call for the ESM worker, one for the IIFE bundles, then copy `manifest.json` and `src/options/options.html` into `outdir`.
- [ ] **Step 5: Run** `npm test && npm run build`. Expected: PASS, and `dist/` contains all 9 files.
- [ ] **Step 6: Commit** — `git add extension && git commit -m "chore(extension): scaffold, manifest, esbuild build"`

---

### Task 2: Protocol codec, internal messages, binary frames

**Files:**
- Create: `src/shared/protocol-codec.ts`, `src/shared/binary-frame.ts`, `src/shared/messages.ts`, `test/helpers/fixtures.ts`.
- Test: `test/protocol-codec.test.ts`, `test/binary-frame.test.ts`.

**Interfaces:**
- Produces:

```ts
// protocol-codec.ts
export type BridgeRequestMessage = Extract<AppToExtension, { type: "request" }>;
export class ProtocolError extends Error { constructor(readonly code: "versionMismatch" | "malformed", message: string) }
export class RequestError extends Error { constructor(readonly code: BridgeErrorCode, message: string) }
export function isExtensionToApp(x: unknown): x is ExtensionToApp;   // deep check, including TabContext fields
export function isAppToExtension(x: unknown): x is AppToExtension;   // v === 1, known type, request method + params
export function parseAppMessage(text: string): AppToExtension;        // throws ProtocolError
export function encodeMessage(msg: ExtensionToApp): string;           // JSON.stringify({ ...msg, v: PROTOCOL_VERSION })
export function okResponse(id: string, result: unknown): ExtensionToApp;
export function errorResponse(id: string, code: BridgeErrorCode, message: string): ExtensionToApp;
// binary-frame.ts
export function encodeBinaryFrame(header: BinaryFrameHeader, payload: Uint8Array): Uint8Array; // RangeError if payload > MAX_CHUNK_BYTES
export function decodeBinaryFrame(frame: Uint8Array): { header: BinaryFrameHeader; payload: Uint8Array };
// messages.ts (extension-internal, not wire types)
export type ContextPart = { page?: WebPageContext | null; youtube?: YouTubeContext | null;
                            classroom?: ClassroomContext | null; drive?: DriveViewerContext | null };   // null clears that field
export type ContentToBackground =
  | { kind: "isBlocked"; url: string }                                                   // reply: { blocked: boolean }
  | { kind: "contextPart"; pageUrl: string; pageTitle: string; capturedAtMs: number; part: ContextPart }
  | { kind: "playhead"; videoId: string; playheadSeconds: number; chapter: string | null }
  | { kind: "reconnectNow" };
export type BackgroundToContent = { kind: "extractNow" }
  | { kind: "viewer"; op: "info" } | { kind: "viewer"; op: "scrollTo"; index: number };
export type BridgeState = "noToken" | "connecting" | "connected" | "disconnected" | "tokenRejected" | "versionMismatch";
export interface ExtensionBridgeStatus { state: BridgeState; port: number | null; appVersion: string | null; updatedAtMs: number }
export const STORAGE_KEYS = { pairingToken: "pairingToken", blocklist: "blocklist", bridgeStatus: "bridgeStatus" } as const;
// test/helpers/fixtures.ts (reads new URL("../../contracts/fixtures/", import.meta.url))
export function contractFixtureNames(): string[]; export function contractFixture(name: string): any;
export function contractFixtureText(name: string): string;
```

- [ ] **Step 1: Write the failing tests**

```ts
it("checks all 24 fixtures", () => expect(contractFixtureNames()).toHaveLength(24));
it.each(extNames)("%s is ExtensionToApp and not AppToExtension", n => {
  expect(isExtensionToApp(contractFixture(n))).toBe(true); expect(isAppToExtension(contractFixture(n))).toBe(false); });
it.each(appNames)("%s is AppToExtension and parses", n => {
  expect(isAppToExtension(contractFixture(n))).toBe(true); expect(parseAppMessage(contractFixtureText(n))).toEqual(contractFixture(n)); });
it("rejects invalid-version", () => {
  expect(isAppToExtension(contractFixture("invalid-version.json"))).toBe(false);
  expect(() => parseAppMessage(contractFixtureText("invalid-version.json"))).toThrow(expect.objectContaining({ code: "versionMismatch" })); });
it("rejects malformed shapes", ...)   // blocked:"no"; method "deleteAll"; config without domains; error.code "nope"; "not json" → "malformed"
it("builders reproduce fixtures", () => {
  expect(JSON.parse(encodeMessage(okResponse("r-1", { context: null })))).toEqual(contractFixture("ext-response-tabContext.json"));
  expect(JSON.parse(encodeMessage(errorResponse("r-3", "downloadBlocked", "The owner has disabled downloads for this file."))))
    .toEqual(contractFixture("ext-response-downloadBlocked.json")); });
// binary-frame.test.ts
it("round-trips with a 4-byte big-endian header length", ...)  // {id:"r-2",seq:0,last:true}, payload "%PDF"; getUint32(0) === frame.length - 4 - 4
it("accepts exactly MAX_CHUNK_BYTES and rejects one byte more", ...)
it("decode rejects a truncated frame", ...)
```

- [ ] **Step 2: Run** `npx vitest run test/protocol-codec.test.ts test/binary-frame.test.ts`. Expected: FAIL (modules missing).
- [ ] **Step 3: Implement** the three source files and the helper. Write the guards as hand-written predicates — no schema library.
- [ ] **Step 4: Run** `npm test`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(extension): protocol guards, codec, binary frames"`

---

### Task 3: Bridge client

**Files:**
- Create: `src/background/bridge-client.ts`, `test/helpers/fake-websocket.ts`.
- Test: `test/bridge-client.test.ts`.

**Interfaces:**
- Consumes: Task 2's `parseAppMessage`, `encodeMessage` and `ExtensionBridgeStatus`.
- Produces:

```ts
export interface WebSocketLike { readonly readyState: number; readonly bufferedAmount: number; binaryType: string;
  onopen: (() => void) | null; onmessage: ((ev: { data: unknown }) => void) | null;
  onclose: ((ev: { code: number }) => void) | null; onerror: (() => void) | null;
  send(data: string | Uint8Array): void; close(code?: number): void }
export type SocketFactory = (url: string) => WebSocketLike;
export const BACKOFF_MS = [500, 1000, 2000, 5000] as const;
// CLOSE_UNAUTHORIZED, CLOSE_VERSION_MISMATCH and HELLO_TIMEOUT_MS are imported from contracts/ts/protocol.ts — do not redeclare.
export const HELLO_ACK_TIMEOUT_MS = 5000;   // how long the client waits for helloAck before reconnecting
export function backoffDelay(failedRounds: number): number;   // 1→500, 2→1000, 3→2000, ≥4→5000
export function detectBrowserName(brands: { brand: string }[] | undefined): string; // first brand not /Chromium|Not.?A.?Brand/i, else "Chromium"
export interface BridgeClientDeps {
  createSocket: SocketFactory; getToken(): Promise<string | null>;
  extensionVersion: string; browserName: string; ports?: readonly number[];   // ports defaults to PORTS
  onAppMessage(msg: AppToExtension): void;          // receives config and request; helloAck and ping are handled internally
  onConnected(port: number, appVersion: string): void; onDisconnected(): void; onStatus(s: ExtensionBridgeStatus): void }
export class BridgeClient {
  constructor(deps: BridgeClientDeps);
  start(): Promise<void>;     // idempotent; does nothing while connecting, connected or rejected
  restart(): Promise<void>;   // closes, clears the rejected state and the backoff, then starts
  send(msg: ExtensionToApp): boolean;            // returns false (and drops the message) unless connected
  sendBinary(frame: Uint8Array): Promise<void>;  // waits while bufferedAmount > 8 * MAX_CHUNK_BYTES
  get connected(): boolean }
```

`FakeWebSocket` (test helper) keeps a static `instances` list; each instance has `url` and `sent: (string | Uint8Array)[]`. Tests drive it with `serverOpen()`, `serverSend(obj)`, `serverClose(code)` and `fail()`. `fail()` closes with code 1006 before the socket opens.

- [ ] **Step 1: Write the failing tests.** Use `vi.useFakeTimers()`. `getToken` resolves to a 64-hex-character `TOKEN`.

```ts
it("tries 47823 first and sends hello as the first frame", ...)
  // instances[0].url === "ws://127.0.0.1:47823"; after serverOpen(): JSON.parse(sent[0]) toEqual
  // { v: 1, type: "hello", token: TOKEN, extensionVersion: "0.1.0", browserName: "Dia" }, and it passes isExtensionToApp
it("falls through the ports in order", ...)                       // fail() twice → the third url ends in ":47825"
it("retries a failed round after 500, 1000, 2000, 5000, 5000 ms", ...) // no new socket at 499 ms; one at 500 ms; …
it("helloAck → connected status with port and app version; backoff resets", ...)
it("routes config and request to onAppMessage; ignores ping, malformed and v:2 frames", ...)
it("close 4001 → tokenRejected, no retry for 60 s; restart() reconnects", ...)
it("close 4002 → versionMismatch, no retry", ...)
it("no token → noToken status and no socket", ...)
it("start() twice while connecting opens one socket", ...)        // Review Focus 2
it("a dropped connection calls onDisconnected and retries from 47823 after 500 ms", ...)
it("no helloAck within 5,000 ms closes the socket and tries the next port", ...)
it("send() returns false and sends nothing while disconnected", ...)
it("sendBinary waits while bufferedAmount exceeds 8 MiB", ...)
it("detectBrowserName", ...)  // [Not)A;Brand, Chromium, Dia] → "Dia"; [Chromium] → "Chromium"; undefined → "Chromium"
```

- [ ] **Step 2: Run** `npx vitest run test/bridge-client.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement `BridgeClient`.** It is a state machine with states `idle`, `connecting`, `connected` and `rejected`. One *round* tries every port. A port fails if its socket closes before `helloAck` (with any code except 4001 or 4002), or if the ack timer fires. Set `binaryType = "arraybuffer"`.
- [ ] **Step 4: Run** `npm test`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(extension): bridge client with port fallback and backoff"`

---

### Task 4: Blocklist and the content guard

**Files:**
- Create: `src/shared/blocklist.ts`, `src/shared/guard.ts`, `src/background/blocklist-store.ts`, `test/helpers/chrome-mock.ts`.
- Test: `test/blocklist.test.ts`, `test/guard.test.ts`.

**Interfaces:**
- Produces:

```ts
// shared/blocklist.ts
export { STARTER_BLOCKED_DOMAINS } from "../../../contracts/ts/protocol";   // re-exported from the frozen contract (18 domains) — never copied
export function hostOf(url: string): string | null;           // lowercased, trailing dot removed; null unless http(s)
export function isHostBlocked(host: string, domains: readonly string[]): boolean;
// shared/guard.ts
export const ASK_BLOCKED_TIMEOUT_MS = 1000;
export function askBlocked(url: string, sendMessage?: (m: ContentToBackground) => Promise<unknown>): Promise<boolean>; // fails closed
// background/blocklist-store.ts
export class BlocklistStore {
  constructor(storage: chrome.storage.StorageArea);
  domains(): Promise<readonly string[]>;        // waits for the one-time load of "blocklist"; the starter list if nothing is stored
  isUrlBlocked(url: string): Promise<boolean>;  // false when hostOf(url) is null
  setConfig(config: BlocklistConfig): Promise<void> }   // replaces the list in memory and persists it to "blocklist"
// test/helpers/chrome-mock.ts
export function createChromeMock(init?: { tabs?: Partial<chrome.tabs.Tab>[]; focusedWindowId?: number;
  storage?: Record<string, unknown>; storageGetDelayMs?: number }): ChromeMock;
```

`ChromeMock` covers only the `chrome` APIs this extension uses:
- `storage.local`: `get`, `set`, `onChanged`
- `runtime`: `getManifest`, `sendMessage`, `onMessage`, `onInstalled`
- `tabs`: `get`, `query`, `sendMessage`, `captureVisibleTab`, `onActivated`, `onUpdated`, `onRemoved`
- `windows`: `WINDOW_ID_NONE` (−1), `getLastFocused`, `onFocusChanged`
- `scripting`: `executeScript`

Every event has `addListener`, `hasListeners` and `fire(...)`, and every call is a `vi.fn()`. `deliver(msg, sender)` runs the `runtime.onMessage` listeners and resolves with the value passed to `sendResponse`. This includes listeners that `return true` and answer asynchronously.

- [ ] **Step 1: Write the failing tests**

```ts
it("matches the host or a dot-suffix only", () => {
  const d = ["chase.com", "web.whatsapp.com"];
  expect(isHostBlocked("secure.chase.com", d)).toBe(true); expect(isHostBlocked("CHASE.COM.", d)).toBe(true);
  expect(isHostBlocked("notchase.com", d)).toBe(false); expect(isHostBlocked("chase.com.evil.io", d)).toBe(false);
  expect(isHostBlocked("whatsapp.com", d)).toBe(false); });
it("hostOf", ...)  // "https://Secure.Chase.com/x" → "secure.chase.com"; "chrome://extensions" and "file:///a" → null
it("starter list is WS0's 18 domains", ...)
it("uses the starter domains until a config is stored", ...)     // chase.com is blocked; example.org is not
it("answers wait for the stored blocklist", async () => {        // Review Focus 2
  const c = createChromeMock({ storage: { blocklist: { bundleIDs: [], domains: ["example.org"] } }, storageGetDelayMs: 50 });
  const s = new BlocklistStore(c.storage.local);
  expect(await s.isUrlBlocked("https://www.example.org/")).toBe(true);
  expect(await s.isUrlBlocked("https://chase.com/")).toBe(false); });   // a stored config replaces the starter list
it("setConfig persists and a new store instance reads it", ...)   // simulates a worker restart
it("askBlocked fails closed", ...)                               // Review Focus 4
  // rejects → true; resolves undefined → true; { blocked: false } → false; never resolves → true at 1,000 ms
```

- [ ] **Step 2: Run** `npx vitest run test/blocklist.test.ts test/guard.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement** the four files.
- [ ] **Step 4: Run** `npm test`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(extension): blocklist store, matching, fail-closed content guard"`

---

### Task 5: Tab store and tab tracker

**Files:**
- Create: `src/background/tab-store.ts`, `src/background/tab-tracker.ts`.
- Test: `test/tab-store.test.ts`, `test/tab-tracker.test.ts`.

**Interfaces:**
- Consumes: `ContextPart` (Task 2); `BlocklistStore` and `createChromeMock` (Task 4).
- Produces:

```ts
export class TabStore {
  applyPart(tabId: number, url: string, title: string, capturedAtMs: number, part: ContextPart): TabContext; // a new URL (ignoring #fragment) starts fresh
  setBlocked(tabId: number, url: string, capturedAtMs: number): TabContext;  // { tabId, url, title: "", capturedAtMs, blocked: true }
  updatePlayhead(tabId: number, videoId: string, playheadSeconds: number, chapter: string | null): void; // only if youtube.videoId matches
  get(tabId: number): TabContext | undefined; delete(tabId: number): void; all(): TabContext[];
  dropIfUrlChanged(tabId: number, url: string): void;
  purge(isBlocked: (url: string) => boolean, nowMs: number): TabContext[];   // replaces matching contexts with blocked ones and returns them
  waitFor(tabId: number, timeoutMs: number): Promise<TabContext | null> }    // resolves on that tab's next applyPart, or null on timeout
export class TabTracker {
  constructor(deps: { chrome: Pick<typeof chrome, "tabs" | "windows">; store: TabStore; blocklist: BlocklistStore;
                      send(msg: ExtensionToApp): void });
  attach(): void;                             // synchronously registers onActivated, windows.onFocusChanged, onUpdated, onRemoved
  activeTabId(): number | null;
  announceActive(): Promise<number | null> }  // sends tabActivated for the focused window's active tab, even if it repeats the last one
```

- [ ] **Step 1: Write the failing tests**

```ts
it("merges page and classroom parts into the classroom fixture", () => {
  const want = contractFixture("ext-tabContext-classroom.json").context;
  s.applyPart(33, want.url, want.title, 1, { page: want.page });
  expect(s.applyPart(33, want.url, want.title, want.capturedAtMs, { classroom: want.classroom })).toEqual(want); });
it("a part for a different URL starts a fresh context", ...)
it("drive: null clears the drive field", ...)
it("updatePlayhead only touches a matching videoId", ...)
it("purge replaces snapshots of newly blocked hosts", ...)
it("waitFor resolves on the next part, or null after the timeout", ...)
it("tabs.onActivated sends tabActivated", ...)   // { type:"tabActivated", tabId:12, windowId:3, url, title }; passes isExtensionToApp
it("window focus re-announces that window's active tab; WINDOW_ID_NONE is ignored", ...)
it("URL or title change of the active tab re-announces it and drops the stale snapshot", ...)
it("identical consecutive activations are sent once", ...)
it("blocked tab activation has an empty title", ...)              // Review Focus 4
it("tab removal deletes the snapshot and sends tabClosed", ...)
```

- [ ] **Step 2: Run** `npx vitest run test/tab-store.test.ts test/tab-tracker.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement** both classes. The tracker finds a window's active tab with `tabs.query({ active: true, windowId })`.
- [ ] **Step 4: Run** `npm test`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(extension): per-tab context store and active-tab tracker"`

---

### Task 6: Generic page extractor

**Files:**
- Create: `src/content/content-deps.ts`, `navigation.ts`, `page-extract.ts` and `page.ts`. Replace `src/content/page-entry.ts`.
- Create fixtures `test/fixtures/pages/{katex,mathjax2,mathjax3,mathml,plain}.html`. Use each library's real markup:
  - KaTeX: `.katex > .katex-mathml > math > semantics > annotation`.
  - MathJax v2: `script[type="math/tex"]` plus `.MJX_Assistive_MathML > math`.
  - MathJax v3: `mjx-container > mjx-assistive-mml > math`.
- Test: `test/page-extract.test.ts`, `test/page-script.test.ts`.

**Interfaces:**
- Consumes: `askBlocked` (Task 4) and the message types (Task 2).
- Produces:

```ts
// content-deps.ts
export interface ContentDeps { doc: Document; win: Window; send(msg: ContentToBackground): void;
  askBlocked(url: string): Promise<boolean>; onExtractNow(cb: () => void): void; now(): number }
export function liveContentDeps(): ContentDeps;            // wires the real window and chrome.runtime sendMessage/onMessage
// navigation.ts
export function watchNavigation(win: Window, onChange: () => void): () => void; // <title> MutationObserver + popstate + href poll every 1,000 ms
export function debounce<A extends unknown[]>(fn: (...a: A) => void, ms: number): (...a: A) => void;
// page-extract.ts
export const VISIBLE_TEXT_CAP = 20_000, MATH_CAP = 50;
export function visibleText(doc: Document): string;   // body.innerText when it is a string; otherwise a TreeWalker that skips
                                                      // script/style/noscript/template/[hidden]. Whitespace collapsed, then capped.
export function extractMath(doc: Document): MathSnippet[];
export function extractPage(doc: Document): WebPageContext;   // url = doc.location.href, title = doc.title
// page.ts
export function startPageScript(deps: ContentDeps): () => void;
// test/helpers/fixtures.ts (added in this task)
export function domFrom(fixturePathOrHtml: string, url: string): JSDOM;
```

`extractMath` walks `annotation[encoding="application/x-tex"], script[type^="math/tex"], math` in document order:
- An x-tex annotation becomes `latex`.
- A `math/tex` script becomes `latex`, including `; mode=display`.
- A `<math>` becomes `mathml` (its outerHTML), unless it contains an x-tex annotation or sits inside `.MJX_Assistive_MathML`. Those were already captured as LaTeX.

Then trim each snippet, drop empties and exact duplicates, and cap at 50.

- [ ] **Step 1: Write the failing tests**

```ts
it("a KaTeX formula yields one latex snippet, not a MathML duplicate", () =>
  expect(extractMath(domFrom("pages/katex.html", U).window.document)).toEqual([{ format: "latex", source: "\\frac{a}{b}" }]));
it("MathJax v2 scripts yield latex, including display mode; assistive MathML is skipped", ...)
it("MathJax v3 assistive MathML yields mathml starting with <math", ...)
it("bare MathML yields mathml", ...)
it("caps math at 50 and drops duplicates", ...)          // 60 distinct KaTeX formulas → 50
it("visibleText collapses whitespace, excludes script/style, caps at 20,000", ...)
it("visibleText uses innerText when the browser provides it", ...)   // Object.defineProperty(body, "innerText", …)
it("blocked host: nothing is read or sent", ...)          // askBlocked → true; neither the doc.querySelectorAll spy nor send is called
it("pushes once on start and once 1,000 ms after the last of several scrolls", ...)
  // send is called with { kind:"contextPart", pageUrl, pageTitle, capturedAtMs, part: { page } }
it("pushes on SPA navigation (title or URL change)", ...)
it("extractNow pushes a fresh part", ...)
```

- [ ] **Step 2: Run** `npx vitest run test/page-extract.test.ts test/page-script.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement.** `startPageScript` calls `askBlocked(location.href)` before every extraction, not only the first one. `page-entry.ts` is `startPageScript(liveContentDeps())`.
- [ ] **Step 4: Run** `npm test`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(extension): generic page text and math extractor"`

---

### Task 7: YouTube transcript retrieval

**Files:**
- Create: `src/content/youtube/transcript.ts`.
- Create fixture `test/fixtures/youtube/json3-sample.json` with five events:
  - a window event with no `segs`;
  - `tStartMs` 575000 / `dDurationMs` 6200, with segs `"so now we "` and `"factor the left side"`;
  - an `aAppend` event whose only seg is `"\n"`;
  - the other two segments of `ext-tabContext-youtube.json`.
- Create fixture `test/fixtures/youtube/transcript-panel.html` with three `ytd-transcript-segment-renderer` elements. Each has a `.segment-timestamp` (`0:00`, `0:05`, `1:02:05`) and a `.segment-text`.
- Test: `test/youtube-transcript.test.ts`.

**Interfaces:**
- Produces:

```ts
export interface CaptionTrack { baseUrl: string; languageCode: string; kind?: string; name?: string } // kind "asr" = auto-generated
export type TranscriptResult = { status: YouTubeContext["transcriptStatus"]; segments: TranscriptSegment[]; source: "json3" | "panel" | "none" };
export const TRANSCRIPT_SELECTORS: { segment: string; timestamp: string; text: string; showButton: string;
                                     expandDescription: string; closePanel: string };   // the one place to change when YouTube's DOM changes
export function chooseTrack(tracks: CaptionTrack[]): CaptionTrack | null;   // manual en* > auto en* > first > null
export function parseJson3(json: unknown): TranscriptSegment[];             // ms → s; segs joined, "\n" → " ", collapsed; empties skipped; sorted
export function parseTimestamp(text: string): number | null;
export function scrapeTranscriptPanel(doc: Document): TranscriptSegment[]; // duration = next start − start; the last one is 0
export function openPanelAndScrape(doc: Document, timeoutMs?: number): Promise<TranscriptSegment[]>;   // default 5,000 ms
export function loadTranscript(track: CaptionTrack | null,
  deps: { fetch: typeof fetch; openPanelAndScrape(): Promise<TranscriptSegment[]> }): Promise<TranscriptResult>;
```

`openPanelAndScrape` scrapes immediately if segments already exist. Otherwise it:
1. clicks `showButton`, clicking `expandDescription` first if the button isn't there;
2. waits for segments with a `MutationObserver`, up to the timeout, then scrapes;
3. closes the panel with `closePanel` if it was the one that opened it.

- [ ] **Step 1: Write the failing tests**

```ts
it("chooseTrack prefers manual English over auto English over first", ...)
it("parseJson3 reproduces the contract fixture's transcript", () =>
  expect(parseJson3(json3Sample)).toEqual(contractFixture("ext-tabContext-youtube.json").context.youtube.transcript));
it("parses a 3-hour json3 transcript", ...)     // Review Focus 5: 4,000 events 2.7 s apart → 4,000 segments, last start 10797.3, < 500 ms
it("parseTimestamp", ...)                      // "1:02:05"→3725, "9:41"→581, "0:00"→0, "abc"→null
it("scrapes the transcript panel", ...)        // starts 0, 5, 3725; durations 5, 3720, 0
it("fetches baseUrl + \"&fmt=json3\"", ...)
it("empty json3 body falls back to the transcript panel", async () => {   // Review Focus 1
  const r = await loadTranscript(track, { fetch: async () => new Response("", { status: 200 }), openPanelAndScrape: async () => segs });
  expect(r).toEqual({ status: "available", segments: segs, source: "panel" }); });
it("fetch rejection or zero events also fall back to the panel", ...)
it("panel never renders → unavailable", ...)   // fake timers: openPanelAndScrape resolves [] at 5,000 ms → "unavailable", source "none"
it("no track → unavailable without fetch or panel", ...)
it("openPanelAndScrape clicks Show transcript, waits for segments, closes the panel", ...)
```

- [ ] **Step 2: Run** `npx vitest run test/youtube-transcript.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement** `transcript.ts`.
- [ ] **Step 4: Run** `npm test`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(extension): YouTube caption parsing with transcript-panel fallback"`

---

### Task 8: YouTube page script (MAIN-world bridge, playhead, navigation)

**Files:**
- Create: `src/content/youtube/player-data.ts`, `src/content/youtube/controller.ts`. Replace `main-world.ts` and `entry.ts`.
- Test: `test/youtube-player-data.test.ts`, `test/youtube-controller.test.ts`.

**Interfaces:**
- Consumes: `ContentDeps` (Task 6); `CaptionTrack`, `chooseTrack`, `loadTranscript` and `TranscriptResult` (Task 7).
- Produces:

```ts
// player-data.ts
export interface PlayerData { videoId: string; title: string; author: string; lengthSeconds: number; captionTracks: CaptionTrack[] }
export function readPlayerData(win: Window, videoId: string): PlayerData | null;
  // movie_player.getPlayerResponse() first, then window.ytInitialPlayerResponse; null unless videoDetails.videoId === videoId
export function installPlayerDataResponder(win: Window): void;   // MAIN world: answers {source:"companion-isolated", type:"playerRequest", videoId}
                                                                  // with {source:"companion-main", type:"playerData", videoId, data}
export function requestPlayerData(win: Window, videoId: string, timeoutMs?: number): Promise<PlayerData | null>; // retries every 500 ms, up to 5,000 ms
// controller.ts
export const PLAYHEAD_INTERVAL_MS = 5000;
export function videoIdFromUrl(url: string): string | null;      // /watch?v=<id> only
export function readChapter(doc: Document): string | null;       // .ytp-chapter-title-content, trimmed; null if empty
export interface YouTubeDeps extends ContentDeps {
  requestPlayerData(videoId: string): Promise<PlayerData | null>; loadTranscript(track: CaptionTrack | null): Promise<TranscriptResult> }
export class YouTubeController {
  constructor(deps: YouTubeDeps);
  start(): Promise<void>;     // guard, first onNavigate, then binds yt-navigate-finish, video events and extractNow
  onNavigate(): Promise<void>; current(): YouTubeContext | null; stop(): void }
```

Field sources:
- `title`: DOM `h1.ytd-watch-metadata`, else the player's `title`.
- `channel`: DOM `#owner ytd-channel-name a`, else the player's `author`.
- `durationSeconds`: `video.duration` if finite, else `lengthSeconds`.
- `playheadSeconds`: `currentTime` of `#movie_player video`, else of the first `video`.

`onNavigate` does the following:
1. Runs the guard.
2. Bumps a generation counter.
3. Sends a part with `transcriptStatus: "loading"` and `transcript: []`.
4. Fetches player data, then the transcript.
5. If the generation has changed since step 2, discards the result. Otherwise it sends the full part.

Navigating again to the same video, once its transcript has resolved, sends nothing. The isolated script posts to the MAIN world only after the guard allows it. The MAIN world never initiates messages.

- [ ] **Step 1: Write the failing tests.** Use a JSDOM at `https://www.youtube.com/watch?v=abc123XYZ00`, with fake timers.

```ts
it("stale ytInitialPlayerResponse is ignored", ...)   // Review Focus 1: initial response for "OLDOLDOLD00" → null; matching getPlayerResponse() → data
it("responder answers only tagged requests", ...)
it("sends loading then available parts, once per video", ...)
  // part 1: transcriptStatus "loading", transcript []; part 2: "available" with segments;
  // Object.keys(part2.youtube).sort() equals the fixture's youtube keys; a second yt-navigate-finish for the same id sends nothing
it("late transcript for the previous video is discarded", ...)   // Review Focus 1: A's loadTranscript resolves after navigating to B →
  // no part with videoId A is sent after B's loading part
it("playhead every 5 s while playing, none while paused, immediately on seeked", ...)
  // play + 15 s → 3 { kind:"playhead", videoId, playheadSeconds, chapter }; pause + 10 s → 0; seeked → 1
it("10 minutes of playback: 120 playheads, no context parts", ...)   // Review Focus 5
it("chapter from .ytp-chapter-title-content, null when empty", ...)
it("blocked host: nothing posted to the MAIN world, nothing sent", ...)
it("non-watch page sends no youtube part", ...)
it("extractNow re-sends the cached context without refetching", ...)
```

- [ ] **Step 2: Run** `npx vitest run test/youtube-player-data.test.ts test/youtube-controller.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement.** `main-world.ts` is `installPlayerDataResponder(window)`. `entry.ts` builds `YouTubeDeps` from `liveContentDeps()`, wires `requestPlayerData` and `loadTranscript` (with `fetch` and `openPanelAndScrape(document)`), and calls `start()`.
- [ ] **Step 4: Run** `npm test`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(extension): YouTube context, playhead and SPA navigation"`

---

### Task 9: Classroom attachments and Drive viewer context

**Files:**
- Create: `src/content/classroom.ts` and `src/content/drive.ts`. Replace `classroom-entry.ts` and `drive-entry.ts`.
- Create fixture `test/fixtures/classroom/assignment.html` containing:
  - `<h1>Read 5.2 and do 1-15</h1>`;
  - two attachment cards for the files in `ext-tabContext-classroom.json`, each an `<a href="https://drive.google.com/file/d/<id>/view?usp=drive_web" title="Attachment: <name>">` with a name line and a `PDF` label line;
  - a second (thumbnail) anchor to the textbook;
  - a `docs.google.com/document/d/…` link;
  - an `Image` card for `/file/d/1ImgImgImgImgImgImgImgImg00000/view` named `diagram.png`.
- Test: `test/classroom.test.ts`, `test/drive.test.ts`.

**Interfaces:**
- Consumes: `ContentDeps`, `watchNavigation` and `debounce` (Task 6).
- Produces:

```ts
export function driveFileIdFromUrl(url: string): string | null;     // /\/file\/d\/([A-Za-z0-9_-]{10,})/
export function parseAttachments(root: ParentNode): DriveFileRef[];  // deduplicated by fileId, in document order
export function parseAssignmentTitle(doc: Document): string | null;  // [role="main"] h1, then the first h1
export function startClassroomScript(deps: ContentDeps): () => void; // MutationObserver + 500 ms debounce; sends only when the result changes
export function driveViewerContext(url: string, docTitle: string): DriveViewerContext | null;
export function startDriveScript(deps: ContentDeps & { isTopFrame: boolean }): () => void; // in a subframe, sends { drive: null } on pagehide
```

Attachment fields:
- **title:** the first non-empty of `aria-label` or `title`, with a leading `Attachment: ` removed. If neither has a value, use the first text line that isn't a type label (`PDF`, `Google Docs`, `Google Slides`, `Google Sheets`, `Image`, `Video`, `Word`, `PowerPoint`).
- **mimeType:** `"application/pdf"` if the title ends in `.pdf` (any case) or the card has a `PDF` label line; otherwise `null`.

For the Drive viewer, the title is `document.title` minus a trailing ` - Google Drive`, and `mimeType` follows the same `.pdf` rule.

- [ ] **Step 1: Write the failing tests**

```ts
it("parses the assignment fixture into the contract's classroom value", () => {
  const want = contractFixture("ext-tabContext-classroom.json").context.classroom;
  const doc = domFrom("classroom/assignment.html", "https://classroom.google.com/c/MTIz/a/NDU2/details").window.document;
  expect({ assignmentTitle: parseAssignmentTitle(doc), attachments: parseAttachments(doc).filter(a => a.mimeType) }).toEqual(want); });
it("duplicate anchors give one ref; Docs links ignored; Image card → mimeType null", ...)   // Review Focus 3
it("a PDF label without .pdf in the title gives application/pdf", ...)
it("attachments rendered late are sent once", ...)   // Review Focus 3: empty main at start → part with 0; cards inserted at 2 s →
  // one part with 3 attachments 500 ms later; an identical re-render sends nothing more
it("SPA nav to another assignment starts fresh", ...)
it("driveViewerContext matches the drive fixture", () => {
  const want = contractFixture("ext-tabContext-drive.json").context;
  expect(driveViewerContext(want.url, want.title)).toEqual(want.drive); });
it("non-file Drive URLs give null", ...)              // /drive/folders/…, /drive/my-drive
it("a Drive subframe clears its part on pagehide", ...)
it("blocked host: classroom and drive scripts send nothing", ...)
```

- [ ] **Step 2: Run** `npx vitest run test/classroom.test.ts test/drive.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement.** `drive-entry.ts` passes `isTopFrame: window === window.top`.
- [ ] **Step 4: Run** `npm test`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(extension): Classroom attachments and Drive viewer context"`

---

### Task 10: Drive PDF download and chunking

**Files:**
- Create: `src/background/drive-download.ts`.
- Create fixtures in `test/fixtures/drive/`:
  - `confirm.html`: a `<form id="download-form" action="https://drive.usercontent.google.com/download" method="get">` with hidden inputs `id`, `export=download`, `confirm=t`, `uuid=abc-123`.
  - `denied.html`: a Drive error page with no form.
- Test: `test/drive-download.test.ts`.

**Interfaces:**
- Consumes: `RequestError` (Task 2).
- Produces:

```ts
export function driveDownloadUrl(fileId: string): string;   // https://drive.google.com/uc?export=download&id=<encoded id>
export function parseConfirmForm(html: string): string | null;   // regex (no DOMParser in a service worker): form action + hidden inputs → URL
export function filenameFromContentDisposition(header: string | null): string | null;  // prefers filename*=UTF-8''… over filename="…"
export function downloadDrivePdf(fileId: string,
  emit: (chunk: Uint8Array, seq: number, last: boolean) => Promise<void>,
  fetchFn?: typeof fetch, signal?: AbortSignal): Promise<DrivePdfResult>;   // throws RequestError; title falls back to fileId
```

`downloadDrivePdf` steps:
1. Fetch with `{ credentials: "include", redirect: "follow", signal }`.
2. Status 404 → `notFound`. Status 401 or 403 → `downloadBlocked`.
3. A `text/html` response goes through `parseConfirmForm`: follow the form once, or throw `downloadBlocked` if there is no form.
4. An empty body, or one that doesn't start with `%PDF-`, → `notPdf`.
5. Otherwise re-chunk the stream into exactly-`MAX_CHUNK_BYTES` pieces, holding one back so `last` is known.

Nothing is emitted before the `%PDF-` check passes.

- [ ] **Step 1: Write the failing tests**

```ts
it("2.5 MiB PDF → 3 frames, seq 0..2, last only on the final one", async () => {
  // body: ReadableStream of 300,000-byte pieces, 2,621,440 bytes total, starting "%PDF-";
  // Content-Disposition: attachment; filename*=UTF-8''Algebra%202%20Textbook.pdf
  expect(emitted.map(e => [e.chunk.length, e.seq, e.last])).toEqual([[1048576, 0, false], [1048576, 1, false], [524288, 2, true]]);
  expect(result).toEqual({ fileId: ID, title: "Algebra 2 Textbook.pdf", byteLength: 2621440 }); });
it("exactly 1 MiB → one frame with last true", ...)
it("requests the uc URL with credentials include", ...)
it("follows the large-file confirm form", ...)  // second fetch: https://drive.usercontent.google.com/download?id=…&export=download&confirm=t&uuid=abc-123
it("maps failures to error codes and emits nothing", ...)  // denied.html → downloadBlocked; 403 → downloadBlocked; 404 → notFound;
  // "PK\x03\x04…" → notPdf; empty body → notPdf
```

- [ ] **Step 2: Run** `npx vitest run test/drive-download.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement** `drive-download.ts`.
- [ ] **Step 4: Run** `npm test`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(extension): Drive PDF download with confirm interstitial and chunking"`

---

### Task 11: Service worker wiring and request handling

**Files:**
- Create: `src/background/service-worker.ts` and `src/background/requests.ts`. Replace `src/background/index.ts`.
- Test: `test/service-worker.test.ts`, `test/requests.test.ts`.

**Interfaces:**
- Consumes (from Tasks 2–5 and 10): `BridgeClient`, `BlocklistStore`, `TabStore`, `TabTracker`, `downloadDrivePdf`, the codec and the frame encoder.
- Produces:

```ts
// requests.ts
export const EXTRACT_NOW_TIMEOUT_MS = 250;
export interface ViewerHandler {              // implemented in Task 14
  info(tabId: number): Promise<ViewerInfo>;
  capturePage(requestId: string, tabId: number, pageIndex: number): Promise<ViewerPageResult>;
  restore(tabId: number, pageIndex: number): Promise<void> }
export interface RequestDeps { store: TabStore; tracker: TabTracker; blocklist: BlocklistStore; tabs: typeof chrome.tabs;
  client: Pick<BridgeClient, "send" | "sendBinary">; fetch: typeof fetch; viewer: ViewerHandler | null; now(): number }
export function handleRequest(req: BridgeRequestMessage, deps: RequestDeps): Promise<void>;   // always sends exactly one response
// service-worker.ts
export interface SwEnv { chrome: typeof chrome; createSocket: SocketFactory; fetch: typeof fetch; now(): number;
  ports?: readonly number[]; viewer?: ViewerHandler | null }
export function createServiceWorker(env: SwEnv): { client: BridgeClient; store: TabStore; tracker: TabTracker; blocklist: BlocklistStore };
// index.ts: createServiceWorker({ chrome, createSocket: u => new WebSocket(u), fetch: fetch.bind(globalThis), now: Date.now }).client.start();
```

**Wiring**

`runtime.onMessage`:
- `isBlocked` replies `{ blocked }`. If blocked, it also forwards `store.setBlocked(...)`.
- `contextPart` is dropped if the sender tab's URL is blocked. Otherwise it is merged and forwarded as `{ type: "tabContext", context }`. For frame 0, url/title come from `pageUrl`/`pageTitle`; for subframes, from `sender.tab`.
- `playhead` updates the snapshot and forwards `youtubePlayhead` with `sender.tab.id`.
- `reconnectNow` calls `client.restart()`.

Other wiring:
- A `pairingToken` change in `storage.onChanged` calls `client.restart()`.
- `onStatus` writes `bridgeStatus`.
- On `config`, call `blocklist.setConfig`, then `store.purge`, forwarding each replaced context.
- The first `config` after `helloAck` also triggers a **resync**: `tracker.announceActive()`, re-send every snapshot, then send `extractNow` to the active tab.
- `runtime.onInstalled` injects the manifest's content scripts into open matching tabs with `chrome.scripting.executeScript`, honouring `world` and `all_frames`.

**`handleRequest`**

`getTabContext`:
1. Resolve the tab as `tabId ?? tracker.activeTabId()`.
2. If its URL is blocked, answer with `setBlocked(...)` and never message the tab.
3. If a snapshot exists, answer with it.
4. Otherwise send `{ kind: "extractNow" }` (ignore rejection) and answer `{ context: await store.waitFor(tabId, 250) }`.

`fetchDrivePdf` sends each chunk via `client.sendBinary(encodeBinaryFrame({ id, seq, last }, chunk))`, then `okResponse`. A `RequestError` becomes `errorResponse(code)`.

Other cases:
- Viewer methods answer `noViewer` while `viewer` is null.
- Any other exception answers `internal`.

- [ ] **Step 1: Write the failing tests.** Use `createChromeMock`, `FakeWebSocket` and fake timers. Every JSON frame sent must pass `isExtensionToApp`.

```ts
it("registers every listener synchronously", ...)   // right after createServiceWorker(), no await: onMessage, tabs.on*, windows.onFocusChanged,
                                                    // storage.onChanged and runtime.onInstalled all report hasListeners()
it("contextPart is merged and forwarded as tabContext", ...)
it("parts from a blocked tab are dropped", ...)      // Review Focus 4: sender.tab.url https://secure.chase.com/…, frameId 3, drive part →
                                                    // nothing stored or sent
it("isBlocked answers and forwards a blocked context", ...)
it("playhead → youtubePlayhead with the sender tab id; snapshot updated", ...)
it("new config purges cached snapshots", ...)        // Review Focus 4: snapshot for example.org; config adds example.org →
                                                    // blocked context sent; storage "blocklist" set
it("resyncs after helloAck and config", ...)          // Review Focus 2: helloAck alone → no tabActivated;
                                                    // config → tabActivated(active), snapshots, extractNow to the active tab
it("getTabContext(null) returns the active tab's snapshot", ...)
it("getTabContext waits 250 ms for an extract-now part, else context null", ...)
it("blocked tab is never asked to extract", ...)      // Review Focus 4: tabs.sendMessage not called; result.context.blocked === true
it("fetchDrivePdf streams frames then the response; failures map to error codes", ...)
it("viewer requests answer noViewer without a handler", ...)
it("pairingToken change and reconnectNow restart the client", ...)
it("status changes are written to bridgeStatus", ...)
it("onInstalled injects matching content scripts into open tabs", ...)   // a youtube tab gets content-youtube.js
                                                                        // and content-youtube-main.js in the MAIN world
```

- [ ] **Step 2: Run** `npx vitest run test/service-worker.test.ts test/requests.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement** the three files.
  - `extensionVersion` is `chrome.runtime.getManifest().version`.
  - `browserName` is `detectBrowserName(navigator.userAgentData?.brands)`. Cast `navigator`, since `userAgentData` isn't in lib.dom.
  - Abort any in-flight download on `onDisconnected`.
- [ ] **Step 4: Run** `npm test && npm run build`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(extension): service worker wiring, resync, request handlers"`

---

### Task 12: Options page

**Files:**
- Create: `src/options/options.ts`. Replace `options.html` and `options-entry.ts`.
- Test: `test/options.test.ts`.

**Interfaces:**
- Consumes: `ExtensionBridgeStatus` and `STORAGE_KEYS` (Task 2), and the `reconnectNow` message.
- Produces:
  - `normalizeToken(input: string): string | null`, which trims, checks `/^[0-9a-f]{64}$/i`, and lowercases.
  - `statusText(s: ExtensionBridgeStatus): string`.
  - `initOptions(doc: Document, chromeApi: typeof chrome): Promise<void>`.
  - Page element ids: `#token` (a password input), `#save`, `#test`, `#status`, `#error`.

Status copy (exact):

| state | text |
|---|---|
| `noToken` | `Not paired — paste the token from Companion Settings.` |
| `connecting` | `Connecting…` |
| `connected` | `Connected to Companion <appVersion> on port <port>` |
| `disconnected` | `Companion app not running — retrying` |
| `tokenRejected` | `Token rejected — paste the current token from Companion Settings.` |
| `versionMismatch` | `Version mismatch — update the extension and the app.` |

An invalid token shows `Token must be 64 hex characters.`

- [ ] **Step 1: Write the failing tests**

```ts
it("normalizeToken", () => { expect(normalizeToken(" " + "A".repeat(64) + "\n")).toBe("a".repeat(64));
  expect(normalizeToken("abc")).toBeNull(); expect(normalizeToken("g".repeat(64))).toBeNull(); });
it("statusText copy for every state", ...)   // connected, port 47824, appVersion "0.1.0" → "Connected to Companion 0.1.0 on port 47824"
it("saving an invalid token shows the error and stores nothing", ...)
it("saving a valid token stores it under pairingToken", ...)
it("Test connection sends reconnectNow", ...)
it("re-renders when bridgeStatus changes", ...)
```

- [ ] **Step 2: Run** `npx vitest run test/options.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement** the options page.
- [ ] **Step 4: Run** `npm test && npm run build`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(extension): options page for pairing and status"`

---

### Task 13: Dev bridge tool and manual Dia verification

**Files:**
- Create: `tools/dev-bridge-lib.mjs`, `tools/dev-bridge.mjs`.
- Test: `test/dev-bridge.test.ts`.

**Interfaces:**
- Consumes: `BridgeClient` (Task 3, tests only); `encodeBinaryFrame` and `isAppToExtension` (Task 2).
- Produces:

```js
export async function startDevBridge({ port = 47823, token, blocklist, appVersion = "dev", log = console.log } = {})
  // → { port, request(method, params) → Promise<{ response, bytes: Buffer | null }>, sendConfig(domains), kick(code), close() }
```

Handshake behavior:
- The first message must be `hello`, within 5 s.
- A missing `hello` or a wrong token closes with 4001. A `v` other than 1 closes with 4002.
- Otherwise reply `helloAck {appVersion}` then `config {blocklist}`, and `ping` every 20 s.

Logging is one line per message; for `tabContext` it shows tabId, url, `blocked`, text length, math count, YouTube status/segments/playhead, attachment count and Drive fileId. Binary frames are reassembled by `id`, in `seq` order.

The CLI `dev-bridge.mjs` takes its token from `COMPANION_TOKEN`, or generates and prints one. It reads these stdin commands:
- `getTabContext [tabId]`
- `fetchDrivePdf <fileId>`: writes `/tmp/companion-<fileId>.pdf`, then prints its size and whether it starts with `%PDF-`.
- `viewerInfo <tabId>`
- `capture <tabId> <pageIndex>`: writes `/tmp/companion-page-<pageIndex>.png`.
- `restore <tabId> <pageIndex>`
- `config <d1,d2,…>`
- `kick <code>`

- [ ] **Step 1: Write the failing tests.** Start the bridge on `port: 0`. The client is Node 24's global `WebSocket`.

```ts
it("closes with 4001 on a wrong token", ...)
it("closes with 4002 on a v:2 hello", ...)
it("replies helloAck then config to a good hello", ...)   // both pass isAppToExtension
it("a real BridgeClient connects and reports connected", ...)   // ports: [bridge.port], createSocket: u => new WebSocket(u)
it("request('fetchDrivePdf') reassembles binary frames", ...)  // client answers with 3 encodeBinaryFrame frames plus a response →
  // bytes equal the original 2,621,440 bytes; response.result.byteLength === 2621440
```

- [ ] **Step 2: Run** `npx vitest run test/dev-bridge.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement** both tool files.
- [ ] **Step 4: Run** `npm test`. Expected: PASS.
- [ ] **Step 5: Verify manually in Dia, and report each result to the human.**
  1. **Load:** run `npm run build`. In Dia's extensions page, turn on Developer mode, choose "Load unpacked" and pick `extension/dist`. Reload any tabs that were already open.
  2. **Pair:** run `COMPANION_TOKEN=$(openssl rand -hex 32) npm run dev-bridge` and paste the token into the options page. The status reads `Connected to Companion dev on port 47823`.
  3. **YouTube with captions:**
     - The log shows `tabActivated`, then `tabContext` with `status=loading`, then `available` with N > 0 segments.
     - While the video plays, a `youtubePlayhead` arrives about every 5 s. Seeking sends one at once; pausing stops them.
     - A video without captions shows `unavailable`.
     - Clicking a recommended video shows `loading`, then `available`, for the **new** videoId.
  4. **Math pages:** https://katex.org and a math.stackexchange.com question both produce `latex` snippets.
  5. **Blocked site:** https://www.chase.com produces `blocked=true` with no page fields, and its `tabActivated` has an empty title.
  6. **Classroom:**
     - An assignment with PDF attachments produces a `classroom` part listing the fileIds.
     - Save the assignment HTML with names scrubbed as `test/fixtures/classroom/real-assignment.html`, and add a test that asserts those attachments.
  7. **Drive download:** `fetchDrivePdf <id>` writes a `/tmp` file that opens in Preview, and its size matches the size Drive shows. `getTabContext` returns the active tab's context.
  8. **Reconnect:** stop the dev bridge — the status reads `Companion app not running — retrying`. Restart it; the extension reconnects within about 5 s (switch tabs if the worker was asleep).
  9. **Worker restart:** stop the worker from Dia's service-worker internals page, then switch tabs. The log shows a reconnect followed by `tabActivated`.
  10. **Token change:** restart the bridge with a different token — the status reads `Token rejected…`. Paste the new token — the status reads `Connected…`.
- [ ] **Step 6: Commit** — `git add extension && git commit -m "feat(extension): dev bridge tool and real Classroom fixture"`

---

### Task 14: Drive viewer driver (built last; may slip to v1.1)

**Files:**
- Create: `src/content/drive-viewer.ts`, `src/background/viewer-driver.ts`.
- Modify: `src/content/drive-entry.ts` (add the viewer message handler, top frame only) and `src/background/index.ts` (pass `viewer`).
- Create the fixture `test/fixtures/drive/viewer.html`, page structure only, recorded in Step 1.
- Test: `test/drive-viewer.test.ts`, `test/viewer-driver.test.ts`.

**Interfaces:**
- Consumes: `ViewerHandler` and `RequestDeps.viewer` (Task 11); the viewer messages in `BackgroundToContent` (Task 2).
- Produces:

```ts
// drive-viewer.ts (content)
export const VIEWER_PAGE_SELECTOR: string;                              // recorded in Step 1
export function viewerPages(doc: Document): HTMLElement[];
export function currentPageIndex(pages: HTMLElement[], viewportHeight: number): number;   // the page with the largest visible area
export function scrollToPage(doc: Document, index: number, timeoutMs?: number):
  Promise<{ rect: { x: number; y: number; width: number; height: number }; devicePixelRatio: number }>;
  // scrollIntoView({ block: "center" }), then waits (default 3,000 ms) for a loaded <img> or <canvas> inside the page
// viewer-driver.ts (worker)
export const CAPTURE_MIN_INTERVAL_MS = 500;
export function cropRect(rect: { x: number; y: number; width: number; height: number }, dpr: number,
  image: { width: number; height: number }): { sx: number; sy: number; sw: number; sh: number };   // × dpr, rounded, clamped
export interface ImageOps { crop(dataUrl: string, r: { sx: number; sy: number; sw: number; sh: number }): Promise<string> } // base64 PNG
export class ViewerDriver implements ViewerHandler {
  constructor(deps: { tabs: typeof chrome.tabs; images: ImageOps; send(msg: ExtensionToApp): void; now(): number }) }
export const offscreenImageOps: ImageOps;   // createImageBitmap + OffscreenCanvas.convertToBlob({ type: "image/png" })
```

`capturePage(requestId, tabId, i)` runs these steps:
1. Send `progress` with the step `Viewer page <i+1> of <n>`.
2. Send `scrollTo` to frame 0.
3. Wait until at least 500 ms have passed since the last capture.
4. Call `captureVisibleTab(windowId, { format: "png" })`, then crop.

Errors:
- No viewer, 0 pages, or no receiver → `noViewer`.
- The tab is not active in its window → `noViewer` with "Viewer tab must be visible".
- The index is out of range → `notFound`.
- The page doesn't render in time → `timeout`.

`restore` scrolls back to the given index. A viewer inside a Classroom iframe is out of scope and answers `noViewer`.

- [ ] **Step 1: Record the viewer structure.** In Dia, open a Drive PDF in the viewer. Use DevTools to find the per-page container, and set `VIEWER_PAGE_SELECTOR` to its selector. Save a scrubbed three-page structural snippet as `test/fixtures/drive/viewer.html`.
- [ ] **Step 2: Write the failing tests**

```ts
it("viewerPages and currentPageIndex on the fixture", ...)   // stub getBoundingClientRect per page
it("cropRect scales by devicePixelRatio and clamps", () => {
  expect(cropRect({ x: 10, y: 20, width: 100, height: 200 }, 2, { width: 1000, height: 1000 })).toEqual({ sx: 20, sy: 40, sw: 200, sh: 400 });
  expect(cropRect({ x: -5, y: 900, width: 100, height: 200 }, 1, { width: 1000, height: 1000 })).toEqual({ sx: 0, sy: 900, sw: 95, sh: 100 }); });
it("capturePage sends progress, scrolls, captures and returns the cropped PNG", ...)  // index 246 of 412 → step "Viewer page 247 of 412"
it("captures are at least 500 ms apart", ...)
it("inactive tab → noViewer; out-of-range index → notFound", ...)
it("viewerRestore scrolls back and answers {}", ...)
```

- [ ] **Step 3: Run** `npx vitest run test/drive-viewer.test.ts test/viewer-driver.test.ts`. Expected: FAIL.
- [ ] **Step 4: Implement** both files. In `index.ts`, pass `viewer: new ViewerDriver({ … images: offscreenImageOps })`.
- [ ] **Step 5: Run** `npm test && npm run build`. Expected: PASS. Then, with a Drive viewer tab open, run `viewerInfo` and `capture` from the dev bridge. The PNG in `/tmp` shows exactly the requested page.
- [ ] **Step 6: Commit** — `git commit -m "feat(extension): Drive viewer page capture (fallback path)"`
