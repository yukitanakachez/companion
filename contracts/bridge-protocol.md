# Bridge protocol, version 1

The app and the Chromium extension talk over one WebSocket. The JSON files in `fixtures/` are the normative examples: `ext-*` are extension→app, `app-*` are app→extension, and `invalid-version.json` must be rejected. `Sources/CompanionCore/Bridge.swift` and `ts/protocol.ts` both implement this document.

## Transport

The app listens on `ws://127.0.0.1:<port>`, binding to the first free port of **47823, 47824, 47825, 47826, 47827**. The extension tries the ports in that order.

Every JSON message is one WebSocket text frame: an object with `"v": 1`, a `"type"`, and the case's fields flattened into the same object. There are two exceptions: `tabContext` carries its payload under `"context"`, and `request` carries `"id"`, `"method"` and `"params"`. A message whose `v` is not 1 is rejected with `versionMismatch`, whatever its `type`.

## Handshake

1. The extension sends `hello` first, with the pairing token (32 random bytes as 64 lowercase hex characters).
2. The app replies `helloAck`, then `config` with the current blocklist.
3. **Immediately after receiving `helloAck`, the extension sends `tabActivated` for the focused window's active tab, followed by that tab's `tabContext`.** A reconnect therefore never leaves the app without an active tab.

The app closes the connection with:

| Code | Meaning | When |
|---|---|---|
| **4001** | `unauthorized` | Wrong token, or no `hello` within 5 s |
| **4002** | `versionMismatch` | The message's protocol version is not 1 |

## Push messages (extension → app)

| Type | Sent |
|---|---|
| `tabActivated` | On tab switch **and** on browser-window focus |
| `tabContext` | On load, navigation and debounced scroll, and when a YouTube transcript becomes ready |
| `youtubePlayhead` | Every 5 s while playing, and on seek |
| `tabClosed` | When a tab closes |

### Blocked sites

For any host matching `config.blocklist.domains` (the host itself or a dot-suffix of it), the extension sends `tabContext` with `blocked: true` and no content fields: no `page`, `youtube`, `classroom` or `drive`. Nothing from a blocked site is read, even locally.

## Requests (app → extension)

A request is `{"v":1,"type":"request","id":…,"method":…,"params":…}`. The extension answers with exactly one `response` carrying the same `id`, and may send `progress` messages (`id`, `step`) before it.

| Method | Params | `result` on success | App timeout |
|---|---|---|---|
| `getTabContext` | `tabId` (number or `null` for the active tab) | `TabContextResult`: `{"context": TabContext or null}` | Set by the caller |
| `fetchDrivePdf` | `fileId` | `DrivePdfResult`: `{fileId, title, byteLength}` | 120 s |
| `viewerInfo` | `tabId` | `ViewerInfo`: `{pageCount, currentIndex}` (0-based) | 10 s |
| `viewerCapturePage` | `tabId`, `pageIndex` (0-based) | `ViewerPageResult`: `{pageIndex, pngBase64}` | 10 s |
| `viewerRestore` | `tabId`, `pageIndex` (0-based) | `EmptyResult`: `{}` or `null` | 10 s |

A response is `{"v":1,"type":"response","id":…,"ok":true,"result":…}` or `{"v":1,"type":"response","id":…,"ok":false,"error":{"code":…,"message":…}}`.

## Binary PDF transfer

`fetchDrivePdf` sends the file as zero or more binary WebSocket frames, then the JSON `response`. Each binary frame is:

1. a 4-byte big-endian header length N,
2. N bytes of UTF-8 JSON `BinaryFrameHeader`: `{"id": <request id>, "seq": <n>, "last": <bool>}`,
3. the payload, at most **1,048,576** bytes.

`seq` starts at 0, and `last` is `true` on the final frame.

## Keep-alive

The app sends `ping` every 20 s. The extension does not reply.

## Error codes

| Code | Meaning |
|---|---|
| `notConnected` | No authenticated extension is connected |
| `notFound` | The tab or file doesn't exist |
| `downloadBlocked` | The file's owner has disabled downloads |
| `notPdf` | The file isn't a PDF |
| `noViewer` | The tab has no Drive viewer |
| `timeout` | The request didn't finish in time |
| `blocked` | The site is on the blocklist |
| `unauthorized` | The pairing token is wrong |
| `versionMismatch` | The protocol version isn't supported |
| `internal` | Anything else, including a malformed frame |
