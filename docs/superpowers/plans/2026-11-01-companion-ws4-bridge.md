# WS4 — Bridge Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. First read `2026-11-01-companion-00-overview.md` (rules, global constraints, the "CompanionBridge (WS4)" API) and WS0 Tasks 3–5 in `2026-11-01-companion-ws0-foundation.md` (the frozen types this plan builds on).

**Goal:** Implement `CompanionBridge`, a token-authenticated WebSocket server on 127.0.0.1. It caches the browser context the extension pushes and sends request/response calls to the extension (tab context, Drive PDF bytes, viewer pages), and it exposes all of this as `BrowserContextProviding`, `DocumentFetching` and `ViewerDriving`.

**Architecture:** `BridgeServer` (a public actor) binds an `NWListener` to 127.0.0.1 and runs one `BridgeSession` actor per connection. Each session runs the receive loop, the hello timer and the handshake. Pushed messages go to a separate `ContextCache` actor, so the hot-path read never waits behind socket or PDF work. Requests go through a `RequestMultiplexer` actor, which handles ids, continuations, timeouts and binary-chunk collection. One `BridgeClient` struct adapts the server to the three CompanionCore protocols. The server actor enqueues every outbound frame synchronously, and `NWConnection.send` keeps call order, so each connection always receives `helloAck` → `config` → later `config`/requests/`ping` in that order.

**Tech Stack:** Swift 6.4 (language mode 6, strict concurrency), Network.framework (`NWListener`, `NWConnection`, `NWProtocolWebSocket`), Security (`SecRandomCopyBytes`), ImageIO (`CGImageSource`), Swift Testing. Tests drive the real server over loopback with Foundation `URLSessionWebSocketTask`.

**Spec:** `docs/superpowers/specs/2026-11-01-screen-companion-design.md` (§5.1 summon hot path, §5.6 bridge). Wire format: `contracts/bridge-protocol.md` and `contracts/fixtures/` (WS0).

## Global Constraints

- The overview's Global Constraints and Rules apply. Edit only `Sources/CompanionBridge/` and `Tests/CompanionBridgeTests/`. No third-party dependencies. Start only after WS0 is merged (`contracts-v1`).
- The public API is the overview's "CompanionBridge (WS4)" block, verbatim. Everything else in this plan is `internal`. Tests use `@testable import CompanionBridge`, `import CompanionCore` and `import CompanionTestSupport`.
- Use WS0 types as they are: `ExtensionToApp`, `AppToExtension`, `BridgeRequest`, `BridgeResponse.decodeResult`, `TabContextResult`, `DrivePdfResult`, `ViewerPageResult`, `BridgeError`/`BridgeErrorCode`, `BinaryFrame`/`BinaryFrameHeader`, `BridgeConstants`, `ViewerInfo`, `ImageAttachment`, `BridgeStatus` and `SecretKey.bridgeToken`. Never redeclare one. If a needed initializer or member is missing, stop and report it (overview rule 2).
- Every error that leaves `BridgePairing` or `BridgeClient` is a `BridgeError`. Map any other error to `.internal`. The `.notConnected` message is `Extension not connected` (spec §7).
- Listener: IPv4 loopback `127.0.0.1` only. Try the ports in `BridgeConstants.ports` (**47823, 47824, 47825, 47826, 47827**) in order and skip any that are in use. Set `allowLocalEndpointReuse = false`. Tests pass `ports: [0]` and read the bound port from `start()`.
- WebSocket: `maximumMessageSize` = **16,777,216** bytes (16 MiB, enough for a base64 viewer PNG); `autoReplyPing = true`.
- Handshake: the first frame must be a `hello` within `BridgeConstants.helloTimeout` (**5 s**). Close with **4001** for a wrong or missing token, a non-`hello`, binary or undecodable first frame, or no hello in time. Close with **4002** for a `BridgeError(.versionMismatch)` while decoding. `stop()` closes with 1001. On success, send `helloAck(appVersion:)` and then `config(blocklist:)`.
- Keep-alive: send the app-level `ping` every `BridgeConstants.pingInterval` (**20 s**) to authenticated sessions only.
- Hot path: callers pass `BridgeConstants.hotPathTimeout` (**300 ms**) to `requestActiveTabContext(timeout:)`. The bridge answers by the caller's timeout and adds no wait of its own. `cachedActiveTabContext()` does no I/O.
- Request timeouts: `getTabContext` uses the caller's timeout; `fetchDrivePdf` has **120 s** overall; `viewerInfo`, `viewerCapturePage` and `viewerRestore` each have **10 s**. Expiry → `BridgeError(.timeout)`. Disconnect → `.notConnected`.
- Request ids are `r-<n>`, with n starting at 1, from one counter per server.
- Binary chunk payloads are at most `BridgeConstants.maxChunkBytes` (**1,048,576**) bytes.
- Pairing token: 32 bytes from `SecRandomCopyBytes` → **64 lowercase hex** characters, stored under `SecretKey.bridgeToken`.
- Tests: each test file is one `@Suite struct` named after the file. Run one task's tests with `swift test --filter <Suite>` and all of them with `swift test --filter CompanionBridgeTests`. Each loopback test starts its own server on port 0 with short injected timings (`BridgeTimings.fast`), so tests can run in parallel. Each one ends with `await server.stop()`.

## Review Focus

