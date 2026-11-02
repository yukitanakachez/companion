# WS5 — Capture, Privacy Gate & Context Gathering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read `2026-11-01-companion-00-overview.md` (rules, global constraints, the `CompanionCapture (WS5)` API block) and the spec's §5.1, §5.3, §5.6 and §7 first. WS0 must be merged: you build on its frozen `CompanionCore` types and `CompanionTestSupport` fakes.

**Goal:** Build `CompanionCapture`: the privacy gate, front-window and region capture, the Accessibility reader, and the streaming `ContextGatherer` that turns one summon into a series of `CapturedContext` values.

**Architecture:** The rules live in pure, test-first cores (`PrivacyGate`, `TranscriptWindow`, `ContextAssembler`, geometry and window-matching helpers), tested against the real bridge fixtures. Platform work sits behind three internal protocols (`WindowCapturing`, `RegionCapturing`, `AccessibilityReading`) with ScreenCaptureKit/AX implementations. `ContextGatherer` orchestrates them: tests drive it with fakes, and `live(...)` wires in the real implementations.

**Tech Stack:** Swift 6.4 (language mode 6, strict concurrency), Swift Testing, ScreenCaptureKit (`SCShareableContent`, `SCContentFilter`, `SCScreenshotManager`), ApplicationServices (AX), AppKit (region overlay), ImageIO + UniformTypeIdentifiers (PNG), `os.OSAllocatedUnfairLock`.

**Spec:** `docs/superpowers/specs/2026-11-01-screen-companion-design.md`

## Global Constraints

- All of the overview's Global Constraints apply. Edit **only** `Sources/CompanionCapture/` and `Tests/CompanionCaptureTests/`. `CompanionCore` and `CompanionTestSupport` are frozen. If one of them can't express what a task needs, stop and report it with a proposed diff. Never duplicate a contract type.
- The public API is exactly the overview's `CompanionCapture (WS5)` block: `RegionSelection` (plus `public init(rect:displayID:)`), `GatherRequest`, `ContextGatherer.live(browser:blocklist:ownBundleID:)`, `ContextGatherer.gather(_:)` and `RegionSelector.select()`. Everything else is `internal`, and tests use `@testable import CompanionCapture`.
- Spec values: screenshot long edge **1500 px**, PNG, never upscaled. Transcript lookback **180 s**. Extension wait on the hot path **300 ms** (`BridgeConstants.hotPathTimeout`). Focused-element text cap **8,000** characters. Page text **20,000** characters and math **50** snippets, re-capped here defensively. AX messaging timeout **50 ms**. First emission target **< 50 ms**.
- Values WS5 chose (keep them in `CaptureConstants`): image capture limit **2 s**. AX tree walk limit of **150 elements** and **40 ms**. Window match accepted at IoU **≥ 0.5**. Minimum region **8 × 8 pt**. Region overlay dims the screen with **15 % black** at window level **`.screenSaver`**.
- Known browsers: `company.thebrowser.dia`, `com.google.Chrome`, `company.thebrowser.Browser`, `com.brave.Browser`, `com.microsoft.edgemac`, `com.apple.Safari`, `org.mozilla.firefox`. The first five are Chromium and can run the extension. Safari and Firefox never consult the extension.
- Privacy copy (exact): `"<appName> is on your blocklist"`, `"This site is on your blocklist"`.
- Never do any of these: capture pixels, read AX text or read the window title of a blocked app; read an `AXSecureTextField`; write captured images or text to disk; make AX or ScreenCaptureKit calls on the main actor; call ScreenCaptureKit without first checking `CGPreflightScreenCaptureAccess()`. Calling SCK without that check can trigger the system prompt on every summon. WS7 owns asking for permission.
- Concurrency: every protocol is `Sendable`. `SC*` and `AXUIElement` objects stay local to one function and are never stored or sent across actors. `@preconcurrency import ScreenCaptureKit` is allowed. `Synchronization.Mutex` needs macOS 15, so use `OSAllocatedUnfairLock`.
- Tests that need a permission use `.enabled(if: CGPreflightScreenCaptureAccess())` or `.enabled(if: AXIsProcessTrusted())`. Manual harnesses use `.enabled(if: ProcessInfo.processInfo.environment["COMPANION_MANUAL"] == "1")`. `swift test --filter CompanionCaptureTests` must pass on a machine with no permissions granted.

## Review Focus

