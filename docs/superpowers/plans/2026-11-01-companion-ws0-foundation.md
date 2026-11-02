# WS0 — Foundation & Contracts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read `2026-11-01-companion-00-overview.md` (rules, global constraints) and the spec first.

**Goal:** Create the repository skeleton every other workstream builds in, and freeze the shared contracts (Swift types/protocols in `CompanionCore`, the bridge wire protocol in `contracts/`, test fakes in `CompanionTestSupport`).

**Architecture:** One SwiftPM package declares every target up front (placeholders for other workstreams) so no later workstream edits `Package.swift`. `CompanionCore` has no dependencies and holds only value types, protocols and tiny pure helpers. The bridge protocol is defined once as JSON fixtures that both Swift (here) and TypeScript (WS3) must decode.

**Tech Stack:** Swift 6.4 / SwiftPM tools 6.0, Swift Testing, XcodeGen, TypeScript (type-check only).

**Spec:** `docs/superpowers/specs/2026-11-01-screen-companion-design.md`

## Global Constraints

All of the overview's Global Constraints apply. This workstream additionally fixes: module names, file layout, ports/timeouts/caps as constants, the starter blocklist, default settings, and the wire format. **Runs alone, first, on `main`** (or a `ws/ws0-foundation` branch merged before anyone else starts).

**Initializer rule (applies to every task here):** every `public struct` in `CompanionCore` and `CompanionTestSupport` declares an explicit `public init` taking all stored properties in declared order (Swift does not synthesize public memberwise initializers). Other workstreams construct these types — e.g. `BridgeError(code:message:)`, `BridgeStatus(port:connectedBrowsers:)`, `ViewerInfo(pageCount:currentIndex:)`, `DocumentChoice(current:alternatives:)`, `BinaryFrameHeader(id:seq:last:)`, `PermissionStatus(screenRecording:accessibility:)`.

## Review Focus

Covered by later workstreams (see overview). WS0's own risk: a contract that can't express what a consumer needs. Mitigation: Task 4's fixtures cover every message variant, and Task 5's fakes exercise every protocol.

---

### Task 1: Repository skeleton and package

**Files:**
- Create: `Package.swift`, `.gitignore`, `AGENTS.md`, `CLAUDE.md`, `scripts/test-all.sh`, `scripts/new-workstream.sh`
- Create placeholders (one comment-only `.swift` file each): `Sources/CompanionCore/CompanionCore.swift`, `Sources/CompanionLLM/CompanionLLM.swift`, `Sources/CompanionPageFinder/CompanionPageFinder.swift`, `Sources/CompanionBridge/CompanionBridge.swift`, `Sources/CompanionCapture/CompanionCapture.swift`, `Sources/CompanionUI/CompanionUI.swift`, `Sources/CompanionSession/CompanionSession.swift`, `Sources/CompanionTestSupport/CompanionTestSupport.swift`
- Create: `Sources/CompanionUIDemo/main.swift` (`print("CompanionUIDemo placeholder — WS6 replaces this")`)
- Create: `Sources/CompanionUI/Resources/web/index.html` (placeholder `<!doctype html><title>placeholder</title>`)
- Create: `Tests/CompanionLLMTests/Fixtures/README.md` (one line: "SSE recordings — owned by WS1")
- Create test placeholders: `Tests/<Target>Tests/PlaceholderTests.swift` for Core, LLM, PageFinder, Bridge, Capture, UI, Session — each `import Testing` + `@Test func placeholder() {}`