1. **The user switches tabs and the new tab hasn't pushed its context yet.** `cachedActiveTabContext()` returns `nil`, never the previous tab's context (the spec's "wrong context" anti-goal). *Task 3 `switchToTabWithoutContextIsNil`*
2. **Two browsers or profiles are connected and both have a tab with the same `tabId`.** Snapshots are keyed by (connection, tabId). The "active" tab is the latest activation across all connections, and requests go only to that browser. When that browser disconnects, the other browser's last activation becomes active. *Task 3 `twoConnectionsSameTabId`, Task 6 `requestGoesOnlyToActiveBrowser`, Task 7 `viewerRequestsGoToTheTabsBrowser`*
3. **The extension is slow or silent on the hot path.** `requestActiveTabContext` returns `nil` by its timeout, the late answer is ignored, and the next request still works. *Task 6 `silentExtensionReturnsNilWithinTimeout`*
4. **The extension reconnects in the middle of a PDF transfer (service-worker restart).** `fetchDrivePDF` throws `.notConnected` at once (not after 120 s), the partial chunks are dropped, and a fetch over the new connection succeeds. *Task 7 `disconnectMidTransferFailsFast`*
5. **Chunks arrive out of order, duplicated or missing, or `byteLength` doesn't match.** Out-of-order chunks are reassembled. Every other case throws `.internal`, so the app never gets a truncated PDF. *Task 2 `ChunkAssemblerTests`, Task 7 `byteLengthMismatchThrows`*

---

### Task 1: Pairing token

**Files:**
- Create: `Sources/CompanionBridge/BridgePairing.swift`
- Delete: `Sources/CompanionBridge/CompanionBridge.swift`, `Tests/CompanionBridgeTests/PlaceholderTests.swift` (WS0 placeholders)
- Test: `Tests/CompanionBridgeTests/BridgePairingTests.swift`

**Interfaces:**
- Consumes: `SecretStoring`, `SecretKey.bridgeToken`, `BridgeError`; in tests, `FakeSecretStore`.
- Produces: `public enum BridgePairing` with `public static func token(in secrets: any SecretStoring) throws -> String` and `public static func regenerate(in secrets: any SecretStoring) throws -> String` (verbatim), plus the internal `static func makeToken() throws -> String`.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct BridgePairingTests {
    @Test func tokenIsCreatedOnceAndStored() throws {
        let store = FakeSecretStore()
        let t = try BridgePairing.token(in: store)
        #expect(t.count == 64 && t.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(store.secret(for: SecretKey.bridgeToken) == t)
        #expect(try BridgePairing.token(in: store) == t)
    }
    @Test func existingTokenIsReturnedUnchanged() throws {
        let existing = String(repeating: "ab", count: 32)
        #expect(try BridgePairing.token(in: FakeSecretStore([SecretKey.bridgeToken: existing])) == existing)
    }
    @Test func regenerateReplacesStoredToken() throws {
        let store = FakeSecretStore()
        let old = try BridgePairing.token(in: store)
        let new = try BridgePairing.regenerate(in: store)
        #expect(new != old && new.count == 64)
        #expect(store.secret(for: SecretKey.bridgeToken) == new)
    }
    @Test func tokensAreRandom() throws { #expect(try BridgePairing.makeToken() != (try BridgePairing.makeToken())) }
}
```

- [ ] **Step 2: Run** `swift test --filter BridgePairingTests`. Expected: FAIL with `cannot find 'BridgePairing' in scope`.
- [ ] **Step 3: Implement `BridgePairing`.**
  - `makeToken()`: call `SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)`. Any status other than `errSecSuccess` throws `BridgeError(code: .internal, message: "SecRandomCopyBytes failed (<status>)")`. Hex-encode each byte with `String(format: "%02x", $0)`.
  - `token(in:)`: return the stored value when it is non-empty; otherwise make, store and return a new one.
  - `regenerate(in:)`: always make, store and return a new token.
  - Delete both placeholder files.
- [ ] **Step 4: Run** `swift test --filter BridgePairingTests`. Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add -A Sources/CompanionBridge Tests/CompanionBridgeTests
git commit -m "feat(bridge): pairing token generation and storage"
```

---

### Task 2: Frame codec and chunk assembler

**Files:**
- Create: `Sources/CompanionBridge/FrameCodec.swift`, `Sources/CompanionBridge/ChunkAssembler.swift`, `Tests/CompanionBridgeTests/Support/TestHelpers.swift`
- Test: `Tests/CompanionBridgeTests/FrameCodecTests.swift`, `Tests/CompanionBridgeTests/ChunkAssemblerTests.swift`

**Interfaces:**
- Consumes: `ExtensionToApp`, `AppToExtension`, `BinaryFrameHeader`, `BridgeError`, `BridgeConstants.protocolVersion`, `BridgeConstants.maxChunkBytes`, `Fixtures.bridgeFixture(_:)`, `Fixtures.allBridgeFixtureNames()`.
- Produces:

```swift
enum FrameCodec {
    static func encode(_ message: AppToExtension) throws -> Data      // UTF-8 JSON for one text frame
    static func decodeText(_ data: Data) throws -> ExtensionToApp     // checks "v" before anything else
}
struct ChunkAssembler: Sendable {
    init(requestID: String, maxChunkBytes: Int = BridgeConstants.maxChunkBytes)
    mutating func add(_ header: BinaryFrameHeader, _ payload: Data) throws   // BridgeError(.internal) on any violation
    func assemble() throws -> Data
}
// Support/TestHelpers.swift
func ext(_ json: String) throws -> ExtensionToApp                // decode an inline wire message
func fixtureMessage(_ name: String) throws -> ExtensionToApp     // decode contracts/fixtures/<name>
func fixtureContext(_ name: String) throws -> TabContext         // the .tabContext payload of a fixture
func jsonString(_ value: some Encodable) throws -> String
func expectBridgeError(_ code: BridgeErrorCode, sourceLocation: SourceLocation = #_sourceLocation,
                       _ body: () async throws -> Void) async    // records an issue unless body throws BridgeError with `code`
```

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct FrameCodecTests {
    @Test func decodesEveryExtensionFixture() throws {
        for name in try Fixtures.allBridgeFixtureNames() where name.hasPrefix("ext-") {
            _ = try FrameCodec.decodeText(Fixtures.bridgeFixture(name))
        }
    }
    @Test func encodesTheWireShape() throws {
        let encoded = try JSONSerialization.jsonObject(with: FrameCodec.encode(.ping)) as? NSDictionary
        #expect(encoded == (try JSONSerialization.jsonObject(with: Fixtures.bridgeFixture("app-ping.json")) as? NSDictionary))
    }
    @Test func versionIsCheckedBeforeType() async throws {
        await expectBridgeError(.versionMismatch) { _ = try FrameCodec.decodeText(Fixtures.bridgeFixture("invalid-version.json")) }
        await expectBridgeError(.versionMismatch) {
            _ = try FrameCodec.decodeText(Data(#"{"v":2,"type":"hello","token":"x","extensionVersion":"9.0","browserName":"Dia"}"#.utf8))
        }
    }
    @Test func malformedTextIsNotAVersionMismatch() {
        let error = #expect(throws: (any Error).self) { try FrameCodec.decodeText(Data("not json".utf8)) }
        #expect((error as? BridgeError)?.code != .versionMismatch)
    }
}

@Suite struct ChunkAssemblerTests {
    static let pdf = Data((0..<2_621_440).map { UInt8(truncatingIfNeeded: $0 &* 31) })   // 2.5 MiB
    static var slices: [Data] { stride(from: 0, to: pdf.count, by: 1_048_576).map { pdf[$0..<min($0 + 1_048_576, pdf.count)] } }  // 3 slices
    func h(_ seq: Int, last: Bool = false, id: String = "r-7") -> BinaryFrameHeader { BinaryFrameHeader(id: id, seq: seq, last: last) }

    @Test func reassemblesInOrder() throws {
        var a = ChunkAssembler(requestID: "r-7"); let s = Self.slices
        try a.add(h(0), s[0]); try a.add(h(1), s[1]); try a.add(h(2, last: true), s[2])
        #expect(try a.assemble() == Self.pdf)
    }
    @Test func reordersOutOfOrderFrames() throws { /* add 2(last), 0, 1 → assemble() == Self.pdf */ }
    @Test func rejectsDuplicateSeq() async { /* add h(0); expectBridgeError(.internal) { add h(0) again } */ }
    @Test func rejectsGap() async { /* add h(0), h(2, last: true); expectBridgeError(.internal) { assemble() } */ }
    @Test func rejectsMissingLastFrame() async { /* add h(0), h(1); expectBridgeError(.internal) { assemble() } */ }
    @Test func rejectsFrameAfterLast() async { /* after h(0, last: true): add h(1) → .internal; add h(1, last: true) → .internal */ }
    @Test func rejectsForeignIDAndOversizedPayload() async { /* h(0, id: "r-8") → .internal; payload of maxChunkBytes + 1 → .internal */ }
    @Test func noFramesAssemblesToEmpty() throws { #expect(try ChunkAssembler(requestID: "r-7").assemble().isEmpty) }
}
```

- [ ] **Step 2: Run** `swift test --filter "FrameCodecTests|ChunkAssemblerTests"`. Expected: FAIL with `cannot find 'FrameCodec' in scope`.
- [ ] **Step 3: Implement `FrameCodec`, `ChunkAssembler` and the test helpers.**
  - `decodeText` first decodes a private `struct { let v: Int }` and throws `BridgeError(code: .versionMismatch, message: "Unsupported protocol version <v>")` when `v != BridgeConstants.protocolVersion`. Only then does it decode `ExtensionToApp` with `JSONDecoder`. So a v2 `hello` is a version mismatch no matter which order WS0 checks fields in.
  - `encode` uses `JSONEncoder`.
  - `add` throws `.internal` when `id != requestID`, `seq < 0`, the seq is already present, `payload.count > maxChunkBytes`, a `last` frame already arrived and this frame is also `last` or has a higher `seq`, or this frame is `last` and a higher `seq` is already present.
  - `assemble` returns empty `Data` when no frames were added. Otherwise it throws `.internal` unless a `last` frame arrived and the seqs are exactly `0...lastSeq`; it then concatenates the payloads in seq order.
- [ ] **Step 4: Run** `swift test --filter "FrameCodecTests|ChunkAssemblerTests"`. Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add Sources/CompanionBridge Tests/CompanionBridgeTests
git commit -m "feat(bridge): frame codec and PDF chunk assembler"
```

---

### Task 3: Context cache

**Files:**
- Create: `Sources/CompanionBridge/ContextCache.swift`
- Test: `Tests/CompanionBridgeTests/ContextCacheTests.swift`

**Interfaces:**
- Consumes: `ExtensionToApp`, `TabContext`; from Task 2, `ext`, `fixtureMessage` and `fixtureContext`.
- Produces:

```swift
struct ConnectionID: Hashable, Sendable, CustomStringConvertible { let raw: UInt64 }
actor ContextCache {
    init()
    func apply(_ message: ExtensionToApp, from connection: ConnectionID)  // tabActivated, tabContext, youtubePlayhead, tabClosed; other cases ignored
    func store(_ context: TabContext, from connection: ConnectionID)     // a getTabContext answer
    func connectionClosed(_ connection: ConnectionID)
    func activeTabContext() -> TabContext?
    func activeConnection() -> ConnectionID?
    func connection(forTab tabId: Int) -> ConnectionID?
}
```

- [ ] **Step 1: Write the failing tests** (`dia = ConnectionID(raw: 1)`, `chrome = ConnectionID(raw: 2)`)

```swift
@Suite struct ContextCacheTests {
    @Test func activeTabReturnsItsSnapshot() async throws {
        let cache = ContextCache()
        await cache.apply(try fixtureMessage("ext-tabActivated.json"), from: dia)
        await cache.apply(try fixtureMessage("ext-tabContext-youtube.json"), from: dia)
        #expect(await cache.activeTabContext()?.youtube?.videoId == "abc123XYZ00")
        #expect(await cache.activeConnection() == dia)
    }
    @Test func switchToTabWithoutContextIsNil() async throws {        // Review Focus 1
        // same setup as activeTabReturnsItsSnapshot (dia: tab 12 + youtube), then
        // apply ext(#"{"v":1,"type":"tabActivated","tabId":21,"windowId":3,"url":"https://example-homework.test/unit4/q3","title":"Unit 4"}"#)
        #expect(await cache.activeTabContext() == nil)
        // apply ext-tabContext-math.json → activeTabContext()?.tabId == 21; re-activate tab 12 → youtube snapshot again
    }
    @Test func playheadUpdatesOnlyMatchingVideo() async throws {
        // ext-youtubePlayhead.json → youtube?.playheadSeconds == 766.5 and chapter == "Finding the roots"
        // playhead with videoId "zzzzzzzzzzz", 900 → playheadSeconds still 766.5
    }
    @Test func tabClosedDropsSnapshotAndActivation() async throws { /* ext-tabClosed.json → activeTabContext() == nil, activeConnection() == nil */ }
    @Test func blockedContextIsCachedVerbatim() async throws { /* activate 40 + ext-tabContext-blocked.json → blocked == true, page == nil */ }
    @Test func twoConnectionsSameTabId() async throws {               // Review Focus 2
        // dia: activate 12 + youtube. chrome: activate 12 + .tabContext(math with tabId = 12)
        #expect(await cache.activeTabContext()?.page?.title == "Unit 4 Quiz Review")
        // dia re-activates 12 → youtube; connectionClosed(dia) → math (chrome's last activation); connectionClosed(chrome) → nil
    }
    @Test func storeActivatesWhenNothingIsActive() async throws { /* fresh cache; store(math, from: chrome) → activeConnection() == chrome, activeTabContext()?.tabId == 21 */ }
    @Test func storeDoesNotStealActiveFromAnotherBrowser() async throws {
        // dia active on 12; store(math, from: chrome) → activeConnection() == dia; connection(forTab: 21) == chrome
    }
}
```

- [ ] **Step 2: Run** `swift test --filter ContextCacheTests`. Expected: FAIL with `cannot find 'ContextCache' in scope`.
- [ ] **Step 3: Implement `ContextCache`.** It keeps three pieces of state: `snapshots: [Key(connection, tabId): TabContext]`, `activations: [ConnectionID: (tabId: Int, order: UInt64)]` and a monotonic `order` counter.
  - `tabActivated` sets `activations[c] = (tabId, nextOrder)`.
  - `tabContext` replaces the whole snapshot for `(c, ctx.tabId)`. Blocked contexts are stored as they are.
  - `youtubePlayhead` changes `playheadSeconds` and `chapter` (set to the message's value, even `nil`) only when a snapshot exists and its `youtube?.videoId` matches.
  - `tabClosed` removes the snapshot, and removes `activations[c]` if it points at that tab.
  - `store` replaces the snapshot. If `c` is the active connection, its active `tabId` becomes `ctx.tabId` and its order stays the same. If nothing is active anywhere, it records a new activation for `(c, ctx.tabId)`.
  - `connectionClosed` drops every snapshot and the activation for `c`.
  - `activeConnection` is the connection with the highest activation order. `activeTabContext` is that connection's snapshot for its active tab, or `nil`; it never falls back to another tab.
  - `connection(forTab:)` picks, among connections holding a snapshot for `tabId`, the one with the highest activation order (connections that never activated rank lowest), or returns `nil`.
- [ ] **Step 4: Run** `swift test --filter ContextCacheTests`. Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat(bridge): per-connection tab context cache"` (after `git add Sources/CompanionBridge Tests/CompanionBridgeTests`).

---

### Task 4: Listener, sessions and handshake

**Files:**
- Create: `Sources/CompanionBridge/BridgeTimings.swift`, `Sources/CompanionBridge/BridgeListener.swift`, `Sources/CompanionBridge/BridgeSession.swift`, `Sources/CompanionBridge/BridgeServer.swift`, `Tests/CompanionBridgeTests/Support/TestClient.swift`
- Modify: `Tests/CompanionBridgeTests/Support/TestHelpers.swift` (add `makeServer` and `BridgeTimings.fast`)
- Test: `Tests/CompanionBridgeTests/HandshakeTests.swift`

**Interfaces:**
- Consumes: Task 1 `BridgePairing.token(in:)`; Task 2 `FrameCodec`; Task 3 `ConnectionID`; WS0 `HelloMessage`, `BinaryFrame.decode`, `BridgeConstants`.
- Produces:

```swift
struct BridgeTimings: Sendable, Equatable {
    var helloTimeout: Duration; var pingInterval: Duration; var drivePdfTimeout: Duration; var viewerTimeout: Duration
    static let standard = BridgeTimings(helloTimeout: BridgeConstants.helloTimeout, pingInterval: BridgeConstants.pingInterval,
                                        drivePdfTimeout: BridgeConstants.drivePdfTimeout, viewerTimeout: BridgeConstants.viewerRequestTimeout)
}
enum BridgeListener {
    static let maxMessageBytes = 16_777_216
    static func makeParameters(port: UInt16) -> NWParameters
    static func bind(ports: [UInt16], queue: DispatchQueue,
                     onConnection: @escaping @Sendable (NWConnection) -> Void) async throws -> (listener: NWListener, port: UInt16)
}
// Close codes and request timeouts come from CompanionCore: BridgeConstants.closeCodeUnauthorized (4001),
// .closeCodeVersionMismatch (4002), .drivePdfTimeout (120 s), .viewerRequestTimeout (10 s) — do not redeclare.
actor BridgeSession {
    struct Events: Sendable {
        var authenticated: @Sendable (BridgeSession, HelloMessage) async -> Void
        var message: @Sendable (ConnectionID, ExtensionToApp) async -> Void
        var binary: @Sendable (ConnectionID, BinaryFrameHeader, Data) async -> Void
        var closed: @Sendable (ConnectionID) async -> Void          // exactly once
    }
    nonisolated let id: ConnectionID
    init(id: ConnectionID, connection: NWConnection, queue: DispatchQueue, timings: BridgeTimings,
         expectedToken: @escaping @Sendable () -> String?, events: Events)
    func start()
    nonisolated func enqueue(_ message: AppToExtension)   // call only from BridgeServer's actor
    func close(code: NWProtocolWebSocket.CloseCode)
}
public actor BridgeServer {
    public init(secrets: any SecretStoring, blocklist: BlocklistConfig,
                ports: [UInt16] = BridgeConstants.ports, appVersion: String)   // delegates with timings: .standard
    init(secrets: any SecretStoring, blocklist: BlocklistConfig, ports: [UInt16], appVersion: String, timings: BridgeTimings)
    public func start() async throws -> UInt16
    public func stop() async
}
// Tests
extension BridgeTimings { static let fast = BridgeTimings(helloTimeout: .seconds(1), pingInterval: .seconds(60),
                                                          drivePdfTimeout: .seconds(3), viewerTimeout: .seconds(1)) }
func makeServer(timings: BridgeTimings = .fast, blocklist: BlocklistConfig = .starter) async throws
    -> (server: BridgeServer, port: UInt16, token: String, secrets: FakeSecretStore)   // ports [0], appVersion "test-1.0", started
final class TestClient: Sendable {
    static func connect(port: UInt16) async throws -> TestClient   // ws://127.0.0.1:<port>; waits for didOpen; maximumMessageSize 16 MiB
    func send(text: String) async throws
    func send(fixture name: String) async throws                    // the fixture file, verbatim, as one text frame
    func send(binary: Data) async throws
    func hello(token: String, browserName: String = "Dia") async throws
    func next(timeout: Duration = .seconds(2)) async -> AppToExtension?   // nil at the deadline or after close
    func closeCode(timeout: Duration = .seconds(2)) async -> Int?        // the server's close code; nil if still open
    func disconnect()
}
```

`TestClient` runs one background loop that pumps `receive()` into an actor mailbox, so a timed-out `next` never swallows a later message. When `receive()` throws, the mailbox records the close code, taken from `URLSessionWebSocketDelegate.urlSession(_:webSocketTask:didCloseWith:reason:)` or, failing that, from `task.closeCode.rawValue`.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct HandshakeTests {
    @Test func parametersAreLoopbackOnlyWith16MiBMessages() {
        let p = BridgeListener.makeParameters(port: 47823)
        #expect(p.requiredLocalEndpoint == .hostPort(host: "127.0.0.1", port: 47823))
        #expect(p.allowLocalEndpointReuse == false)
        let ws = p.defaultProtocolStack.applicationProtocols.first as? NWProtocolWebSocket.Options
        #expect(ws?.maximumMessageSize == 16_777_216 && ws?.autoReplyPing == true)
    }
    @Test func standardTimings() {
        #expect(BridgeTimings.standard == BridgeTimings(helloTimeout: .seconds(5), pingInterval: .seconds(20),
                                                        drivePdfTimeout: BridgeConstants.drivePdfTimeout, viewerTimeout: BridgeConstants.viewerRequestTimeout))
    }
    @Test func startCreatesTokenAndReturnsBoundPort() async throws {
        let secrets = FakeSecretStore()
        let server = BridgeServer(secrets: secrets, blocklist: .starter, ports: [0], appVersion: "test-1.0")
        #expect(try await server.start() > 0)
        #expect(secrets.secret(for: SecretKey.bridgeToken)?.count == 64)
        await server.stop()
    }
    @Test func skipsPortInUse() async throws {
        // blocker: a plain-TCP NWListener with requiredLocalEndpoint 127.0.0.1:.any; await .ready; P = its port
        let a = BridgeServer(secrets: FakeSecretStore(), blocklist: .starter, ports: [P, 0], appVersion: "t")
        #expect(try await a.start() != P)
        let b = BridgeServer(secrets: FakeSecretStore(), blocklist: .starter, ports: [P], appVersion: "t")
        await expectBridgeError(.internal) { _ = try await b.start() }
    }
    @Test func goodTokenGetsHelloAckThenConfig() async throws {
        var blocklist = BlocklistConfig.starter; blocklist.domains.append("example-homework.test")
        let (server, port, token, _) = try await makeServer(blocklist: blocklist)
        let client = try await TestClient.connect(port: port)
        try await client.hello(token: token)
        #expect(await client.next() == .helloAck(appVersion: "test-1.0"))
        #expect(await client.next() == .config(blocklist: blocklist))
        await server.stop()
    }
    @Test func wrongTokenIsClosed4001() async throws { /* hello(token: String(repeating: "0", count: 64)) → closeCode() == 4001 and no helloAck was received */ }
    @Test func silenceIsClosed4001AfterHelloTimeout() async throws {
        // timings: .fast with helloTimeout = .milliseconds(200); connect and send nothing
        // closeCode(timeout: .seconds(2)) == 4001; time from connect to close ≥ 150 ms
    }
    @Test func firstMessageMustBeHello() async throws { /* send(fixture: "ext-tabActivated.json") → closeCode() == 4001 */ }
    @Test func versionMismatchIsClosed4002() async throws {
        // send(text: #"{"v":2,"type":"hello","token":"<token>","extensionVersion":"9.0","browserName":"Dia"}"#) → closeCode() == 4002
    }
}
```

- [ ] **Step 2: Run** `swift test --filter HandshakeTests`. Expected: FAIL with `cannot find 'BridgeListener' in scope`.
- [ ] **Step 3: Implement the four source files and the test support.**
  - **`makeParameters`:** start from `NWParameters.tcp`. Insert an `NWProtocolWebSocket.Options()` (with `maximumMessageSize = maxMessageBytes` and `autoReplyPing = true`) at index 0 of `defaultProtocolStack.applicationProtocols`. Set `requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)` (port 0 means any port) and `allowLocalEndpointReuse = false`.
  - **`bind`:** for each port, create `NWListener(using:)`, set `newConnectionHandler`, `start(queue:)`, and await the first relevant state. `.ready` → return `listener.port!.rawValue`. `.failed` or `.waiting` → `cancel()` and try the next port. If every port fails → throw `BridgeError(code: .internal, message: "No free bridge port in <ports>")`.
  - **`BridgeSession` receive loop:** wrap `connection.receiveMessage` in a continuation and read the opcode from `NWProtocolWebSocket.Metadata`. **Await each event before reading the next frame**, so each connection's message order is preserved into the cache. `closed` fires once, on `.cancelled`, `.failed` or a receive error.
  - **Handshake:**
    - The first frame goes through `FrameCodec.decodeText`. `.versionMismatch` → `close(.privateCode(4002))`.
    - Close with `.privateCode(4001)` for: any other decode error, a binary frame, a non-`hello` message, or a token mismatch. Compare the token with a constant-time byte comparison against `expectedToken()`; a `nil` expected token never matches.
    - Otherwise the session becomes authenticated and awaits `events.authenticated(self, hello)`.
    - The hello timer is a `Task` that sleeps `timings.helloTimeout` and then closes with 4001 if the session is still waiting for `hello`.
  - **After authentication:** decode text frames; `.versionMismatch` → close 4002, other decode errors and repeated `hello` messages are ignored, and everything else goes to `events.message`. Decode binary frames with `BinaryFrame.decode`, ignore errors, and pass the result to `events.binary`.
  - **`close(code:)`:** send a message whose context carries `NWProtocolWebSocket.Metadata(opcode: .close)` with `closeCode = code`, then call `connection.cancel()` in its `.contentProcessed` completion.
  - **`enqueue`:** encode with `FrameCodec.encode` and call `connection.send` with text-opcode metadata and `isComplete: true`. On a send error, cancel the connection.
  - **`BridgeServer.init`:** the public init delegates to the internal init with `timings: .standard`. The server uses one serial `DispatchQueue(label: "dev.local.Companion.bridge")`.
  - **`BridgeServer.start()`:**
    - If the server is already started, return the current port.
    - Call `_ = try BridgePairing.token(in: secrets)`, then `bind`.
    - For each new connection, assign the next `ConnectionID` and create a `BridgeSession` with `expectedToken: { [secrets] in secrets.secret(for: SecretKey.bridgeToken) }`. The token is read per connection, so a regenerated token applies only to new connections.
    - The `authenticated` event appends `(id, session, hello)` to an ordered `authenticated` list. In the same synchronous step it calls `session.enqueue(.helloAck(appVersion:))` and then `session.enqueue(.config(blocklist:))`.
    - The `closed` event removes the session.
  - **`stop()`:** cancel the listener, close every session with `.protocolCode(.goingAway)`, clear state and set `port` to `nil`.
- [ ] **Step 4: Run** `swift test --filter HandshakeTests`. Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat(bridge): loopback WebSocket listener, sessions and token handshake"` (after `git add Sources/CompanionBridge Tests/CompanionBridgeTests`).

---

### Task 5: Request multiplexer

**Files:**
- Create: `Sources/CompanionBridge/RequestMultiplexer.swift`
- Test: `Tests/CompanionBridgeTests/RequestMultiplexerTests.swift`

**Interfaces:**
- Consumes: Task 2 `ChunkAssembler`; Task 3 `ConnectionID`; WS0 `BridgeRequest`, `BridgeResponse`, `BinaryFrameHeader`, `BridgeError`.
- Produces:

```swift
struct RequestOutcome: Sendable { var response: BridgeResponse; var chunks: ChunkAssembler? }
actor RequestMultiplexer {
    init()
    /// Allocates "r-<n>", registers a waiter for `connection`, sends, then waits for the response, the timeout,
    /// the connection closing, or a chunk error. An `ok: false` response throws its `error` payload.
    func perform(on connection: ConnectionID, timeout: Duration,
                 _ makeRequest: (String) -> BridgeRequest,
                 send: @escaping @Sendable (BridgeRequest) async throws -> Void) async throws -> RequestOutcome
    func handleResponse(_ response: BridgeResponse, from connection: ConnectionID)
    func handleBinary(_ header: BinaryFrameHeader, _ payload: Data, from connection: ConnectionID)
    func connectionClosed(_ connection: ConnectionID)   // that connection's pending requests → .notConnected
    func failAll()                                      // every pending request → .notConnected (used by stop())
    var pendingCount: Int { get }
}
```

- [ ] **Step 1: Write the failing tests.** The fake `send` yields into `AsyncStream.makeStream(of: BridgeRequest.self)`. Responses are built with `ext(...)` from inline JSON such as `{"v":1,"type":"response","id":"r-1","ok":true,"result":{…}}`.

```swift
@Suite struct RequestMultiplexerTests {
    @Test func idsAreSequentialAndResponseResolves() async throws {
        // perform(.viewerInfo(id: $0, tabId: 34)) → the sent request has id "r-1" and method "viewerInfo"
        // handleResponse(ok, result {"pageCount":412,"currentIndex":87}) → outcome.response.decodeResult(ViewerInfo.self) == ViewerInfo(pageCount: 412, currentIndex: 87)
        // a second perform sends id "r-2"
    }
    @Test func errorPayloadIsThrown() async throws {
        // response ok:false, error {"code":"downloadBlocked","message":"The owner has disabled downloads for this file."}
        // → throws BridgeError with code .downloadBlocked and that exact message
    }
    @Test func timeoutThrowsAndForgetsRequest() async throws {
        // timeout .milliseconds(100), no response → .timeout; pendingCount == 0; a late handleResponse for that id does nothing
    }
    @Test func disconnectFailsOnlyThatConnectionsRequests() async throws {
        // two pending on c1 and one on c2 (timeouts 10 s); connectionClosed(c1) → both c1 requests throw .notConnected in < 500 ms; c2 still resolves
    }
    @Test func responseFromAnotherConnectionIsIgnored() async throws { /* request on c1; same-id response from c2 → pendingCount == 1; then from c1 → resolves */ }
    @Test func sendFailureThrowsNotConnected() async throws { /* send throws → .notConnected; pendingCount == 0 */ }
    @Test func binaryFramesAreCollectedForTheRequest() async throws {
        // 3 frames for the request id in seq order 2(last), 0, 1, then an ok response → outcome.chunks?.assemble() == the original bytes
    }
    @Test func duplicateChunkFailsRequestImmediately() async throws { /* seq 0 twice → perform throws .internal with no response sent */ }
}
```

- [ ] **Step 2: Run** `swift test --filter RequestMultiplexerTests`. Expected: FAIL with `cannot find 'RequestMultiplexer' in scope`.
- [ ] **Step 3: Implement `RequestMultiplexer`.**
  - Inside `withCheckedThrowingContinuation`, **register** `Pending(connection, continuation, assembler: nil, timeoutTask)` under the new id **before** sending, because a fast extension can answer before `send` returns.
  - Then start a `Task` that awaits `send(request)`; on failure it calls `finish(id, .notConnected)`.
  - Start the timeout task too: it sleeps `timeout`, then calls `finish(id, BridgeError(code: .timeout, message: "<method> timed out"))`.
  - `finish` removes the entry first and cancels its timeout task. Whichever of these arrives first wins and every later one is a no-op: response, timeout, disconnect, send failure or chunk error.
  - `handleBinary` and `handleResponse` act only when the id is pending **on that same connection**. `handleBinary` creates the assembler lazily, and an `add` error finishes the request with that error.
  - An `ok: false` response throws `response.error ?? BridgeError(code: .internal, message: "Error response without error payload")`.
- [ ] **Step 4: Run** `swift test --filter RequestMultiplexerTests`. Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat(bridge): request multiplexer with timeouts and chunk collection"`.

---

### Task 6: Message routing and `BrowserContextProviding`

**Files:**
- Modify: `Sources/CompanionBridge/BridgeServer.swift`, `Tests/CompanionBridgeTests/Support/TestHelpers.swift` (add `eventually`)
- Create: `Sources/CompanionBridge/BridgeClient.swift`, `Tests/CompanionBridgeTests/Support/ScriptedExtension.swift`
- Test: `Tests/CompanionBridgeTests/BrowserContextTests.swift`

**Interfaces:**
- Consumes: Task 3 `ContextCache`; Task 4 `BridgeServer`, `BridgeSession`, `TestClient`, `makeServer`; Task 5 `RequestMultiplexer`; WS0 `TabContextResult`.
- Produces:

```swift
// Added inside `public actor BridgeServer` (stored properties can't live in an extension)
    public nonisolated var browserContext: any BrowserContextProviding { get }   // BridgeClient(server: self)
    nonisolated let cache: ContextCache          // `let` actors, so the client reaches them without hopping through the server actor
    nonisolated let multiplexer: RequestMultiplexer
    nonisolated let timings: BridgeTimings
    func requestTarget() async -> ConnectionID?  // cache.activeConnection() if authenticated, else the most recently authenticated session
    func send(_ message: AppToExtension, to connection: ConnectionID) throws   // BridgeError(.notConnected) unless authenticated
    func hasAuthenticatedSession() -> Bool
// BridgeClient.swift
struct BridgeClient: BrowserContextProviding { let server: BridgeServer }    // Task 7 adds DocumentFetching and ViewerDriving
// Tests
func eventually<T: Sendable>(timeout: Duration = .seconds(2), _ probe: @Sendable () async -> T?) async -> T?  // polls every 10 ms
final class ScriptedExtension: Sendable {
    static func connect(port: UInt16, token: String, browserName: String = "Dia") async throws -> ScriptedExtension  // hello; requires helloAck then config
    func push(fixture name: String) async throws
    func push(_ message: ExtensionToApp) async throws                         // JSONEncoder → text frame
    func nextRequest(timeout: Duration = .seconds(2)) async -> BridgeRequest? // skips ping and config
    func respond(id: String, resultJSON: String) async throws                 // {"v":1,"type":"response","id":…,"ok":true,"result":<resultJSON>}
    func respondError(id: String, code: String, message: String) async throws
    func sendChunks(id: String, data: Data, order: [Int]? = nil) async throws // 1 MiB slices via BinaryFrame.encode; `order` = slice indices to send, in that order
    func disconnect()
}
```

- [ ] **Step 1: Write the failing tests** (`math = try fixtureContext("ext-tabContext-math.json")`)

```swift
@Suite struct BrowserContextTests {
    @Test func pushedContextIsCached() async throws {
        let (server, port, token, _) = try await makeServer()
        let dia = try await ScriptedExtension.connect(port: port, token: token)
        try await dia.push(fixture: "ext-tabActivated.json"); try await dia.push(fixture: "ext-tabContext-youtube.json")
        #expect(await eventually { await server.browserContext.cachedActiveTabContext() }?.youtube?.playheadSeconds == 761)
        #expect(await server.browserContext.isConnected())
        await server.stop()
    }
    @Test func requestActiveTabContextAsksTheExtension() async throws {
        async let result = server.browserContext.requestActiveTabContext(timeout: .seconds(2))
        let req = try #require(await dia.nextRequest())
        #expect(req == .getTabContext(id: req.id, tabId: nil))
        try await dia.respond(id: req.id, resultJSON: "{\"context\":" + (try jsonString(math)) + "}")
        #expect(await result == math)
        #expect(await server.browserContext.cachedActiveTabContext() == math)
    }
    @Test func nullContextResponseIsNil() async throws { /* respond {"context":null} → nil; cachedActiveTabContext() == nil */ }
    @Test func noBrowserMeansNilAndNotConnected() async throws {
        // no client: requestActiveTabContext(timeout: .milliseconds(300)) == nil and returns in < 100 ms; isConnected() == false
    }
    @Test func silentExtensionReturnsNilWithinTimeout() async throws {   // Review Focus 3
        // dia receives request r and stays silent → requestActiveTabContext(timeout: .milliseconds(300)) == nil, elapsed < 550 ms
        // dia.respond(id: r.id, math) afterwards → cachedActiveTabContext() stays nil
        // a second request that dia answers promptly → == math
    }
    @Test func requestGoesOnlyToActiveBrowser() async throws {           // Review Focus 2
        // dia: ext-tabActivated + youtube (tab 12). chrome (browserName "Chrome"): tabActivated 12 + .tabContext(math with tabId 12)
        // eventually cached?.page != nil; then requestActiveTabContext → chrome.nextRequest() != nil, dia.nextRequest(timeout: .milliseconds(300)) == nil
        // chrome.disconnect() → eventually cached?.youtube?.videoId == "abc123XYZ00"
    }
    @Test func disconnectClearsConnectionAndCache() async throws { /* dia pushes youtube, then disconnects → eventually isConnected() == false and cached == nil */ }
}
```

- [ ] **Step 2: Run** `swift test --filter BrowserContextTests`. Expected: FAIL with `value of type 'BridgeServer' has no member 'browserContext'`.
- [ ] **Step 3: Implement routing and `BridgeClient`.**
  - **Routing in `BridgeServer`:** the session's `message` event sends `tabActivated`, `tabContext`, `youtubePlayhead` and `tabClosed` to `cache.apply`, and `response` to `multiplexer.handleResponse`. `progress` is dropped (no contract API consumes it) and a repeated `hello` is ignored. `binary` goes to `multiplexer.handleBinary`. `closed` removes the session and calls `cache.connectionClosed` and `multiplexer.connectionClosed`. `stop()` also calls `multiplexer.failAll()`.
  - **`BridgeClient`:** `cachedActiveTabContext` is `await server.cache.activeTabContext()` and never hops through the server actor. `isConnected` is `await server.hasAuthenticatedSession()`. `requestActiveTabContext(timeout:)` does this:
    1. `target = await server.requestTarget()`, or return `nil`.
    2. `multiplexer.perform(on: target, timeout: timeout, { .getTabContext(id: $0, tabId: nil) }, send: { try await server.send(.request($0), to: target) })`.
    3. Decode `TabContextResult`; a non-nil context → `cache.store(ctx, from: target)`. Any error → `nil`.
- [ ] **Step 4: Run** `swift test --filter BrowserContextTests`. Expected: PASS. Then run `swift test --filter CompanionBridgeTests`. Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat(bridge): route pushed context and serve BrowserContextProviding"`.

---

### Task 7: `DocumentFetching` and `ViewerDriving`

**Files:**
- Modify: `Sources/CompanionBridge/BridgeServer.swift`, `Sources/CompanionBridge/BridgeClient.swift`
- Test: `Tests/CompanionBridgeTests/DocumentAndViewerTests.swift`

**Interfaces:**
- Consumes: Task 6 `BridgeClient`, `requestTarget()`, `send(_:to:)`, `ScriptedExtension`; Task 3 `ContextCache.connection(forTab:)`; WS0 `DrivePdfResult`, `ViewerPageResult`, `ViewerInfo`, `Fixtures.samplePNG(width:height:)`.
- Produces:

```swift
extension BridgeServer {
    public nonisolated var documentFetcher: any DocumentFetching { get }   // BridgeClient(server: self)
    public nonisolated var viewerDriver: any ViewerDriving { get }
    func viewerTarget(tabId: Int) async -> ConnectionID?   // cache.connection(forTab:) if authenticated, else requestTarget()
}
extension BridgeClient: DocumentFetching, ViewerDriving {
    static func imageAttachment(fromBase64 png: String) throws -> ImageAttachment   // BridgeError(.internal) if not a decodable image
}
```

- [ ] **Step 1: Write the failing tests** (`fileId = "1AbCdEfGhIjKlMnOpQrStUvWxYz012345"`, `pdf` = the 2.5 MiB data from Task 2)

```swift
@Suite struct DocumentAndViewerTests {
    @Test func fetchesPdfStreamedInThreeChunks() async throws {
        async let got = server.documentFetcher.fetchDrivePDF(fileId: fileId)
        let req = try #require(await dia.nextRequest())
        #expect(req == .fetchDrivePdf(id: req.id, fileId: fileId))
        try await dia.sendChunks(id: req.id, data: pdf, order: [2, 0, 1])
        try await dia.respond(id: req.id, resultJSON: #"{"fileId":"\#(fileId)","title":"Algebra 2 Textbook.pdf","byteLength":2621440}"#)
        let (data, title) = try await got
        #expect(data == pdf && title == "Algebra 2 Textbook.pdf")
    }
    @Test func downloadBlockedIsThrown() async throws { /* respondError(code: "downloadBlocked", …) → .downloadBlocked */ }
    @Test func byteLengthMismatchThrows() async throws { /* all 3 chunks, byteLength 2097152 → .internal */ }          // Review Focus 5
    @Test func disconnectMidTransferFailsFast() async throws {                                                        // Review Focus 4
        // timings.drivePdfTimeout = .seconds(30); dia sends chunks [0, 1], then disconnect() → throws .notConnected, elapsed < 1 s
        // a new ScriptedExtension connects (no pushes) → a full fetch succeeds through it
    }
    @Test func noBrowserThrowsNotConnected() async throws { /* no client → fetchDrivePDF and viewerInfo throw .notConnected */ }
    @Test func requestTimeoutsUseInjectedValues() async throws {
        // timings drivePdfTimeout .milliseconds(200) / viewerTimeout .milliseconds(200); silent client → both throw .timeout
    }
    @Test func viewerInfoCaptureAndRestore() async throws {
        // viewerInfo(tabId: 34): request == .viewerInfo(id:_, tabId: 34); respond {"pageCount":412,"currentIndex":87} → ViewerInfo(pageCount: 412, currentIndex: 87)
        // capturePage(tabId: 34, pageIndex: 246): respond {"pageIndex":246,"pngBase64": Fixtures.samplePNG(width: 4, height: 3).png base64}
        //   → pixelWidth == 4, pixelHeight == 3, png == the sample bytes
        // restore(tabId: 34, pageIndex: 87): request == .viewerRestore(id:_, tabId: 34, pageIndex: 87); respond "{}" → no throw
    }
    @Test func badCaptureThrowsInternal() async throws { /* pngBase64 "not-base64!" → .internal; pageIndex 245 for a 246 request → .internal */ }
    @Test func viewerRequestsGoToTheTabsBrowser() async throws {                                                      // Review Focus 2
        // dia pushes ext-tabContext-drive.json (tab 34); chrome then activates tab 5 → viewerInfo(tabId: 34) reaches dia; chrome gets nothing in 300 ms
    }
}
```

- [ ] **Step 2: Run** `swift test --filter DocumentAndViewerTests`. Expected: FAIL with `value of type 'BridgeServer' has no member 'documentFetcher'`.
- [ ] **Step 3: Implement the two conformances in `BridgeClient`.**
  - **`fetchDrivePDF`:** `target = await server.requestTarget()`, or throw `.notConnected`. Call `perform` with `timings.drivePdfTimeout` and decode `DrivePdfResult`; a `fileId` that doesn't match the request → `.internal`. Then `data = try outcome.chunks?.assemble() ?? Data()`, which runs on the caller's task, not on any actor. If `data.count != byteLength`, throw `BridgeError(code: .internal, message: "PDF size mismatch: expected <n> bytes, got <m>")`. Return `(data, result.title)`.
  - **Viewer methods** use `viewerTarget(tabId:)` and `timings.viewerTimeout`. `viewerInfo` decodes `ViewerInfo`. `capturePage` decodes `ViewerPageResult`, requires `pageIndex == requested` (else `.internal`), then calls `imageAttachment(fromBase64:)`: `Data(base64Encoded:)` → `CGImageSourceCreateWithData` → `CGImageSourceCopyPropertiesAtIndex` → `kCGImagePropertyPixelWidth` and `kCGImagePropertyPixelHeight`. `restore` succeeds on any `ok: true` response and ignores `result`, which may be `{}` or absent.
  - Map every non-`BridgeError` to `.internal`.
- [ ] **Step 4: Run** `swift test --filter DocumentAndViewerTests`. Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat(bridge): Drive PDF fetch and viewer driving over the bridge"`.

---

### Task 8: Keep-alive, blocklist push and status

**Files:**
- Modify: `Sources/CompanionBridge/BridgeServer.swift`
- Test: `Tests/CompanionBridgeTests/KeepAliveStatusTests.swift`

**Interfaces:**
- Consumes: Task 4 `authenticated` list and `BridgeSession.enqueue`; Task 1 `BridgePairing.regenerate(in:)`; Task 4 `TestClient`.
- Produces (verbatim): `public func updateBlocklist(_ config: BlocklistConfig) async` and `public func status() async -> BridgeStatus`.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct KeepAliveStatusTests {
    @Test func authenticatedSessionsArePinged() async throws {
        // pingInterval .milliseconds(100); after the handshake (helloAck and config drained): next() == .ping twice within 1 s
    }
    @Test func unauthenticatedSessionsAreNotPinged() async throws {
        // pingInterval .milliseconds(50), helloTimeout .seconds(2); connect without hello → next(timeout: .milliseconds(400)) == nil
    }
    @Test func updateBlocklistReachesEverySession() async throws {
        // two clients handshaken; var b = BlocklistConfig.starter; b.domains.append("example-homework.test"); updateBlocklist(b)
        // → each client's next() == .config(blocklist: b); a third client's handshake config == b
    }
    @Test func statusListsPortAndBrowsers() async throws {
        // before start(): status().port == nil && connectedBrowsers.isEmpty
        // "Dia" and then "Chrome" authenticate, plus one client that never sends hello → port == bound port, connectedBrowsers == ["Dia", "Chrome"]
        // Dia disconnects → eventually ["Chrome"]; after stop() → port == nil && connectedBrowsers.isEmpty
    }
    @Test func regeneratedTokenOnlyAffectsNewConnections() async throws {
        // client A handshakes; BridgePairing.regenerate(in: secrets); A still receives .ping (interval 100 ms)
        // a new client with the old token → closeCode() == 4001; a new client with the new token → .helloAck
    }
}
```

- [ ] **Step 2: Run** `swift test --filter KeepAliveStatusTests`. Expected: FAIL with `value of type 'BridgeServer' has no member 'status'`.
- [ ] **Step 3: Implement keep-alive, blocklist push and status.**
  - `start()` launches a `pingTask` that loops `try await Task.sleep(for: timings.pingInterval)` and then enqueues `.ping` to every authenticated session. `stop()` cancels the task.
  - `updateBlocklist` stores the new value and enqueues `.config(blocklist:)` to every authenticated session. New sessions get the stored value during the handshake.
  - `status()` returns `BridgeStatus(port: port, connectedBrowsers: authenticated.map { $0.hello.browserName })`, in authentication order.
- [ ] **Step 4: Run** `swift test --filter CompanionBridgeTests`. Expected: PASS for the whole module. Then run `scripts/test-all.sh`. Expected: exit 0.
- [ ] **Step 5: Commit** with `git commit -m "feat(bridge): keep-alive pings, blocklist push and status"`.