1. **Extension not connected, its service worker asleep, or ignoring its own timeout** (overview Review Focus #3): gathering still finishes in under 500 ms with a screenshot, AX text and an "extension not connected" chip, and never waits on the provider past 300 ms. *Task 8 `extensionNotConnectedStillCompletesFast` and `stubbornExtensionIsAbandonedAtHotPathTimeout`; Task 7 `abandonsNonCooperativeOperation`.*
2. **Blocked app or site:** nothing is ever captured or emitted, including a site that only turns out to be blocked when the fresh tab arrives, and a region dragged over a blocklisted app sitting in the background. *Task 8 `blockedAppNeverCaptures` and `freshTabTurnsOutBlockedNeverEmitsCapture`; Task 2 `blockedContextCarriesOnlyTheNotice`; Task 4 `regionExclusionIncludesOwnAndBlockedApps`.*
3. **Multiple displays and negative coordinates** (a display left of or above the primary): the region crops the pixels that were selected, and the right window is matched. *Task 3 `pixelRectOnDisplayLeftOfPrimary`, `pixelRectOnDisplayAbovePrimary` and `flipForDisplayAbovePrimary`; Task 6 `dragRectOnNegativeXScreen`.*
4. **Screen Recording or Accessibility not granted:** no crash, no hang, and no system prompt on each summon. Gathering finishes without the missing pieces. *Task 4 `capturersThrowWithoutPermissionBeforeTouchingSCK`; Task 5 `untrustedReaderReturnsNilText`; Task 8 `missingPermissionsStillComplete`.*
5. **Nothing capturable** (window minimized or in another Space, an app with no windows, or our own app frontmost): text and tab context still arrive, and capture never picks our panel or a menu-bar strip. *Task 3 `matcherIgnoresOtherPidsAndLayers`; Task 5 `resolverSkipsOwnApp`; Task 8 `noCapturableWindowStillCompletesWithText`.*

---

### Task 1: Public types, constants, browsers and the privacy gate

**Files:**
- Delete: `Sources/CompanionCapture/CompanionCapture.swift`, `Tests/CompanionCaptureTests/PlaceholderTests.swift`
- Create: `Sources/CompanionCapture/PublicTypes.swift`, `Sources/CompanionCapture/CaptureConstants.swift`, `Sources/CompanionCapture/PrivacyGate.swift`
- Test: `Tests/CompanionCaptureTests/TestHelpers.swift`, `Tests/CompanionCaptureTests/PrivacyGateTests.swift`

**Interfaces:**
- Consumes: `FrontAppInfo`, `TabContext`, `BlocklistConfig` (`.starter`), `PrivacyDecision`, `ExtensionToApp`, `Fixtures.bridgeFixture(_:)`, `Fixtures.samplePNG()`.
- Produces:

```swift
public struct RegionSelection: Sendable, Equatable {
    public var rect: CGRect                 // global AppKit coordinates (bottom-left origin)
    public var displayID: CGDirectDisplayID
    public init(rect: CGRect, displayID: CGDirectDisplayID)
}
public enum GatherRequest: Sendable, Equatable { case frontWindow, region(RegionSelection) }

enum CaptureConstants {
    static let longEdgePixels = 1500, focusedTextCap = 8_000, pageTextCap = 20_000, mathCap = 50, axWalkMaxElements = 150
    static let transcriptLookback: Double = 180, axMessagingTimeout: Float = 0.05, minRegionSide: CGFloat = 8
    static let imageTimeout: Duration = .seconds(2), axWalkMaxDuration: Duration = .milliseconds(40)
}
enum KnownBrowsers {
    static let chromium: Set<String>, all: Set<String>   // chromium: dia, Chrome, Arc, Brave, Edge; all: chromium ∪ Safari, Firefox
    static func isBrowser(_ bundleID: String) -> Bool; static func usesExtension(_ bundleID: String) -> Bool
}
enum CaptureError: Error, Sendable, Equatable { case permissionDenied, noCapturableWindow, displayNotFound, encodingFailed }
enum PrivacyGate {
    static let siteBlockedReason = "This site is on your blocklist"
    static func evaluate(front: FrontAppInfo?, isBrowser: Bool, tab: TabContext?,
                         browserURL: URL?, config: BlocklistConfig) -> PrivacyDecision
    static func hostMatches(_ host: String, domain: String) -> Bool
}
// TestHelpers.swift (tests only, shared by every later task)
let dia, safari, preview, onePassword: FrontAppInfo   // pids 4242, 4343, 5151, 777; windowTitle/windowFrame nil
let img = Fixtures.samplePNG()
let siteBlocked = PrivacyDecision.blocked(reason: "This site is on your blocklist")
func tabFixture(_ name: String) throws -> TabContext  // decodes ExtensionToApp, unwraps .tabContext
func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint
func ev(_ front: FrontAppInfo?, browser: Bool, tab: TabContext? = nil, url: String? = nil,
        config: BlocklistConfig = .starter) -> PrivacyDecision            // PrivacyGate.evaluate shorthand
extension CapturedContext { var pieces: [ContextPiece]; var notices: [ContextNotice]; var chips: [String] }
```

- [ ] **Step 1: Write the failing tests** in `PrivacyGateTests.swift`

```swift
@Test func blockedBundleID() {
    #expect(ev(onePassword, browser: false) == .blocked(reason: "1Password is on your blocklist"))
    #expect(ev(FrontAppInfo(bundleID: "COM.1PASSWORD.1password", appName: "1Password", pid: 1, windowTitle: nil, windowFrame: nil),
               browser: false) != .allowed)                                              // case-insensitive
}
@Test func blockedTabFlagAloneBlocks() throws {                                          // even with an empty domain list
    #expect(ev(dia, browser: true, tab: try tabFixture("ext-tabContext-blocked.json"), config: BlocklistConfig(bundleIDs: [], domains: [])) == siteBlocked)
}
@Test func domainSuffixMatching() {
    #expect(PrivacyGate.hostMatches("secure.chase.com", domain: "chase.com") && PrivacyGate.hostMatches("chase.com", domain: "chase.com"))
    #expect(PrivacyGate.hostMatches("SECURE.Chase.COM.", domain: "chase.com"))          // lowercased, trailing dot ignored
    #expect(!PrivacyGate.hostMatches("notchase.com", domain: "chase.com") && !PrivacyGate.hostMatches("chase.com.evil.test", domain: "chase.com"))
}
@Test func browserURLUsedWhenNoTab() { #expect(ev(dia, browser: true, url: "https://www.paypal.com/myaccount") == siteBlocked) }
@Test func eitherHostMatchingBlocks() throws {        // tab says youtube, AX URL says chase → blocked (conservative)
    let yt = try tabFixture("ext-tabContext-youtube.json")
    #expect(ev(dia, browser: true, tab: yt, url: "https://chase.com") == siteBlocked && ev(dia, browser: true, tab: yt) == .allowed)
}
@Test func unknownSiteInBrowserIsUnchecked() throws {
    var noURL = try tabFixture("ext-tabContext-youtube.json"); noURL.url = ""
    #expect(ev(dia, browser: true) == .siteUnchecked && ev(dia, browser: true, tab: noURL) == .siteUnchecked)
}
@Test func nonBrowserAndUnknownFrontAreAllowed() { #expect(ev(preview, browser: false) == .allowed && ev(nil, browser: false) == .allowed) }
@Test func knownBrowsers() {
    #expect(KnownBrowsers.all.count == 7 && KnownBrowsers.chromium.count == 5)
    #expect(KnownBrowsers.usesExtension("company.thebrowser.dia") && !KnownBrowsers.usesExtension("com.apple.Safari"))
    #expect(KnownBrowsers.isBrowser("org.mozilla.firefox") && !KnownBrowsers.isBrowser("com.apple.Preview"))
}
@Test func specValues() {
    #expect(CaptureConstants.longEdgePixels == 1500 && CaptureConstants.transcriptLookback == 180)
    #expect(CaptureConstants.focusedTextCap == 8_000 && CaptureConstants.axMessagingTimeout == 0.05)
    #expect(BridgeConstants.hotPathTimeout == .milliseconds(300))
}
```

- [ ] **Step 2: Run to verify failure.** Run `swift test --filter CompanionCaptureTests`. Expected: FAIL with `cannot find 'PrivacyGate' in scope`.
- [ ] **Step 3: Implement** the three source files and `TestHelpers.swift`. `evaluate` checks rules in order and the first match wins:
  1. The bundle ID is in `config.bundleIDs` (case-insensitive) → `.blocked(reason: "\(appName) is on your blocklist")`.
  2. `isBrowser` and `tab?.blocked == true` → `.blocked(reason: "This site is on your blocklist")`.
  3. The host of `tab.url` **or** of `browserURL` matches any domain → `.blocked(reason: "This site is on your blocklist")`. Matching is `host == d || host.hasSuffix("." + d)` after lowercasing and stripping a trailing dot.
  4. `isBrowser` and neither host is known → `.siteUnchecked`.
  5. Otherwise → `.allowed`.

- [ ] **Step 4: Run to verify pass.** Run `swift test --filter CompanionCaptureTests`. Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git rm Sources/CompanionCapture/CompanionCapture.swift Tests/CompanionCaptureTests/PlaceholderTests.swift
git add Sources/CompanionCapture Tests/CompanionCaptureTests
git commit -m "feat(capture): public types, constants, known browsers, privacy gate"
```

---

### Task 2: Transcript window and context assembler

**Files:**
- Create: `Sources/CompanionCapture/TranscriptWindow.swift`, `Sources/CompanionCapture/ContextAssembler.swift`
- Test: `Tests/CompanionCaptureTests/TranscriptWindowTests.swift`, `Tests/CompanionCaptureTests/ContextAssemblerTests.swift`

**Interfaces:**
- Consumes: Task 1 (`CaptureConstants`, test helpers), `ContextItem`/`ContextPiece` chip labels, `CapturedContext`.
- Produces:

```swift
enum TranscriptWindow {
    /// Segments overlapping [max(0, playhead − lookback), playhead]: start <= to && start + duration > from.
    static func slice(segments: [TranscriptSegment], playhead: Double,
                      lookback: Double = CaptureConstants.transcriptLookback)
        -> (segments: [TranscriptSegment], from: Double, to: Double)
}
/// One UUID per item slot, created once per gather so chip ids stay stable across emissions.
struct ItemIDs: Sendable, Equatable {
    init()
    let image, youtube, transcript, webPage, math, selection, screenText: UUID
    let notices: [ContextNotice: UUID]          // one per ContextNotice case
}
struct SummonSnapshot: Sendable {   // synthesized memberwise init (declaration order); defaulted fields may be omitted
    var front: FrontAppInfo?; var privacy: PrivacyDecision; var isBrowser: Bool; var extensionConnected: Bool
    var windowImage: ImageAttachment? = nil; var regionImage: ImageAttachment? = nil
    var selectedText: String? = nil; var focusedText: String? = nil; var tab: TabContext? = nil
    var isComplete: Bool = false; var itemIDs = ItemIDs()
}
enum ContextAssembler { static func assemble(_ snapshot: SummonSnapshot) -> CapturedContext }
```

- [ ] **Step 1: Write the failing tests.** In the assembler tests, `snap(…)` means `SummonSnapshot(front: dia, privacy: .allowed, isBrowser: true, extensionConnected: true, windowImage: img, …)` with the listed overrides. One-line tests carry their assertions in the comment.

```swift
// TranscriptWindowTests.swift
@Test func fixtureWindowIncludesBoundaryOverlap() throws {              // 575.0 + 6.2 = 581.2 > 581
    let w = TranscriptWindow.slice(segments: try tabFixture("ext-tabContext-youtube.json").youtube!.transcript, playhead: 761)
    #expect(w.from == 581 && w.to == 761 && w.segments.count == 3)
}
@Test func segmentEndingExactlyAtWindowStartIsExcluded() {
    #expect(TranscriptWindow.slice(segments: [TranscriptSegment(start: 575, duration: 6, text: "a")], playhead: 761).segments.isEmpty)
}
@Test func startOfVideo() {
    let w = TranscriptWindow.slice(segments: [0, 30, 59.5, 60, 61].map { TranscriptSegment(start: $0, duration: 3, text: "t") }, playhead: 60)
    #expect(w.from == 0 && w.to == 60 && w.segments.map(\.start) == [0, 30, 59.5, 60])
}
@Test func emptyTranscript() {
    let w = TranscriptWindow.slice(segments: [], playhead: 761)
    #expect(w.segments.isEmpty && w.from == 581 && w.to == 761)
}

// ContextAssemblerTests.swift
@Test func youtubeTab() throws {
    let c = ContextAssembler.assemble(snap(tab: try tabFixture("ext-tabContext-youtube.json")))
    #expect(c.kind == .youtube && c.chips == ["window", "▶ 12:41 · Finding the roots", "transcript 9:41–12:41"])
}
@Test func mathTab() throws {}        // ext-tabContext-math → kind .mathPage; chips ["window", "page text", "math ×2"]
@Test func classroomTab() throws {}   // ext-tabContext-classroom → kind .webPage; chips ["window", "page text"] (empty math → no item)
@Test func blockedContextCarriesOnlyTheNotice() throws {
    let framed = FrontAppInfo(bundleID: dia.bundleID, appName: "Dia", pid: 4242, windowTitle: "Chase - Dashboard", windowFrame: R(0, 0, 800, 600))
    let c = ContextAssembler.assemble(snap(front: framed, privacy: siteBlocked, selectedText: "acct 1234", focusedText: "x",
                                           tab: try tabFixture("ext-tabContext-youtube.json")))
    #expect(c.pieces == [.notice(.contextOffForSite)] && c.kind == .genericWindow)   // site-blocked → "context off for this site"
    #expect(c.front?.bundleID == dia.bundleID && c.front?.windowTitle == nil && c.front?.windowFrame == nil)
}
@Test func regionWinsKindAndReplacesWindowImage() throws {}  // regionImage: img + youtube tab → kind .region, chips.first == "region", no "window"
@Test func noticesOrderAndRules() {}  // privacy .siteUnchecked, extensionConnected false → chips.suffix(2) == ["site not checked", "extension not connected"];
                                      // isBrowser false, extensionConnected false → no "extension not connected"
@Test func transcriptItemRules() throws {}  // youtube .unavailable (transcript []) → "no captions", no chip hasPrefix("transcript");
                                            // .loading → neither; .available with playhead 3000 (empty slice) → no transcript chip
@Test func textRules() {}  // focusedText 10_000 × "a" → .focusedText of 8_000 chars; focused == selected → only "selection";
                           // selectedText "  \n" → no "selection"; "selection" precedes "screen text"
@Test func pageCaps() throws {}  // visibleText "" → no "page text" but kind .webPage; 25_000 chars → 20_000; 60 snippets → "math ×50"
@Test func genericWindow() {}    // front preview, isBrowser false, no tab → kind .genericWindow, chips == ["window"]
@Test func idsStableAcrossEmissions() {
    let ids = ItemIDs()
    let a = ContextAssembler.assemble(snap(front: preview, isBrowser: false, itemIDs: ids))
    let b = ContextAssembler.assemble(snap(front: preview, isBrowser: false, selectedText: "s", itemIDs: ids))
    #expect(a.items[0].id == b.items[0].id && a.items[0].id == ids.image)
}
```

- [ ] **Step 2: Run to verify failure.** Run `swift test --filter CompanionCaptureTests`. Expected: FAIL with `cannot find 'ContextAssembler' in scope`.
- [ ] **Step 3: Implement.** `assemble` copies `front`, `privacy` and `isComplete`, and uses `itemIDs` for every item id.
  - **`.blocked`:** items are a single notice only — `notice(.contextOffForSite)` when the reason is `PrivacyGate.siteBlockedReason` ("This site is on your blocklist"), otherwise `notice(.contextOffForApp)`. `kind` is `.genericWindow`. `front` keeps only `bundleID`, `appName` and `pid`.
  - **Otherwise, items in this order:**
    1. `regionImage`, or else `windowImage`.
    2. `youtubeVideo(tab.youtube)`, unchanged. The full transcript stays inside it for WS1.
    3. `transcriptWindow`: only when the status is `.available` and the slice is non-empty.
    4. `webPage`: only when `page.visibleText` is non-empty after trimming. Cap `visibleText` at 20,000 characters.
    5. `math`: only when non-empty. Keep the first 50.
    6. `selectedText`: only when non-empty after trimming.
    7. `focusedText`: non-empty after trimming, truncated to 8,000 characters, and dropped when it equals `selectedText`.
    8. Notices in this order: `siteNotChecked` (privacy `.siteUnchecked`), `extensionNotConnected` (`isBrowser && !extensionConnected`), `noCaptions` (status `.unavailable`).
  - **`kind`:** `.region` if there is a region image; else `.youtube` if a youtube context exists; else `.mathPage` if math is non-empty; else `.webPage` if a page exists; else `.genericWindow`.

- [ ] **Step 4: Run to verify pass.** Run `swift test --filter CompanionCaptureTests`. Expected: PASS.
- [ ] **Step 5: Commit.** `git add Sources/CompanionCapture Tests/CompanionCaptureTests && git commit -m "feat(capture): transcript window and context assembler"`

---

### Task 3: Screen geometry, window matching and image encoding

**Files:**
- Create: `Sources/CompanionCapture/ScreenGeometry.swift`, `Sources/CompanionCapture/WindowMatcher.swift`, `Sources/CompanionCapture/ImageEncoding.swift`
- Test: `Tests/CompanionCaptureTests/ScreenGeometryTests.swift`, `Tests/CompanionCaptureTests/WindowMatcherTests.swift`, `Tests/CompanionCaptureTests/ImageEncodingTests.swift`

**Interfaces:**
- Consumes: `CaptureConstants`, `CaptureError` (Task 1), `ImageAttachment`.
- Produces:

```swift
enum ScreenGeometry {
    static func primaryDisplayHeight() -> CGFloat                       // CGDisplayBounds(CGMainDisplayID()).height
    /// AppKit global (bottom-left) ⇄ CG global (top-left); self-inverse: y' = H − y − h.
    static func flipped(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect
    static func fittedPixelSize(width: Int, height: Int,
                                longEdge: Int = CaptureConstants.longEdgePixels) -> (width: Int, height: Int)
    /// selection: AppKit global points. displayFrameCG: SCDisplay.frame (CG global points).
    /// Returns display-local, top-left-origin pixels, clamped to the display, integral.
    static func displayPixelRect(selection: CGRect, displayFrameCG: CGRect,
                                 primaryHeight: CGFloat, scale: CGFloat) -> CGRect
}
struct WindowCandidate: Sendable, Equatable { var windowID: CGWindowID; var pid: Int32; var layer: Int; var frame: CGRect }  // CG global
enum WindowMatcher {
    /// Only pid-owned, layer-0 windows. Best IoU with focusedFrame (CG global) if ≥ 0.5, else the largest area.
    static func pick(_ windows: [WindowCandidate], pid: Int32, focusedFrame: CGRect?) -> CGWindowID?
}
enum ImageEncoding {
    static func png(_ image: CGImage) throws -> Data            // ImageIO; throws CaptureError.encodingFailed
    static func downscaled(_ image: CGImage, longEdge: Int = CaptureConstants.longEdgePixels) throws -> CGImage  // same image if within
    static func attachment(_ image: CGImage) throws -> ImageAttachment
}
```

- [ ] **Step 1: Write the failing tests.** `px(sel, display, scale)` means `ScreenGeometry.displayPixelRect(selection: sel, displayFrameCG: display, primaryHeight: 982, scale: scale)`.

```swift
@Test func flipRoundTrip() {
    #expect(ScreenGeometry.flipped(R(100, 100, 800, 600), primaryHeight: 982) == R(100, 282, 800, 600))
    #expect(ScreenGeometry.flipped(ScreenGeometry.flipped(R(100, 100, 800, 600), primaryHeight: 982), primaryHeight: 982) == R(100, 100, 800, 600))
}
@Test func flipForDisplayAbovePrimary() { #expect(ScreenGeometry.flipped(R(200, 1100, 400, 300), primaryHeight: 982) == R(200, -418, 400, 300)) }
@Test func fittedSizes() {
    #expect(ScreenGeometry.fittedPixelSize(width: 3024, height: 1964) == (1500, 974))
    #expect(ScreenGeometry.fittedPixelSize(width: 1964, height: 3024) == (974, 1500))
    #expect(ScreenGeometry.fittedPixelSize(width: 800, height: 600) == (800, 600))       // never upscaled
    #expect(ScreenGeometry.fittedPixelSize(width: 4000, height: 1) == (1500, 1))         // min 1 px
}
@Test func pixelRectOnRetinaPrimary()        { #expect(px(R(100, 682, 200, 100), R(0, 0, 1512, 982), 2) == R(200, 400, 400, 200)) }
@Test func pixelRectOnDisplayLeftOfPrimary() { #expect(px(R(-1820, 782, 300, 100), R(-1920, 0, 1920, 1080), 1) == R(100, 100, 300, 100)) }
@Test func pixelRectOnDisplayAbovePrimary()  { #expect(px(R(10, 2322, 100, 50), R(0, -1440, 2560, 1440), 1) == R(10, 50, 100, 50)) }
@Test func pixelRectClampsToDisplay()        { #expect(px(R(1400, 682, 300, 100), R(0, 0, 1512, 982), 2) == R(2800, 400, 224, 200)) }

// WindowMatcherTests — w1 = (id 1, pid 42, layer 0, R(0, 25, 1200, 800)); w2 = (2, 42, 0, R(300, 200, 900, 700));
//                      other = (3, 7, 0, R(0, 0, 3000, 2000)); menu = (4, 42, 25, R(0, 0, 3000, 30))
@Test func picksBestOverlapWithFocusedFrame() { #expect(WindowMatcher.pick([w1, w2, other, menu], pid: 42, focusedFrame: w2.frame) == 2) }
@Test func fallsBackToLargest() {
    #expect(WindowMatcher.pick([w1, w2], pid: 42, focusedFrame: nil) == 1)
    #expect(WindowMatcher.pick([w1, w2], pid: 42, focusedFrame: R(5000, 5000, 10, 10)) == 1)     // no overlap
}
@Test func matcherIgnoresOtherPidsAndLayers() {
    #expect(WindowMatcher.pick([other, menu], pid: 42, focusedFrame: nil) == nil)
    #expect(WindowMatcher.pick([], pid: 42, focusedFrame: nil) == nil)
}

// ImageEncodingTests — makeImage(width:height:) fills a CGContext
@Test func downscalesAndEncodesPNG() throws {
    let a = try ImageEncoding.attachment(ImageEncoding.downscaled(makeImage(width: 3000, height: 2000)))
    #expect(Array(a.png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47] && a.pixelWidth == 1500 && a.pixelHeight == 1000)
    #expect(try ImageEncoding.downscaled(makeImage(width: 800, height: 600)).width == 800)
}
```

- [ ] **Step 2: Run to verify failure.** Run `swift test --filter CompanionCaptureTests`. Expected: FAIL with `cannot find 'ScreenGeometry' in scope`.
- [ ] **Step 3: Implement** the three files.
  - `fittedPixelSize`: `scale = min(1, longEdge / max(w, h))`, round each side to the nearest integer, minimum 1.
  - `displayPixelRect`: flip the selection to CG, subtract the display origin, intersect with the display's local bounds, multiply by `scale`, then apply `.integral`.
  - `downscaled`: draw into a device-RGB `CGContext` with `.high` interpolation.
  - `png`: use `CGImageDestinationCreateWithData` with `UTType.png`.

- [ ] **Step 4: Run to verify pass.** Run `swift test --filter CompanionCaptureTests`. Expected: PASS.
- [ ] **Step 5: Commit.** `git add Sources/CompanionCapture Tests/CompanionCaptureTests && git commit -m "feat(capture): screen geometry, window matching, PNG encoding"`

---

### Task 4: ScreenCaptureKit window and region capturers

**Files:**
- Create: `Sources/CompanionCapture/Capturing.swift`, `Sources/CompanionCapture/LiveWindowCapturer.swift`, `Sources/CompanionCapture/LiveRegionCapturer.swift`
- Test: `Tests/CompanionCaptureTests/LiveCaptureTests.swift`

**Interfaces:**
- Consumes: Task 3 (`ScreenGeometry`, `WindowMatcher`, `WindowCandidate`, `ImageEncoding`), `CaptureError`, `RegionSelection`, `BlocklistConfig`.
- Produces:

```swift
protocol WindowCapturing: Sendable {
    /// focusedFrame: the AX focused-window frame in AppKit global coordinates (nil → largest window).
    func captureFrontWindow(pid: Int32, focusedFrame: CGRect?) async throws -> ImageAttachment
}
protocol RegionCapturing: Sendable {
    func capture(_ selection: RegionSelection) async throws -> ImageAttachment
}
enum RegionExclusion {
    static func bundleIDsToExclude(running: [String], ownBundleID: String, config: BlocklistConfig) -> Set<String>
}
struct LiveWindowCapturer: WindowCapturing {
    init(hasPermission: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() })
}
struct LiveRegionCapturer: RegionCapturing {
    init(ownBundleID: String, blocklist: @escaping @Sendable () -> BlocklistConfig,
         hasPermission: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() })
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func capturersThrowWithoutPermissionBeforeTouchingSCK() async {
    await #expect(throws: CaptureError.permissionDenied) {
        try await LiveWindowCapturer(hasPermission: { false }).captureFrontWindow(pid: getpid(), focusedFrame: nil) }
    await #expect(throws: CaptureError.permissionDenied) {
        try await LiveRegionCapturer(ownBundleID: "x", blocklist: { .starter }, hasPermission: { false })
            .capture(RegionSelection(rect: R(0, 0, 50, 50), displayID: CGMainDisplayID())) }
}
@Test func regionExclusionIncludesOwnAndBlockedApps() {
    #expect(RegionExclusion.bundleIDsToExclude(running: ["dev.local.Companion", "com.1password.1password", "com.google.Chrome"],
                                               ownBundleID: "dev.local.Companion", config: .starter)
            == ["dev.local.Companion", "com.1password.1password"])
}
@Test(.enabled(if: CGPreflightScreenCaptureAccess())) func liveWindowCaptureProducesDownscaledPNG() async throws {}
    // capture any on-screen layer-0 SCWindow whose owner pid != getpid() (focusedFrame nil) → PNG signature,
    // max(pixelWidth, pixelHeight) <= 1500, aspect within 2% of the window frame's.
    // SCStreamError.userDeclined (a pending re-prompt) → return without failing
@Test(.enabled(if: CGPreflightScreenCaptureAccess())) func liveRegionCaptureOfMainDisplay() async throws {}
    // selection R(100, 100, 300, 200) on CGMainDisplayID() → PNG; abs(pixelWidth / pixelHeight − 1.5) < 0.02
```

- [ ] **Step 2: Run to verify failure.** Run `swift test --filter CompanionCaptureTests`. Expected: FAIL with `cannot find 'LiveWindowCapturer' in scope`.
- [ ] **Step 3: Implement**
  - **`LiveWindowCapturer`:**
    1. Check the permission; if it's missing, throw `.permissionDenied` before touching SCK.
    2. Call `SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)` and map the windows to `WindowCandidate` values (owner pid, `windowLayer`, `frame`).
    3. Call `WindowMatcher.pick` with `focusedFrame` flipped to CG. If nothing matches, throw `.noCapturableWindow`.
    4. Build `SCContentFilter(desktopIndependentWindow:)`. This naturally leaves out our panel and the glow.
    5. Configure `SCStreamConfiguration`: size it to `fittedPixelSize` of `filter.contentRect.size × filter.pointPixelScale`, and set `scalesToFit = true`, `preservesAspectRatio = true`, `showsCursor = false`, `ignoreShadowsSingleWindow = true`.
    6. Capture with `SCScreenshotManager.captureImage(contentFilter:configuration:)`, then `ImageEncoding.attachment`.
  - **`LiveRegionCapturer`:**
    1. Check the permission as above.
    2. Call `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)`.
    3. Find the `SCDisplay` whose `displayID` matches. If none does, throw `.displayNotFound`.
    4. Build `SCContentFilter(display:excludingApplications:exceptingWindows: [])`. The excluded apps are the `SCRunningApplication`s named by `RegionExclusion`, so our own windows and any blocklisted app's windows never appear in a region.
    5. Capture at native size (`display.width/height × filter.pointPixelScale`) with `showsCursor = false`.
    6. Call `cropping(to: displayPixelRect(…, displayFrameCG: display.frame, primaryHeight: primaryDisplayHeight(), scale: filter.pointPixelScale))`, then `downscaled`, then `attachment`. A crop failure throws `.encodingFailed`.

- [ ] **Step 4: Run to verify pass.** Run `swift test --filter CompanionCaptureTests`. Expected: PASS. The two live tests either pass or are reported as skipped when the machine lacks Screen Recording permission.
- [ ] **Step 5: Commit.** `git add Sources/CompanionCapture Tests/CompanionCaptureTests && git commit -m "feat(capture): ScreenCaptureKit window and region capturers"`

---

### Task 5: Accessibility reader

**Files:**
- Create: `Sources/CompanionCapture/AccessibilityReading.swift` (protocol and pure helpers), `Sources/CompanionCapture/LiveAccessibilityReader.swift`
- Test: `Tests/CompanionCaptureTests/AccessibilityTests.swift`

**Interfaces:**
- Consumes: `FrontAppInfo`, `ScreenGeometry.flipped` and `primaryDisplayHeight()`, `CaptureConstants` (AX timeout, walk limits).
- Produces:

```swift
struct FocusedWindowInfo: Sendable, Equatable { var title: String?; var frame: CGRect? }    // frame: AppKit global
protocol AccessibilityReading: Sendable {
    func frontApp() async -> FrontAppInfo?            // bundleID, appName, pid only (windowTitle/windowFrame nil); no AX needed
    func focusedWindow(pid: Int32) async -> FocusedWindowInfo?
    func selectedText(pid: Int32) async -> String?    // nil when empty or the focused element is secure
    func focusedText(pid: Int32) async -> String?     // AXValue of the focused element; nil for AXSecureTextField
    func browserURL(pid: Int32) async -> URL?         // AXWebArea "AXURL", else the toolbar address field
}
enum AXTextPolicy { static func isReadable(role: String?, subrole: String?) -> Bool }
enum BrowserURLParser { static func url(fromAddressField text: String) -> URL? }
enum AXTreeSearch {   // breadth-first; nil once maxVisited nodes were visited or the deadline passed
    static func firstMatch<Node>(root: Node, maxVisited: Int, deadline: ContinuousClock.Instant,
                                 children: (Node) -> [Node], descend: (Node) -> Bool,
                                 matches: (Node) -> Bool) -> Node?
}
enum FrontAppResolver {   // frontmost unless it is us/nil → first window owner (front-to-back) that isn't us
    static func resolve(frontmost: FrontAppInfo?, ownBundleID: String, windowOwners: () -> [FrontAppInfo]) -> FrontAppInfo?
}
struct LiveAccessibilityReader: AccessibilityReading {
    init(ownBundleID: String, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() })
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func secureFieldIsNeverRead() {
    #expect(!AXTextPolicy.isReadable(role: "AXTextField", subrole: "AXSecureTextField") && !AXTextPolicy.isReadable(role: nil, subrole: "AXSecureTextField"))
    #expect(AXTextPolicy.isReadable(role: "AXTextArea", subrole: nil) && AXTextPolicy.isReadable(role: "AXTextField", subrole: "AXSearchField"))
}
@Test func addressFieldParsing() {
    #expect(BrowserURLParser.url(fromAddressField: "secure.chase.com/web/auth/dashboard")?.host == "secure.chase.com")
    #expect(BrowserURLParser.url(fromAddressField: "https://www.youtube.com/watch?v=abc123XYZ00")?.host == "www.youtube.com")
    #expect(BrowserURLParser.url(fromAddressField: "chrome://newtab")?.host == "newtab")
    #expect(BrowserURLParser.url(fromAddressField: "localhost:3000")?.host == "localhost")
    #expect(BrowserURLParser.url(fromAddressField: "Search Google or type a URL") == nil && BrowserURLParser.url(fromAddressField: "") == nil)
}
@Test func treeSearchFindsWebAreaWithinBudget() {}
    // fake tree: window → [toolbar → 20 × tab, group → [group → [webArea]]]; matches role == "AXWebArea" → found;
    // maxVisited 5 → nil; descend { $0.role != "AXToolbar" } → ≤ 6 nodes visited; deadline .now − .seconds(1) → nil
@Test func resolverSkipsOwnApp() {
    var asked = false
    #expect(FrontAppResolver.resolve(frontmost: dia, ownBundleID: "dev.local.Companion", windowOwners: { asked = true; return [] }) == dia && !asked)
    let me = FrontAppInfo(bundleID: "dev.local.Companion", appName: "Companion", pid: 1, windowTitle: nil, windowFrame: nil)
    #expect(FrontAppResolver.resolve(frontmost: me, ownBundleID: me.bundleID, windowOwners: { [me, preview] }) == preview)
    #expect(FrontAppResolver.resolve(frontmost: nil, ownBundleID: me.bundleID, windowOwners: { [me] }) == nil)
}
@Test func untrustedReaderReturnsNilText() async {
    let r = LiveAccessibilityReader(ownBundleID: "x", isTrusted: { false })
    #expect(await r.focusedWindow(pid: getpid()) == nil)      // one await per #expect: `await` can't follow `&&`
    #expect(await r.selectedText(pid: getpid()) == nil)
    #expect(await r.focusedText(pid: getpid()) == nil)
    #expect(await r.browserURL(pid: getpid()) == nil)
}
@Test(.enabled(if: AXIsProcessTrusted())) func liveReaderAnswersQuicklyForFrontApp() async {}
    // front = await frontApp(); guard non-nil; the four pid calls together finish in < 500 ms
@Test(.enabled(if: ProcessInfo.processInfo.environment["COMPANION_MANUAL"] == "1")) func manualReadFrontApp() async throws {}
    // sleep 3 s (switch to Dia), then print frontApp, focusedWindow, selectedText, focusedText, browserURL
```

- [ ] **Step 2: Run to verify failure.** Run `swift test --filter CompanionCaptureTests`. Expected: FAIL with `cannot find 'AXTextPolicy' in scope`.
- [ ] **Step 3: Implement**
  - **`frontApp()`:** call `FrontAppResolver.resolve` with `NSWorkspace.shared.frontmostApplication`. Our non-activating bubble leaves the user's app frontmost. The `windowOwners` fallback lists on-screen layer-0 windows front to back from `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)`, looking each owner up with `NSRunningApplication(processIdentifier:)`. If the SDK marks `NSWorkspace` as main-actor-only, read it through `await MainActor.run`.
  - **The other four methods:** return `nil` when `isTrusted()` is false. Otherwise:
    - Call `AXUIElementSetMessagingTimeout(…, CaptureConstants.axMessagingTimeout)` on the system-wide element (once, in `init`) and on every `AXUIElementCreateApplication(pid)`.
    - **`focusedWindow`:** read `kAXFocusedWindowAttribute`, then title, position and size. Flip the CG frame to AppKit coordinates.
    - **`selectedText` and `focusedText`:** read `kAXFocusedUIElementAttribute`. Check `AXTextPolicy` against its role and subrole, then read `kAXSelectedTextAttribute` or `kAXValueAttribute` (strings only, empty → nil).
    - **`browserURL`:** run `AXTreeSearch` from the focused window to find `AXWebArea` and copy its `"AXURL"` attribute (a CFURL). If that fails, search again for an `AXTextField` or `AXComboBox` whose `AXValue` parses with `BrowserURLParser`, without descending into `AXWebArea`, so a page's own inputs are never mistaken for the address bar. Both passes share one budget of `axWalkMaxElements` and `axWalkMaxDuration`. The walk stops on the first `kAXErrorCannotComplete`.
    - Do not set `AXEnhancedUserInterface` or `AXManualAccessibility`. They change how the browser behaves. The address-field fallback covers browsers whose web content isn't exposed to AX yet.

- [ ] **Step 4: Run to verify pass.** Run `swift test --filter CompanionCaptureTests`. Expected: PASS, with the gated tests skipped where permission is missing. Then run `COMPANION_MANUAL=1 swift test --filter manualReadFrontApp` with Dia showing a YouTube page and some selected text. The printed URL host is `www.youtube.com` and the selection text matches. Repeat with the extension disconnected: the URL still prints, which confirms the address-field fallback.
- [ ] **Step 5: Commit.** `git add Sources/CompanionCapture Tests/CompanionCaptureTests && git commit -m "feat(capture): accessibility reader with secure-field skip and browser URL"`

---

### Task 6: Region selector overlay

**Files:**
- Create: `Sources/CompanionCapture/RegionSelector.swift`
- Test: `Tests/CompanionCaptureTests/RegionSelectorTests.swift`

**Interfaces:**
- Consumes: `RegionSelection`, `CaptureConstants.minRegionSide`, `LiveRegionCapturer` (only in the manual harness).
- Produces:

```swift
@MainActor public enum RegionSelector { public static func select() async -> RegionSelection? }   // nil on Esc
enum RegionDrag {   // nonisolated, pure: normalized, clamped to screenFrame, nil if either side < 8 pt
    static func rect(from start: CGPoint, to end: CGPoint, screenFrame: CGRect) -> CGRect?
}
```

- [ ] **Step 1: Write the failing tests** (`main = R(0, 0, 1512, 982)`)

```swift
@Test func dragNormalizesDirection() { #expect(RegionDrag.rect(from: P(100, 100), to: P(50, 40), screenFrame: main) == R(50, 40, 50, 60)) }
@Test func dragClampsToScreen()      { #expect(RegionDrag.rect(from: P(1400, 900), to: P(1700, 1100), screenFrame: main) == R(1400, 900, 112, 82)) }
@Test func tinyDragIsIgnored()       { #expect(RegionDrag.rect(from: P(0, 0), to: P(7, 20), screenFrame: main) == nil) }
@Test func dragRectOnNegativeXScreen() {
    #expect(RegionDrag.rect(from: P(-100, 500), to: P(-400, 300), screenFrame: R(-1920, 0, 1920, 1080)) == R(-400, 300, 300, 200))
}
```

- [ ] **Step 2: Run to verify failure.** Run `swift test --filter CompanionCaptureTests`. Expected: FAIL with `cannot find 'RegionDrag' in scope`.
- [ ] **Step 3: Implement `RegionSelector.select()`**
  - Create one `NSPanel` subclass per `NSScreen.screens` entry:
    - `styleMask: [.borderless, .nonactivatingPanel]` with `canBecomeKey` returning `true`. The panel takes Esc without activating our app, so the user's app stays frontmost for capture.
    - `level = .screenSaver`, `backgroundColor = .black.withAlphaComponent(0.15)`, `isOpaque = false`, `hasShadow = false`.
    - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, so the overlay also works over full-screen apps.
  - The content view sets `NSCursor.crosshair` and tracks the drag using `NSEvent.mouseLocation` (global AppKit coordinates). While dragging it draws the selection as a clear hole with a 1 pt white border.
  - On mouse-up, `RegionDrag.rect` decides the result. `nil` (too small) keeps the overlay up. A rect resolves `RegionSelection(rect:displayID:)`, where the display ID comes from `screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]`. Esc resolves `nil`.
  - Order out every panel before resuming the single `CheckedContinuation`. A call made while a selection is already open returns `nil` immediately.
  - If manual checks show the crosshair or Esc don't work without activation, fall back: call `NSApp.activate()` for the selection, re-activate the previously frontmost `NSRunningApplication` on close, and rely on `FrontAppResolver`'s own-app fallback.

- [ ] **Step 4: Run to verify pass, then check manually**
  - Run `swift test --filter CompanionCaptureTests`. Expected: PASS.
  - Add `@MainActor @Test(.enabled(if: COMPANION_MANUAL == "1")) func manualRegionSelection()`. It calls `NSApplication.shared.setActivationPolicy(.accessory)` and starts `Task { result = await RegionSelector.select() }`. Until that task finishes, it pumps `NSApp.nextEvent(matching: .any, until: +50 ms, inMode: .default, dequeue: true)` into `NSApp.sendEvent`, with `await Task.yield()` between batches. It then captures the result with `LiveRegionCapturer` and prints the selection and pixel size.
  - Run `COMPANION_MANUAL=1 swift test --filter manualRegionSelection` and check four things: (a) every display dims by about 15 % and shows a crosshair; (b) Esc returns `nil`; (c) a drag on a secondary display, including one left of the primary, prints that display's ID and a pixel size matching the drag × scale; (d) a drag over a visible 1Password window yields an image without its pixels.
  - If this harness can't deliver events inside the test process, write that down in the commit message so the same checks run at milestone M2 in the real app (WS7's end-to-end checklist).

- [ ] **Step 5: Commit.** `git add Sources/CompanionCapture Tests/CompanionCaptureTests && git commit -m "feat(capture): crosshair region selector"`

---

### Task 7: Time-limited waits and test doubles

**Files:**
- Create: `Sources/CompanionCapture/Deadline.swift`
- Test: `Tests/CompanionCaptureTests/DeadlineTests.swift`, `Tests/CompanionCaptureTests/TestDoubles.swift`

**Interfaces:**
- Consumes: the protocols from Tasks 4 and 5, `BrowserContextProviding`, `Fixtures.samplePNG()`.
- Produces:

```swift
/// The operation's value, or nil once `limit` elapses or the caller is cancelled. Never waits for a late
/// operation: it is cancelled and abandoned, so a callee that ignores cancellation cannot stall the caller.
func withTimeLimit<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async -> T?) async -> T?

// TestDoubles.swift — fakes sleep `delay` cooperatively, then count the call and record their arguments
func nonCooperativeSleep(_ seconds: Double) async        // DispatchQueue.global().asyncAfter + continuation; ignores cancellation
actor FakeWindowCapturer: WindowCapturing {
    init(result: Result<ImageAttachment, CaptureError> = .success(Fixtures.samplePNG()), delay: Duration = .zero)
    var calls: Int { get }; var lastFocusedFrame: CGRect? { get }
}
actor FakeRegionCapturer: RegionCapturing { /* same init */ var calls: Int { get }; var lastSelection: RegionSelection? { get } }
actor FakeAccessibilityReader: AccessibilityReading {
    init(front: FrontAppInfo?, window: FocusedWindowInfo? = FocusedWindowInfo(title: "Doc", frame: R(100, 100, 800, 600)),
         selected: String? = nil, focused: String? = nil, url: URL? = nil)
    var windowCalls: Int { get }; var textCalls: Int { get }; var urlCalls: Int { get }
}
final class StubbornBrowserProvider: BrowserContextProviding {   // connected, no cache; request ignores timeout + cancellation
    init(fresh: TabContext?, after seconds: Double = 1)
}
struct Collected { var emissions: [CapturedContext]; var firstAt: Duration; var finalAt: Duration; var final: CapturedContext }
func collect(_ stream: AsyncStream<CapturedContext>, since start: ContinuousClock.Instant) async -> Collected
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func returnsFastValue() async { #expect(await withTimeLimit(.milliseconds(300)) { 5 } == 5) }
@Test func abandonsNonCooperativeOperation() async {
    let start = ContinuousClock.now
    let v: Int? = await withTimeLimit(.milliseconds(100)) { await nonCooperativeSleep(1); return 1 }
    #expect(v == nil && ContinuousClock.now - start < .milliseconds(300))
}
@Test func callerCancellationReturnsNil() async {
    let start = ContinuousClock.now
    let t = Task { await withTimeLimit(.seconds(5)) { await nonCooperativeSleep(1); return 1 } }
    t.cancel()
    let v = await t.value
    #expect(v == nil && ContinuousClock.now - start < .milliseconds(300))
}
```

- [ ] **Step 2: Run to verify failure.** Run `swift test --filter CompanionCaptureTests`. Expected: FAIL with `cannot find 'withTimeLimit' in scope`.
- [ ] **Step 3: Implement `withTimeLimit`** and `TestDoubles.swift`. Resume one `CheckedContinuation` exactly once, guarded by `OSAllocatedUnfairLock<Bool>`. Whichever of two unstructured `Task`s finishes first resumes it: the operation, or `Task.sleep(for: limit)` resuming with `nil`. Then cancel the other task. Wrap the whole thing in `withTaskCancellationHandler` so that cancelling the caller resumes with `nil`. Do **not** use `withTaskGroup`, because it waits for cancelled children.
- [ ] **Step 4: Run to verify pass.** Run `swift test --filter CompanionCaptureTests`. Expected: PASS.
- [ ] **Step 5: Commit.** `git add Sources/CompanionCapture Tests/CompanionCaptureTests && git commit -m "feat(capture): time-limited waits and capture test doubles"`

---

### Task 8: ContextGatherer

**Files:**
- Create: `Sources/CompanionCapture/ContextGatherer.swift`
- Test: `Tests/CompanionCaptureTests/ContextGathererTests.swift`

**Interfaces:**
- Consumes: everything above, plus `FakeBrowserContextProvider`, `BridgeConstants.hotPathTimeout` and `BlocklistConfig.starter`.
- Produces (public names exactly as in the overview):

```swift
public actor ContextGatherer {
    public static func live(browser: any BrowserContextProviding,
                            blocklist: @escaping @Sendable () -> BlocklistConfig,
                            ownBundleID: String) -> ContextGatherer
    /// First element within 50 ms (front app + privacy decision); emits again as each piece lands;
    /// the final element is complete. Finishes after the final element.
    public func gather(_ request: GatherRequest) -> AsyncStream<CapturedContext>
    init(accessibility: any AccessibilityReading, windowCapturer: any WindowCapturing,
         regionCapturer: any RegionCapturing, browser: any BrowserContextProviding,
         blocklist: @escaping @Sendable () -> BlocklistConfig,
         browserWait: Duration = BridgeConstants.hotPathTimeout,
         imageTimeout: Duration = CaptureConstants.imageTimeout)
}
```

- [ ] **Step 1: Write the failing tests**
  - The gatherer is built from the listed fakes with `blocklist: { .starter }`. Unless a test says otherwise, `ax = FakeAccessibilityReader(front: dia)`, `window = FakeWindowCapturer()` and `browser = FakeBrowserContextProvider()`.
  - `r = await collect(await g.gather(.frontWindow), since: start)`.
  - Every test also checks that exactly one emission is complete and that it comes last.

```swift
@Test func extensionNotConnectedStillCompletesFast() async throws {          // Review Focus #3 (overview)
    let browser = FakeBrowserContextProvider(cached: nil, fresh: try tabFixture("ext-tabContext-youtube.json"),
                                             freshDelay: .seconds(1), connected: false)
    // … build g with ax (front dia, url nil) and a succeeding window capturer; collect r
    #expect(r.finalAt < .milliseconds(500) && r.final.isComplete)
    #expect(r.final.pieces.contains { if case .windowImage = $0 { true } else { false } })
    #expect(r.final.notices.contains(.extensionNotConnected))
    #expect(!r.final.chips.contains { $0.hasPrefix("▶") || $0.hasPrefix("transcript") })
    #expect(await browser.requestCount == 0)                                  // not connected → never asked
}
@Test func stubbornExtensionIsAbandonedAtHotPathTimeout() async throws {}  // StubbornBrowserProvider(fresh: youtube, after: 1) → finalAt < 500 ms,
                                                                          // windowImage present, notices == [.siteNotChecked], no "▶"/"transcript" chips
@Test func cachedTabSkipsRequestAndAXURL() async throws {}   // cached: youtube → emissions[0].kind == .youtube, its chips contain "▶ 12:41 · Finding the roots";
                                                             // browser.requestCount == 0; ax.urlCalls == 0
@Test func freshTabWithinWaitIsUsed() async throws {}        // cached nil, fresh youtube, freshDelay 100 ms → final.kind == .youtube, no .siteNotChecked
@Test func blockedAppNeverCaptures() async {}   // ax front onePassword; for both .frontWindow and .region(sel): every emission's pieces ==
    // [.notice(.contextOffForApp)], final.privacy == .blocked(reason: "1Password is on your blocklist");
    // window.calls, region.calls, ax.windowCalls, ax.textCalls, ax.urlCalls, browser.requestCount all == 0
@Test func blockedSiteFromCachedTabOrAXURLNeverCaptures() async throws {}  // (a) cached = ext-tabContext-blocked.json;
    // (b) cached nil, connected false, ax url https://secure.chase.com/x → both: final.pieces == [.notice(.contextOffForSite)], window.calls == 0
@Test func freshTabTurnsOutBlockedNeverEmitsCapture() async throws {}  // cached nil, fresh = blocked fixture after 100 ms, ax url nil, selected "acct"
    // → no emission contains .windowImage/.regionImage/.selectedText/.focusedText; final.privacy == siteBlocked; final.front?.windowTitle == nil
@Test func slowCapturerDoesNotDelayFirstEmission() async {}  // ax front preview, window delay 400 ms → firstAt < 100 ms (target 50),
    // emissions[0].isComplete == false and has no image; final has windowImage
@Test func imageTimeoutDropsImage() async {}                // window delay 5 s, imageTimeout 200 ms → finalAt < 1 s, complete, no image
@Test func regionRequestUsesRegionCapturer() async {}       // .region(RegionSelection(rect: R(10, 10, 300, 200), displayID: 1)) → region.calls == 1,
    // region.lastSelection == sel, window.calls == 0, final.kind == .region, final.chips.first == "region"
@Test func windowFrameFlowsToCapturer() async {}            // window.lastFocusedFrame == R(100, 100, 800, 600) == final.front?.windowFrame;
                                                            // final.front?.windowTitle == "Doc"
@Test func noCapturableWindowStillCompletesWithText() async {}  // window .failure(.noCapturableWindow), selected "x^2", front preview
                                                                // → final complete, chips == ["selection"]
@Test func missingPermissionsStillComplete() async {}      // window .failure(.permissionDenied), texts nil, front preview → finalAt < 500 ms,
                                                           // kind .genericWindow, items empty
@Test func nonChromiumBrowserNeverConsultsExtension() async throws {}  // front safari, cached youtube → no "▶" chip, requestCount == 0,
                                                                       // ax.urlCalls == 1, notices contain .extensionNotConnected
@Test func unknownFrontApp() async {}                      // ax front nil → final complete, privacy .allowed, window.calls == 0, kind .genericWindow
@Test(.enabled(if: CGPreflightScreenCaptureAccess() && AXIsProcessTrusted())) func liveGatherCompletes() async {}
    // ContextGatherer.live(browser: FakeBrowserContextProvider(connected: false), blocklist: { .starter },
    //                      ownBundleID: "dev.local.Companion.tests") → final complete within 2 s, front != nil
```

- [ ] **Step 2: Run to verify failure.** Run `swift test --filter CompanionCaptureTests`. Expected: FAIL with `cannot find 'ContextGatherer' in scope`.
- [ ] **Step 3: Implement.** `gather` creates `AsyncStream.makeStream(of: CapturedContext.self)` and starts one `Task` running a nonisolated `static func run(…)` that captures only Sendable dependencies. It sets `onTermination` to cancel that task and returns the stream. `run` creates one `ItemIDs` per gather and works through these steps:
  1. **Front app and config.** `front = await ax.frontApp()`, `config = blocklist()`, `isBrowser = KnownBrowsers.isBrowser(front.bundleID)`.
  2. **Bundle check.** If `PrivacyGate.evaluate(front:isBrowser:tab: nil, browserURL: nil, config:)` is `.blocked`, emit the blocked snapshot with `isComplete` false, emit it again with `isComplete` true, and finish. Nothing else is called.
  3. **Extension state.** If `KnownBrowsers.usesExtension`, read `connected = await browser.isConnected()` and `tab = await browser.cachedActiveTabContext()`. Safari and Firefox never consult the extension, so they get `connected = false` and `tab = nil`.
  4. **Address bar.** If it's a browser and `tab == nil`, `url = await ax.browserURL(pid:)`.
  5. **First emission.** `privacy = PrivacyGate.evaluate(…tab, url…)`. If it's `.blocked`, finish as in step 2. Otherwise emit the first element with `isComplete` false.
  6. **Window details.** If `front` exists, `await ax.focusedWindow(pid:)` and fold its title and frame into `snapshot.front`.
  7. **Concurrent pieces.** Set `awaitingTab = usesExtension && connected && tab == nil`. Run a task group with three kinds of child:
     - Image: `withTimeLimit(imageTimeout)` around the window capturer (with the focused frame), or the region capturer for `.region`. Errors become `nil`.
     - Text: `selectedText` and `focusedText`.
     - Fresh tab, only when `awaitingTab`: `withTimeLimit(browserWait) { await browser.requestActiveTabContext(timeout: browserWait) }`.
     When `front` is nil there's no pid, so skip the window capture and the text reads. A region is still captured.
  8. **Folding results.** Fold each result into the snapshot as it lands.
     - A fresh-tab result clears `awaitingTab` and re-evaluates privacy using the tab and step 4's `url`. If that is `.blocked`, call `group.cancelAll()`, emit the blocked-only context as complete, and finish.
     - After each landing, emit `assemble(snapshot)` unless `awaitingTab` is set. Image and text are held for at most 300 ms until the tab question settles, so a late "blocked" never follows a capture that was already emitted.
  9. **Final emission.** Once the group drains, set `isComplete = true`, emit, and finish.

  `live(...)` wires up `LiveAccessibilityReader(ownBundleID:)`, `LiveWindowCapturer()` and `LiveRegionCapturer(ownBundleID:blocklist:)`, and keeps the default waits.

- [ ] **Step 4: Run to verify pass.** Run `swift test --filter CompanionCaptureTests`. Expected: PASS, with the gated tests skipped where permissions are missing. Then run `swift build --target CompanionCapture 2>&1 | grep "Sources/CompanionCapture" | grep -c "warning:"`. Expected: `0`, meaning no strict-concurrency warnings.
- [ ] **Step 5: Commit.** `git add Sources/CompanionCapture Tests/CompanionCaptureTests && git commit -m "feat(capture): streaming ContextGatherer with privacy-first pipeline"`