**Interfaces:**
- Produces: target and product names used by everyone (exact, below).

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Companion",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CompanionCore", targets: ["CompanionCore"]),
        .library(name: "CompanionLLM", targets: ["CompanionLLM"]),
        .library(name: "CompanionPageFinder", targets: ["CompanionPageFinder"]),
        .library(name: "CompanionBridge", targets: ["CompanionBridge"]),
        .library(name: "CompanionCapture", targets: ["CompanionCapture"]),
        .library(name: "CompanionUI", targets: ["CompanionUI"]),
        .library(name: "CompanionSession", targets: ["CompanionSession"]),
        .executable(name: "CompanionUIDemo", targets: ["CompanionUIDemo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .target(name: "CompanionCore"),
        .target(name: "CompanionLLM", dependencies: ["CompanionCore"]),
        .target(name: "CompanionPageFinder", dependencies: ["CompanionCore"]),
        .target(name: "CompanionBridge", dependencies: ["CompanionCore"]),
        .target(name: "CompanionCapture", dependencies: ["CompanionCore"]),
        .target(name: "CompanionUI", dependencies: ["CompanionCore", "KeyboardShortcuts"],
                resources: [.copy("Resources/web")]),
        .target(name: "CompanionSession", dependencies: [
            "CompanionCore", "CompanionLLM", "CompanionPageFinder",
            "CompanionBridge", "CompanionCapture", "CompanionUI"]),
        .executableTarget(name: "CompanionUIDemo", dependencies: ["CompanionUI", "CompanionCore"]),
        .target(name: "CompanionTestSupport", dependencies: ["CompanionCore"]),
        .testTarget(name: "CompanionCoreTests", dependencies: ["CompanionCore", "CompanionTestSupport"]),
        .testTarget(name: "CompanionLLMTests", dependencies: ["CompanionLLM", "CompanionTestSupport"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "CompanionPageFinderTests", dependencies: ["CompanionPageFinder", "CompanionTestSupport"]),
        .testTarget(name: "CompanionBridgeTests", dependencies: ["CompanionBridge", "CompanionTestSupport"]),
        .testTarget(name: "CompanionCaptureTests", dependencies: ["CompanionCapture", "CompanionTestSupport"]),
        .testTarget(name: "CompanionUITests", dependencies: ["CompanionUI", "CompanionTestSupport"]),
        .testTarget(name: "CompanionSessionTests", dependencies: [
            "CompanionSession", "CompanionCore", "CompanionLLM", "CompanionPageFinder",
            "CompanionBridge", "CompanionCapture", "CompanionUI", "CompanionTestSupport"]),
    ]
)
```

- [ ] **Step 2: Write `.gitignore`**

```
.build/
.swiftpm/
DerivedData/
*.xcodeproj/
Xcode/
Config/Signing.local.xcconfig
.superpowers/
extension/node_modules/
extension/dist/
ui-web/node_modules/
.DS_Store
```

- [ ] **Step 3: Write `scripts/test-all.sh`** (executable) — `set -euo pipefail`; `swift build`; `swift test`; `npx -y -p typescript@5 tsc -p contracts/ts --noEmit` (skip with a message if `contracts/ts` is absent); if `extension/package.json` exists: `(cd extension && npm ci && npm test && npm run build)`; if `ui-web/package.json` exists: `(cd ui-web && npm ci && npm test)`. Exit non-zero on any failure.

- [ ] **Step 4: Write `scripts/new-workstream.sh <id>`** (executable) — validates one argument; runs `git worktree add "../companion-$1" -b "ws/$1" main`; prints the path and the line `Give your agent: Implement docs/superpowers/plans/2026-11-01-companion-$1.md`.

- [ ] **Step 5: Write `AGENTS.md`** — the eight "Rules every agent follows" from the overview, verbatim, plus: "Workstream plans live in `docs/superpowers/plans/`; read `2026-11-01-companion-00-overview.md` first." Write `CLAUDE.md` containing the single line `@AGENTS.md`.

- [ ] **Step 6: Create all placeholder files listed above, then verify**

Run: `swift build && swift test`
Expected: build succeeds (KeyboardShortcuts resolves); 7 placeholder tests pass.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Package.resolved .gitignore AGENTS.md CLAUDE.md scripts Sources Tests
git commit -m "chore: repository skeleton with all workstream targets"
```

---

### Task 2: Core context types and chip labels

**Files:**
- Create: `Sources/CompanionCore/Context.swift` (replace the placeholder file `CompanionCore.swift` with nothing — delete it)
- Test: `Tests/CompanionCoreTests/ContextTests.swift` (delete `PlaceholderTests.swift`)

**Interfaces:**
- Produces (all `public`, all `Sendable`, `Equatable`; memberwise `public init` for every struct):

```swift
public enum ContextKind: String, Codable, Sendable, CaseIterable {
    case youtube, mathPage, webPage, pdfPages, genericWindow, region
}
public struct ImageAttachment: Codable { public var png: Data; public var pixelWidth: Int; public var pixelHeight: Int }
public struct TranscriptSegment: Codable { public var start: Double; public var duration: Double; public var text: String }
public enum TranscriptStatus: String, Codable { case loading, available, unavailable }
public struct YouTubeContext: Codable {
    public var videoId: String; public var title: String; public var channel: String?; public var chapter: String?
    public var playheadSeconds: Double; public var durationSeconds: Double?
    public var transcriptStatus: TranscriptStatus
    public var transcript: [TranscriptSegment]        // empty unless .available
}
public struct MathSnippet: Codable {
    public enum Format: String, Codable, Sendable { case latex, mathml }
    public var format: Format; public var source: String
}
public struct WebPageContext: Codable { public var url: String; public var title: String; public var visibleText: String; public var math: [MathSnippet] }
public struct DriveFileRef: Codable, Hashable { public var fileId: String; public var title: String; public var mimeType: String? }
public struct ClassroomContext: Codable { public var assignmentTitle: String?; public var attachments: [DriveFileRef] }
public struct DriveViewerContext: Codable { public var file: DriveFileRef }
public struct TabContext: Codable {
    public var tabId: Int; public var url: String; public var title: String
    public var capturedAtMs: Double; public var blocked: Bool
    public var page: WebPageContext?; public var youtube: YouTubeContext?
    public var classroom: ClassroomContext?; public var drive: DriveViewerContext?
}
public struct FrontAppInfo { public var bundleID: String; public var appName: String; public var pid: Int32
                             public var windowTitle: String?; public var windowFrame: CGRect? }   // AppKit global coords
public struct RenderedPage { public var printedLabel: String; public var pdfIndex: Int; public var image: ImageAttachment; public var text: String }
public enum ContextNotice: String, CaseIterable { case contextOffForApp, contextOffForSite, siteNotChecked, extensionNotConnected, noCaptions
                                                  public var label: String }
public enum ContextPiece {
    case windowImage(ImageAttachment)
    case regionImage(ImageAttachment)
    case youtubeVideo(YouTubeContext)
    case transcriptWindow(segments: [TranscriptSegment], from: Double, to: Double)
    case webPage(WebPageContext)
    case math([MathSnippet])
    case pdfPages([RenderedPage])
    case selectedText(String)
    case focusedText(String)
    case notice(ContextNotice)
}
public struct ContextItem: Identifiable {
    public let id: UUID; public var piece: ContextPiece
    public init(id: UUID = UUID(), piece: ContextPiece)
    public var chipLabel: String { get }
    public var isRemovable: Bool { get }          // false only for .notice
}
public enum PrivacyDecision: Sendable, Equatable { case allowed, blocked(reason: String), siteUnchecked }
public struct CapturedContext {
    public var front: FrontAppInfo?; public var privacy: PrivacyDecision; public var kind: ContextKind
    public var items: [ContextItem]; public var isComplete: Bool
    public var tabId: Int?                        // browser tab the context came from (nil when not a browser / unknown)
    public var hasImage: Bool { get }             // windowImage, regionImage or pdfPages present
    public var hasExtractedMath: Bool { get }     // a non-empty .math present
    public func removingItem(_ id: UUID) -> CapturedContext
}
public enum KnownBrowsers {
    public static let bundleIDs: Set<String>      // exact list below
    public static let chromiumBundleIDs: Set<String>   // bundleIDs minus Safari and Firefox
    public static func isBrowser(_ bundleID: String) -> Bool
    public static func usesExtension(_ bundleID: String) -> Bool   // true for chromiumBundleIDs
}
public func formatTimestamp(_ seconds: Double) -> String
```

- [ ] **Step 1: Write the failing tests** in `ContextTests.swift` (Swift Testing):

```swift
@Test func timestamps() {
    #expect(formatTimestamp(761) == "12:41")
    #expect(formatTimestamp(581.2) == "9:41")
    #expect(formatTimestamp(3725) == "1:02:05")
    #expect(formatTimestamp(0) == "0:00")
    #expect(formatTimestamp(-5) == "0:00")
}
@Test func chipLabels() {
    let img = ImageAttachment(png: Data([1]), pixelWidth: 1, pixelHeight: 1)
    let yt = YouTubeContext(videoId: "abc123XYZ00", title: "Solving Quadratics", channel: nil,
                            chapter: "Finding the roots", playheadSeconds: 761, durationSeconds: 1450,
                            transcriptStatus: .available, transcript: [])
    #expect(ContextItem(piece: .windowImage(img)).chipLabel == "window")
    #expect(ContextItem(piece: .regionImage(img)).chipLabel == "region")
    #expect(ContextItem(piece: .youtubeVideo(yt)).chipLabel == "▶ 12:41 · Finding the roots")
    #expect(ContextItem(piece: .transcriptWindow(segments: [], from: 581, to: 761)).chipLabel == "transcript 9:41–12:41")
    #expect(ContextItem(piece: .math([MathSnippet(format: .latex, source: "x"), MathSnippet(format: .latex, source: "y")])).chipLabel == "math ×2")
    #expect(ContextItem(piece: .selectedText("hi")).chipLabel == "selection")
    #expect(ContextItem(piece: .focusedText("hi")).chipLabel == "screen text")
    #expect(ContextItem(piece: .notice(.siteNotChecked)).chipLabel == "site not checked")
    #expect(ContextItem(piece: .notice(.extensionNotConnected)).isRemovable == false)
}
@Test func pdfPageChipLabels() {
    func page(_ l: String) -> RenderedPage { RenderedPage(printedLabel: l, pdfIndex: 0, image: ImageAttachment(png: Data(), pixelWidth: 1, pixelHeight: 1), text: "") }
    #expect(ContextItem(piece: .pdfPages([page("231")])).chipLabel == "p. 231")
    #expect(ContextItem(piece: .pdfPages([page("231"), page("232")])).chipLabel == "pp. 231–232")
    #expect(ContextItem(piece: .pdfPages([page("231"), page("233")])).chipLabel == "pp. 231, 233")
}
@Test func capturedContextHelpers() { /* hasImage true with windowImage; hasExtractedMath false for .math([]) and true for one snippet; removingItem drops only that id */ }
```

`KnownBrowsers.bundleIDs` (exact): `company.thebrowser.dia`, `com.google.Chrome`, `company.thebrowser.Browser`, `com.brave.Browser`, `com.microsoft.edgemac`, `com.apple.Safari`, `org.mozilla.firefox`. Test: `KnownBrowsers.isBrowser("company.thebrowser.dia")` is true, `isBrowser("com.apple.Notes")` is false.

Also: chapter longer than 24 characters is truncated to its first 24 characters in the `.youtubeVideo` chip; a `nil` chapter yields `"▶ 12:41"`. Notice labels: `contextOffForApp` → `context off for this app`, `contextOffForSite` → `context off for this site`, `siteNotChecked` → `site not checked`, `extensionNotConnected` → `extension not connected`, `noCaptions` → `no captions`. `webPage` chip → `page text`.

- [ ] **Step 2: Run to verify failure** — `swift test --filter CompanionCoreTests` → FAIL (types not defined).
- [ ] **Step 3: Implement `Context.swift`** with the declarations above. `pdfPages` chip: if every label parses as `Int` and they are consecutive → `pp. <first>–<last>` (en dash); one page → `p. <label>`; otherwise `pp. ` + labels joined by `, `.
- [ ] **Step 4: Run to verify pass** — `swift test --filter CompanionCoreTests` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(core): context types, chip labels, timestamps"`

---

### Task 3: Core privacy, LLM, settings and service protocols

**Files:**
- Create: `Sources/CompanionCore/Privacy.swift`, `Sources/CompanionCore/LLM.swift`, `Sources/CompanionCore/Settings.swift`, `Sources/CompanionCore/Services.swift`
- Test: `Tests/CompanionCoreTests/SettingsTests.swift`

**Interfaces:**
- Produces:

```swift
// Privacy.swift
public struct BlocklistConfig: Codable, Sendable, Equatable {
    public var bundleIDs: [String]
    public var domains: [String]        // matched as the host or a dot-suffix of it (WS5/WS3 implement matching)
    public static let starter: BlocklistConfig
}
// LLM.swift
public struct ModelRef: Codable, Sendable, Hashable {
    public var providerID: String; public var modelID: String; public var displayName: String
    public static let anthropicProviderID = "anthropic"
    public static let openAICompatibleProviderID = "openai-compatible"
}
public enum ModelCatalog {
    public static let haiku45 = ModelRef(providerID: "anthropic", modelID: "claude-haiku-4-5-20251001", displayName: "Haiku 4.5")
    public static let sonnet55 = ModelRef(providerID: "anthropic", modelID: "claude-sonnet-5-5", displayName: "Sonnet 5.5")
    public static let defaultCycle: [ModelRef] = [haiku45, sonnet55]
}
public enum LLMRole: String, Codable, Sendable { case user, assistant }
public enum LLMContent: Sendable, Equatable {
    case text(String)
    case image(ImageAttachment)
    case toolUse(id: String, name: String, inputJSON: String)              // reserved for v2
    case toolResult(toolUseID: String, content: String, isError: Bool)     // reserved for v2
}
public struct LLMMessage: Sendable, Equatable { public var role: LLMRole; public var content: [LLMContent] }
public struct LLMToolSpec: Sendable, Equatable { public var name: String; public var description: String; public var inputSchemaJSON: String }
public struct LLMRequest: Sendable, Equatable {
    public var model: ModelRef; public var system: String; public var messages: [LLMMessage]
    public var maxTokens: Int; public var tools: [LLMToolSpec]
    public init(model: ModelRef, system: String, messages: [LLMMessage], maxTokens: Int = 4096, tools: [LLMToolSpec] = [])
}
public enum LLMStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case toolUse(id: String, name: String, inputJSON: String)
    case finished(stopReason: String?)
}
public enum LLMError: Error, Sendable, Equatable {
    case missingAPIKey(providerID: String)
    case http(status: Int, message: String)
    case network(String)
    case decoding(String)
}
public protocol LLMProvider: Sendable {
    var providerID: String { get }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error>
    func prewarm() async
}
// Settings.swift
public struct RoutingDefaults: Codable, Sendable, Equatable {
    public var youtube, mathPage, webPage, pdfPages, genericWindow, region: ModelRef
    public func model(for kind: ContextKind) -> ModelRef
    public static let standard: RoutingDefaults    // youtube/webPage/genericWindow → haiku45; mathPage/pdfPages/region → sonnet55
}
public struct AppSettings: Codable, Sendable, Equatable {
    public var routing: RoutingDefaults
    public var modelCycle: [ModelRef]
    public var openAICompatibleBaseURL: String     // default "https://api.openai.com/v1"
    public var orbEnabled: Bool                     // default true
    public var orbPosition: CGPoint?                // default nil (bottom-right of main screen)
    public var blocklist: BlocklistConfig           // default .starter
    public static let `default`: AppSettings
}
@MainActor public protocol SettingsStoring: AnyObject {
    var settings: AppSettings { get }
    func update(_ mutate: (inout AppSettings) -> Void)
    func addObserver(_ onChange: @escaping @MainActor (AppSettings) -> Void)   // app-lifetime observers
}
public protocol SecretStoring: Sendable {
    func secret(for key: String) -> String?
    func setSecret(_ value: String?, for key: String) throws        // nil deletes
}
public enum SecretKey {
    public static let anthropicAPIKey = "anthropic.apiKey"
    public static let openAICompatibleAPIKey = "openai-compatible.apiKey"
    public static let bridgeToken = "bridge.pairingToken"
}
public struct DocumentChoice: Sendable, Equatable { public var current: DriveFileRef; public var alternatives: [DriveFileRef] }
public struct BridgeStatus: Sendable, Equatable { public var port: UInt16?; public var connectedBrowsers: [String] }
public enum PermissionKind: Sendable, Equatable { case screenRecording, accessibility }
public struct PermissionStatus: Sendable, Equatable { public var screenRecording: Bool; public var accessibility: Bool }
// Services.swift
public protocol BrowserContextProviding: Sendable {
    func cachedActiveTabContext() async -> TabContext?                       // no I/O; most recently activated tab across connected browsers
    func requestActiveTabContext(timeout: Duration) async -> TabContext?     // asks the extension; nil on timeout/disconnect
    func isConnected() async -> Bool
}
public protocol DocumentFetching: Sendable {
    func fetchDrivePDF(fileId: String) async throws -> (data: Data, title: String)   // throws BridgeError
}
public struct ViewerInfo: Codable, Sendable, Equatable { public var pageCount: Int; public var currentIndex: Int }   // 0-based index
public protocol ViewerDriving: Sendable {
    func viewerInfo(tabId: Int) async throws -> ViewerInfo
    func capturePage(tabId: Int, pageIndex: Int) async throws -> ImageAttachment
    func restore(tabId: Int, pageIndex: Int) async throws
}
```

`BlocklistConfig.starter` (exact): bundleIDs `com.1password.1password`, `com.agilebits.onepassword7`, `com.bitwarden.desktop`, `com.lastpass.LastPass`, `com.apple.keychainaccess`, `com.apple.Passwords`, `com.apple.MobileSMS`, `com.hnc.Discord`, `net.whatsapp.WhatsApp`, `ru.keepcoder.Telegram`, `org.whispersystems.signal-desktop`; domains `1password.com`, `bitwarden.com`, `lastpass.com`, `dashlane.com`, `chase.com`, `bankofamerica.com`, `wellsfargo.com`, `citi.com`, `capitalone.com`, `usbank.com`, `pnc.com`, `schwab.com`, `fidelity.com`, `paypal.com`, `venmo.com`, `discord.com`, `web.whatsapp.com`, `messages.google.com`.

- [ ] **Step 1: Write the failing tests** — `RoutingDefaults.standard.model(for:)` returns `haiku45` for `.youtube`, `.webPage`, `.genericWindow` and `sonnet55` for `.mathPage`, `.pdfPages`, `.region`; `AppSettings.default` survives `JSONEncoder` → `JSONDecoder` round-trip unchanged; `AppSettings.default.openAICompatibleBaseURL == "https://api.openai.com/v1"`; `BlocklistConfig.starter.bundleIDs.contains("com.1password.1password")` and `.domains.contains("chase.com")`; `LLMRequest(model:system:messages:)` defaults `maxTokens == 4096`, `tools.isEmpty`.
- [ ] **Step 2: Run** `swift test --filter CompanionCoreTests` → FAIL.
- [ ] **Step 3: Implement** the four files exactly as declared.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(core): privacy, LLM, settings and service contracts"`

---

### Task 4: Bridge wire protocol (Swift + fixtures + TypeScript mirror)

**Files:**
- Create: `contracts/bridge-protocol.md`, `contracts/fixtures/*.json` (list below), `contracts/ts/protocol.ts`, `contracts/ts/tsconfig.json`
- Create: `Sources/CompanionCore/JSONValue.swift`, `Sources/CompanionCore/Bridge.swift`
- Test: `Tests/CompanionCoreTests/BridgeProtocolTests.swift`

**Interfaces:**
- Produces:

```swift
public enum BridgeConstants {
    public static let protocolVersion = 1
    public static let ports: [UInt16] = [47823, 47824, 47825, 47826, 47827]
    public static let maxChunkBytes = 1_048_576
    public static let helloTimeout: Duration = .seconds(5)
    public static let hotPathTimeout: Duration = .milliseconds(300)
    public static let pingInterval: Duration = .seconds(20)
    public static let drivePdfTimeout: Duration = .seconds(120)
    public static let viewerRequestTimeout: Duration = .seconds(10)
    public static let closeCodeUnauthorized: UInt16 = 4001
    public static let closeCodeVersionMismatch: UInt16 = 4002
}
public enum JSONValue: Codable, Sendable, Equatable { case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue]) }
public enum BridgeErrorCode: String, Codable, Sendable {
    case notConnected, notFound, downloadBlocked, notPdf, noViewer, timeout, blocked, unauthorized, versionMismatch, `internal`
}
public struct BridgeError: Error, Codable, Sendable, Equatable { public var code: BridgeErrorCode; public var message: String }
public struct HelloMessage: Codable, Sendable, Equatable { public var token: String; public var extensionVersion: String; public var browserName: String }
public struct TabActivatedMessage: Codable, Sendable, Equatable { public var tabId: Int; public var windowId: Int; public var url: String; public var title: String }
public struct YouTubePlayheadMessage: Codable, Sendable, Equatable { public var tabId: Int; public var videoId: String; public var playheadSeconds: Double; public var chapter: String? }
public struct ProgressMessage: Codable, Sendable, Equatable { public var id: String; public var step: String }
public struct BridgeResponse: Codable, Sendable, Equatable {
    public var id: String; public var ok: Bool; public var result: JSONValue?; public var error: BridgeError?
    public func decodeResult<T: Decodable>(_ type: T.Type) throws -> T
}
public enum ExtensionToApp: Codable, Sendable, Equatable {
    case hello(HelloMessage)
    case tabActivated(TabActivatedMessage)
    case tabContext(TabContext)
    case youtubePlayhead(YouTubePlayheadMessage)
    case tabClosed(tabId: Int)
    case response(BridgeResponse)
    case progress(ProgressMessage)
}
public enum BridgeRequest: Codable, Sendable, Equatable {
    case getTabContext(id: String, tabId: Int?)
    case fetchDrivePdf(id: String, fileId: String)
    case viewerInfo(id: String, tabId: Int)
    case viewerCapturePage(id: String, tabId: Int, pageIndex: Int)
    case viewerRestore(id: String, tabId: Int, pageIndex: Int)
    public var id: String { get }
    public var method: String { get }      // "getTabContext", "fetchDrivePdf", ...
}
public enum AppToExtension: Codable, Sendable, Equatable {
    case helloAck(appVersion: String)
    case config(blocklist: BlocklistConfig)
    case request(BridgeRequest)
    case ping
}
public struct TabContextResult: Codable, Sendable, Equatable { public var context: TabContext? }
public struct DrivePdfResult: Codable, Sendable, Equatable { public var fileId: String; public var title: String; public var byteLength: Int }
public struct ViewerPageResult: Codable, Sendable, Equatable { public var pageIndex: Int; public var pngBase64: String }
public struct EmptyResult: Codable, Sendable, Equatable { public init() }   // decodes from `{}` or `null`
public struct BinaryFrameHeader: Codable, Sendable, Equatable { public var id: String; public var seq: Int; public var last: Bool }
public enum BinaryFrame {
    public static func encode(header: BinaryFrameHeader, payload: Data) throws -> Data
    public static func decode(_ frame: Data) throws -> (header: BinaryFrameHeader, payload: Data)
}
```

`decodeResult` treats a missing or `null` `result` as JSON `null`; `EmptyResult` decodes from either `null` or `{}` (custom `init(from:)`).

**Wire format (fixed by the fixtures):** every JSON message is one WebSocket text frame: an object with `"v": 1`, a `"type"`, and the case's fields flattened into the same object — except `tabContext`, whose payload is under `"context"`, and `request`, which carries `"id"`, `"method"` and `"params"`. Decoding a message whose `v` ≠ 1 throws `BridgeError(code: .versionMismatch, …)`. Binary frames (PDF transfer only): 4-byte big-endian header length N, then N bytes of UTF-8 JSON `BinaryFrameHeader`, then the payload (≤ `maxChunkBytes`).

**Fixtures** — create exactly these files in `contracts/fixtures/` (prefix `ext-` = extension→app, `app-` = app→extension):

`ext-hello.json`
```json
{"v":1,"type":"hello","token":"0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0","extensionVersion":"0.1.0","browserName":"Dia"}
```
`ext-tabActivated.json`
```json
{"v":1,"type":"tabActivated","tabId":12,"windowId":3,"url":"https://www.youtube.com/watch?v=abc123XYZ00","title":"Solving Quadratics by Factoring - YouTube"}
```
`ext-tabContext-youtube.json`
```json
{"v":1,"type":"tabContext","context":{"tabId":12,"url":"https://www.youtube.com/watch?v=abc123XYZ00","title":"Solving Quadratics by Factoring - YouTube","capturedAtMs":1793558137000,"blocked":false,
 "youtube":{"videoId":"abc123XYZ00","title":"Solving Quadratics by Factoring","channel":"Math Channel","chapter":"Finding the roots","playheadSeconds":761,"durationSeconds":1450,"transcriptStatus":"available",
  "transcript":[{"start":575.0,"duration":6.2,"text":"so now we factor the left side"},{"start":740.5,"duration":5.0,"text":"x minus two times x minus three equals zero"},{"start":755.0,"duration":6.0,"text":"so x has to be two or three"}]}}}
```
`ext-tabContext-math.json`
```json
{"v":1,"type":"tabContext","context":{"tabId":21,"url":"https://example-homework.test/unit4/q3","title":"Unit 4 Quiz Review","capturedAtMs":1793558200000,"blocked":false,
 "page":{"url":"https://example-homework.test/unit4/q3","title":"Unit 4 Quiz Review","visibleText":"Question 3. Solve for x.","math":[{"format":"latex","source":"x^2-5x+6=0"},{"format":"mathml","source":"<math><mi>x</mi></math>"}]}}}
```
`ext-tabContext-classroom.json`
```json
{"v":1,"type":"tabContext","context":{"tabId":33,"url":"https://classroom.google.com/c/MTIz/a/NDU2/details","title":"Read 5.2 and do 1-15","capturedAtMs":1793558300000,"blocked":false,
 "page":{"url":"https://classroom.google.com/c/MTIz/a/NDU2/details","title":"Read 5.2 and do 1-15","visibleText":"Read pages 231-232 and do problems 1-15.","math":[]},
 "classroom":{"assignmentTitle":"Read 5.2 and do 1-15","attachments":[{"fileId":"1AbCdEfGhIjKlMnOpQrStUvWxYz012345","title":"Algebra 2 Textbook.pdf","mimeType":"application/pdf"},{"fileId":"1ZyXwVuTsRqPoNmLkJiHgFeDcBa987654","title":"Worksheet 5.2.pdf","mimeType":"application/pdf"}]}}}
```
`ext-tabContext-drive.json`
```json
{"v":1,"type":"tabContext","context":{"tabId":34,"url":"https://drive.google.com/file/d/1AbCdEfGhIjKlMnOpQrStUvWxYz012345/view","title":"Algebra 2 Textbook.pdf - Google Drive","capturedAtMs":1793558310000,"blocked":false,
 "drive":{"file":{"fileId":"1AbCdEfGhIjKlMnOpQrStUvWxYz012345","title":"Algebra 2 Textbook.pdf","mimeType":"application/pdf"}}}}
```
`ext-tabContext-blocked.json`
```json
{"v":1,"type":"tabContext","context":{"tabId":40,"url":"https://secure.chase.com/web/auth/dashboard","title":"","capturedAtMs":1793558400000,"blocked":true}}
```
`ext-youtubePlayhead.json`
```json
{"v":1,"type":"youtubePlayhead","tabId":12,"videoId":"abc123XYZ00","playheadSeconds":766.5,"chapter":"Finding the roots"}
```
`ext-tabClosed.json` — `{"v":1,"type":"tabClosed","tabId":12}`
`ext-progress.json` — `{"v":1,"type":"progress","id":"r-5","step":"Viewer page 240 of 412"}`
`ext-response-tabContext.json` — `{"v":1,"type":"response","id":"r-1","ok":true,"result":{"context":null}}`
`ext-response-drivePdf.json` — `{"v":1,"type":"response","id":"r-2","ok":true,"result":{"fileId":"1AbCdEfGhIjKlMnOpQrStUvWxYz012345","title":"Algebra 2 Textbook.pdf","byteLength":2097152}}`
`ext-response-downloadBlocked.json` — `{"v":1,"type":"response","id":"r-3","ok":false,"error":{"code":"downloadBlocked","message":"The owner has disabled downloads for this file."}}`
`ext-response-viewerInfo.json` — `{"v":1,"type":"response","id":"r-4","ok":true,"result":{"pageCount":412,"currentIndex":87}}`
`ext-response-viewerPage.json` — `{"v":1,"type":"response","id":"r-5","ok":true,"result":{"pageIndex":246,"pngBase64":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="}}`
`app-helloAck.json` — `{"v":1,"type":"helloAck","appVersion":"0.1.0"}`
`app-config.json` — `{"v":1,"type":"config","blocklist":{"bundleIDs":["com.1password.1password"],"domains":["chase.com","1password.com"]}}`
`app-request-getTabContext.json` — `{"v":1,"type":"request","id":"r-1","method":"getTabContext","params":{"tabId":null}}`
`app-request-fetchDrivePdf.json` — `{"v":1,"type":"request","id":"r-2","method":"fetchDrivePdf","params":{"fileId":"1AbCdEfGhIjKlMnOpQrStUvWxYz012345"}}`
`app-request-viewerInfo.json` — `{"v":1,"type":"request","id":"r-4","method":"viewerInfo","params":{"tabId":34}}`
`app-request-viewerCapturePage.json` — `{"v":1,"type":"request","id":"r-5","method":"viewerCapturePage","params":{"tabId":34,"pageIndex":246}}`
`app-request-viewerRestore.json` — `{"v":1,"type":"request","id":"r-6","method":"viewerRestore","params":{"tabId":34,"pageIndex":87}}`
`app-ping.json` — `{"v":1,"type":"ping"}`
`invalid-version.json` — `{"v":2,"type":"ping"}`

**`contracts/bridge-protocol.md`** documents, in prose: transport (`ws://127.0.0.1:<port>`, ports in order), handshake (extension sends `hello` first; app replies `helloAck` then `config`, or closes with code **4001** `unauthorized` for a wrong token / **4002** `versionMismatch`; no `hello` within 5 s → close 4001; **immediately after receiving `helloAck`, the extension sends `tabActivated` for the focused window's active tab followed by that tab's `tabContext`**, so a reconnect never leaves the app without an active tab), push messages (`tabActivated` on tab switch **and** browser-window focus; `tabContext` on load/navigation/debounced scroll and when a YouTube transcript becomes ready; `youtubePlayhead` every 5 s while playing and on seek; `tabClosed`), the blocked-site rule (extension sends `tabContext` with `blocked: true` and no content fields for any host matching `config.blocklist.domains`), requests and their result shapes, binary PDF transfer (zero or more binary frames with the request id, `seq` from 0, `last: true` on the final frame, then the JSON `response`), keep-alive (app sends `ping` every 20 s; no reply), and the error codes.

**`contracts/ts/protocol.ts`** exports TypeScript types mirroring every message, payload and result above **using the same names as the Swift types** (`TabContext`, `YouTubeContext`, `WebPageContext`, `DriveFileRef`, `ClassroomContext`, `DriveViewerContext`, `TranscriptSegment`, `MathSnippet`, `BlocklistConfig`, `ViewerInfo`, `TabContextResult`, `DrivePdfResult`, `ViewerPageResult`, `BridgeError`, `BinaryFrameHeader`, …); every message type includes `v: 1` and its literal `type` (optional Swift fields → `?: T | null`), the constants `PROTOCOL_VERSION = 1`, `PORTS = [47823, 47824, 47825, 47826, 47827]`, `MAX_CHUNK_BYTES = 1048576`, `PING_INTERVAL_MS = 20000`, `CLOSE_UNAUTHORIZED = 4001`, `CLOSE_VERSION_MISMATCH = 4002`, `HELLO_TIMEOUT_MS = 5000`, `STARTER_BLOCKED_DOMAINS` (exactly `BlocklistConfig.starter.domains`, same order), and union types `ExtensionToApp` / `AppToExtension` discriminated on `type`. No runtime code besides constants. `contracts/ts/tsconfig.json`: `strict`, `noEmit`, `target: ES2022`, `module: ESNext`, `moduleResolution: Bundler`, `resolveJsonModule: true`, `include: ["*.ts"]`.

- [ ] **Step 1: Write the failing tests** in `BridgeProtocolTests.swift`:

```swift
@Test func everyExtensionFixtureDecodesAndRoundTrips() throws {
    for name in try Fixtures.allBridgeFixtureNames() where name.hasPrefix("ext-") {
        let msg = try JSONDecoder().decode(ExtensionToApp.self, from: Fixtures.bridgeFixture(name))
        let again = try JSONDecoder().decode(ExtensionToApp.self, from: JSONEncoder().encode(msg))
        #expect(again == msg, "\(name)")
    }
}
@Test func everyAppFixtureDecodesAndRoundTrips() throws { /* same for "app-" with AppToExtension */ }
@Test func youtubeFixtureValues() throws {
    guard case .tabContext(let ctx) = try decodeExt("ext-tabContext-youtube.json") else { Issue.record("wrong case"); return }
    #expect(ctx.youtube?.playheadSeconds == 761)
    #expect(ctx.youtube?.transcript.count == 3)
    #expect(ctx.youtube?.transcriptStatus == .available)
}
@Test func blockedFixtureHasNoContent() throws { /* blocked == true, page/youtube/classroom/drive all nil */ }
@Test func requestFixtures() throws {
    #expect(try decodeApp("app-request-fetchDrivePdf.json") == .request(.fetchDrivePdf(id: "r-2", fileId: "1AbCdEfGhIjKlMnOpQrStUvWxYz012345")))
    #expect(try decodeApp("app-request-getTabContext.json") == .request(.getTabContext(id: "r-1", tabId: nil)))
}
@Test func responseResults() throws {
    guard case .response(let r) = try decodeExt("ext-response-viewerInfo.json") else { Issue.record("wrong case"); return }
    #expect(try r.decodeResult(ViewerInfo.self) == ViewerInfo(pageCount: 412, currentIndex: 87))
    guard case .response(let e) = try decodeExt("ext-response-downloadBlocked.json") else { Issue.record("wrong case"); return }
    #expect(e.ok == false && e.error?.code == .downloadBlocked)
}
@Test func emptyResultFromNull() throws {
    let r = BridgeResponse(id: "r-6", ok: true, result: nil, error: nil)
    #expect(try r.decodeResult(EmptyResult.self) == EmptyResult())
}
@Test func versionMismatchThrows() {
    #expect(throws: BridgeError.self) { try JSONDecoder().decode(AppToExtension.self, from: Fixtures.bridgeFixture("invalid-version.json")) }
}
@Test func binaryFrameRoundTrip() throws {
    let header = BinaryFrameHeader(id: "r-2", seq: 0, last: true)
    let frame = try BinaryFrame.encode(header: header, payload: Data([0x25, 0x50, 0x44, 0x46]))
    let headerLen = frame.prefix(4).reduce(0) { $0 << 8 | Int($1) }
    #expect(headerLen == frame.count - 4 - 4)
    let decoded = try BinaryFrame.decode(frame)
    #expect(decoded.header == header && decoded.payload == Data([0x25, 0x50, 0x44, 0x46]))
}
```
(`decodeExt`/`decodeApp` are file-private helpers that decode a named fixture.) These tests need `Fixtures` from Task 5 — write Task 5's `Fixtures` enum first if executing strictly in order, or temporarily inline a loader and switch to `Fixtures` in Task 5.

- [ ] **Step 2: Run** `swift test --filter CompanionCoreTests` → FAIL.
- [ ] **Step 3: Implement** `JSONValue.swift` and `Bridge.swift` (custom `Codable` producing/consuming exactly the fixture shapes), write the fixtures, `bridge-protocol.md`, and `contracts/ts/*`.
- [ ] **Step 4: Verify** — `swift test --filter CompanionCoreTests` → PASS; `npx -y -p typescript@5 tsc -p contracts/ts --noEmit` → exit 0.
- [ ] **Step 5: Commit** — `git commit -m "feat(contracts): bridge wire protocol, fixtures, TS mirror"`

---

### Task 5: Test support — fixture loader and fakes

**Files:**
- Create: `Sources/CompanionTestSupport/Fixtures.swift`, `Sources/CompanionTestSupport/Fakes.swift` (delete the placeholder)
- Test: `Tests/CompanionCoreTests/FakesTests.swift`

**Interfaces:**
- Produces:

```swift
public enum Fixtures {
    public static var contractsDirectory: URL { get }     // repo/contracts, resolved from #filePath
    public static func bridgeFixture(_ name: String) throws -> Data
    public static func allBridgeFixtureNames() throws -> [String]   // sorted *.json file names in contracts/fixtures
    public static func samplePNG(width: Int = 4, height: Int = 3) -> ImageAttachment   // real PNG bytes (ImageIO)
}
public final class FakeSecretStore: SecretStoring, @unchecked Sendable {   // NSLock-protected dictionary
    public init(_ initial: [String: String] = [:])
}
@MainActor public final class FakeSettingsStore: SettingsStoring {
    public init(_ settings: AppSettings = .default)        // update() notifies observers synchronously
}
public final class FakeLLMProvider: LLMProvider, @unchecked Sendable {
    public init(providerID: String = "fake", events: [LLMStreamEvent] = [.textDelta("Hello"), .finished(stopReason: "end_turn")],
                failure: (any Error)? = nil, delayPerEvent: Duration = .zero)
    public var requests: [LLMRequest] { get }               // every request received, in order
    public var prewarmCount: Int { get }
}
public actor FakeBrowserContextProvider: BrowserContextProviding {
    public init(cached: TabContext? = nil, fresh: TabContext? = nil, freshDelay: Duration = .zero, connected: Bool = true)
    public func setCached(_ context: TabContext?)
    public var requestCount: Int { get }
}
public actor FakeDocumentFetcher: DocumentFetching {
    public init(files: [String: (data: Data, title: String)] = [:], failure: BridgeError? = nil)
    public var requestedFileIDs: [String] { get }
}
public actor FakeViewerDriver: ViewerDriving {
    public init(info: ViewerInfo, page: @escaping @Sendable (Int) -> ImageAttachment)
    public var capturedIndices: [Int] { get }
    public var restoredIndex: Int? { get }
}
```
`FakeLLMProvider.stream` yields `events` (sleeping `delayPerEvent` between them), then finishes; if `failure` is set it throws it before yielding anything. `FakeBrowserContextProvider.requestActiveTabContext(timeout:)` sleeps `freshDelay`; returns `fresh` if `freshDelay < timeout`, else `nil`.

- [ ] **Step 1: Write the failing tests** — `Fixtures.allBridgeFixtureNames()` contains `"ext-hello.json"` and `"app-ping.json"` and has 24 entries (15 `ext-`, 8 `app-`, 1 `invalid-`); `samplePNG()` bytes start with `[0x89, 0x50, 0x4E, 0x47]` and `pixelWidth == 4`; `FakeLLMProvider` default yields `[.textDelta("Hello"), .finished(stopReason: "end_turn")]` and records the request; `FakeBrowserContextProvider(fresh: ctx, freshDelay: .milliseconds(500)).requestActiveTabContext(timeout: .milliseconds(300))` returns `nil`; `FakeSecretStore` set/get/delete.
- [ ] **Step 2: Run** `swift test --filter CompanionCoreTests` → FAIL.
- [ ] **Step 3: Implement** both files.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(test-support): fixture loader and fakes for all contracts"`

---

### Task 6: App target scaffold (XcodeGen) and signing

**Files:**
- Create: `project.yml`, `Config/Debug.xcconfig`, `Config/Release.xcconfig`, `Config/Signing.local.xcconfig.example`, `App/CompanionApp.swift`, `scripts/run-app.sh`

**Interfaces:**
- Produces: an Xcode scheme `Companion` building `Companion.app` (bundle id `dev.local.Companion`) that links every library product; `App/` is handed to WS7 after this task.

- [ ] **Step 1: Write `project.yml`** — project `Companion`; `options.deploymentTarget.macOS: "14.0"`; `packages: { Companion: { path: . } }`; `configFiles` Debug/Release → the xcconfigs; one target `Companion` (`type: application`, `platform: macOS`, `sources: [App]`), dependencies on package products `CompanionSession`, `CompanionUI`, `CompanionCore`, `CompanionLLM`, `CompanionBridge`, `CompanionCapture`, `CompanionPageFinder`; `info.path: App/Info.plist` with properties `LSUIElement: true`, `CFBundleDisplayName: Companion`, `CFBundleShortVersionString: "0.1.0"`, `CFBundleVersion: "1"`; `entitlements.path: App/Companion.entitlements` with `com.apple.security.app-sandbox: false`; settings `PRODUCT_BUNDLE_IDENTIFIER: dev.local.Companion`, `SWIFT_VERSION: "6.0"`, `CODE_SIGN_STYLE: Automatic`, `ENABLE_HARDENED_RUNTIME: NO`.
- [ ] **Step 2: Write the xcconfigs** — `Debug.xcconfig` and `Release.xcconfig` each contain `#include? "Signing.local.xcconfig"`. The example file contains `DEVELOPMENT_TEAM = YOUR_TEAM_ID` and `CODE_SIGN_IDENTITY = Apple Development` with a comment: "Copy to Signing.local.xcconfig. A stable signing identity keeps Screen Recording and Accessibility permissions across rebuilds."
- [ ] **Step 3: Write `App/CompanionApp.swift`** — `@main struct CompanionApp: App` with a `MenuBarExtra("Companion", systemImage: "sparkle")` containing `Text("Companion scaffold")` and a Quit button (`NSApp.terminate(nil)`).
- [ ] **Step 4: Write `scripts/run-app.sh`** (executable) — `xcodegen generate` then `xcodebuild -project Companion.xcodeproj -scheme Companion -configuration Debug -derivedDataPath .build/xcode build` then `open .build/xcode/Build/Products/Debug/Companion.app`.
- [ ] **Step 5: Verify** — `xcodegen generate && xcodebuild -project Companion.xcodeproj -scheme Companion -configuration Debug -derivedDataPath .build/xcode build` → `** BUILD SUCCEEDED **`. If Xcode refuses a local package at the project root, generate into a subfolder instead (`xcodegen generate --project Xcode`, and point `run-app.sh` at `Xcode/Companion.xcodeproj`); `.gitignore` already covers both.
- [ ] **Step 6: Manual check** — `scripts/run-app.sh`; a sparkle icon appears in the menu bar, no Dock icon; Quit works.
- [ ] **Step 7: Commit** — `git add project.yml Config App scripts/run-app.sh && git commit -m "chore(app): XcodeGen app target, signing config, run script"`

---

### Task 7: Freeze and hand off

- [ ] **Step 1:** Run `scripts/test-all.sh` → all green (extension step skipped: no `extension/` yet).
- [ ] **Step 2:** Merge to `main` (if on a branch) and tag: `git tag contracts-v1`.
- [ ] **Step 3:** Tell the human: "WS0 merged. Contracts frozen at `contracts-v1`. Wave 1 can start: `scripts/new-workstream.sh <id>` for ws1-llm, ws2-pagefinder, ws3-extension, ws4-bridge, ws5-capture, ws6-ui, ws7-integration."
