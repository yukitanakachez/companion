# WS7 — Session Integration & App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read `2026-11-01-companion-00-overview.md` (rules, global constraints, cross-workstream APIs) and the spec first.

**Goal:** Turn the six libraries into one app: a `SummonCoordinator` that drives the bubble from hotkey to streamed answer (context, page finder, errors, follow-ups), the small session services around it, the composition root in `App/`, and the v1 end-to-end checklist.

**Architecture:** `CompanionSession` owns all behaviour; `App/` only builds objects and wires callbacks. The coordinator reaches other modules through module-internal seam protocols (`BubblePresenting`, `ProviderResolving`, `PermissionChecking`, `GlowFlashing`, `ContextGathering`, `RegionSelecting`, `PageFinding`). The real types adopt them by extension inside `CompanionSession`, and tests use `@testable import CompanionSession` with fakes. Tasks 1–5 import only `CompanionCore` and run in Wave 1. Tasks 6–11 are gated, and each seam is declared in the first task whose gate makes its types importable, so every commit compiles.

**Tech Stack:** Swift 6.4 (language mode 6), Swift Testing, AppKit + SwiftUI `MenuBarExtra`, `os` (`OSSignposter`, `Logger`, `OSAllocatedUnfairLock`), CoreGraphics/ApplicationServices permission APIs, XcodeGen app target (frozen `project.yml`).

**Spec:** `docs/superpowers/specs/2026-11-01-screen-companion-design.md` (§5.1, §5.2, §5.5, §5.7, §7, §8 matter most here)

| Task | Gate (merged into `main`) | Milestone |
|---|---|---|
| 1–5 ConversationStore, LatencyTrace, settings store, permissions, error copy | none (Core only) | — |
| 6 SummonCoordinator core | WS1, WS6 | — |
| 7 App shell | WS1, WS6 | **M1** (with 6) |
| 8 Screen context + region | WS1, WS5, WS6 | **M2** |
| 9 Page-finder flow | WS1, WS2, WS6 (may run before 8) | — |
| 10 Full composition | WS1–WS6 | **M3, M4** |
| 11 End-to-end verification | WS1–WS6 + WS3, Tasks 1–10 | v1 sign-off |

## Global Constraints

All of the overview's Global Constraints apply. In addition:

- Owned paths: `Sources/CompanionSession/`, `Tests/CompanionSessionTests/`, `App/` (sources only; `project.yml` is frozen and already links every library product), `docs/superpowers/verification/`.
- Commands: `swift test --filter CompanionSessionTests`; app: `scripts/run-app.sh` (look for `** BUILD SUCCEEDED **`, then the app launches). `swift build` must be green at every commit.
- **Gates:** before a gated task, run `git fetch && git rebase main`, then confirm that `git log --oneline --merges main` lists each required `ws/<id>` branch. If a gate is still closed, stop and tell the human. Never stub or copy another workstream's types.
- Conversation resume window **600 s**: `now − lastInteraction ≤ 600` resumes.
- Summon placement: window summons call `show(cursor: NSEvent.mouseLocation, avoiding: nil)` — no contract carries the focal area (e.g. the video player's frame) in v1, so the bubble simply opens right-below the cursor (see the overview's known limitations). Region capture passes the selection rect, and WS6's placement moves the bubble beside it.
- Latency: ring buffer of the last **20** summons; summary copy is pinned in Task 2. Budgets: hotkey→typing **p95 < 100 ms target, < 800 ms hard**; submit→first token **median ≤ 1.5 s** on Haiku 4.5. Before `show()` returns, `summon()` does only cheap in-memory resets. Keychain reads, prewarm, permission checks and gathering all run after it.
- Settings: JSON of `AppSettings` in `UserDefaults` under key **`settings.v1`**. Own bundle id given to the gatherer: **`dev.local.Companion`**.
- `SummonCoordinator` and everything touching AppKit is `@MainActor`. Seams used off the main actor are `Sendable`.
- All user-visible copy in this plan is exact (tests pin it). Curly quotes `“ ”` and the ellipsis `…` are single characters.

## Review Focus

1. **First run with no API key and/or no Screen Recording/Accessibility.** The bubble shows instantly and a banner says exactly what is missing. Its Settings button opens the right place: app Settings for a key, the System Settings privacy pane for a permission. Once a key exists, asking works, even without Screen Recording. Never a hang or a crash. *Task 6 `firstRunWithoutKeyOrPermissions`.*
2. **⌥Space while the bubble is open or mid-answer.** The existing bubble gets focus. There is no second `show`, no new gather and no new trace record, and the stream finishes. *Task 6 `doubleSummonMidAnswerFocusesOnly`, Task 8 `doubleSummonDoesNotRegather`.*
3. **Settings changed while an answer streams** (routing, cycle, base URL, blocklist). The in-flight answer finishes on the model it started with, and the next question uses the new settings. The blocklist reaches background readers without a restart. *Task 3 `mirrorTracksUpdatesSynchronously`, Task 6 `settingsChangeMidStreamAffectsNextQuestionOnly`.*
4. **⌥Space or ⌥⇧Space pressed while the region crosshair is up.** Both are ignored: no bubble over the overlay and no second overlay. Esc on the overlay leaves everything as it was. *Task 8 `hotkeysIgnoredDuringRegionSelection`.*
5. **Quit while a PDF is mid-transfer or an answer is streaming.** The app quits within about 2 s and the stream is cancelled. The PDF cache is still cleared even if `bridge.stop()` hangs. *Task 10 `hangingStepDoesNotBlockLaterSteps`.*

---

### Task 1: ConversationStore

**Files:**
- Create: `Sources/CompanionSession/ConversationStore.swift`, `Tests/CompanionSessionTests/TestClock.swift`
- Delete: `Sources/CompanionSession/CompanionSession.swift`, `Tests/CompanionSessionTests/PlaceholderTests.swift` (WS0 placeholders)
- Test: `Tests/CompanionSessionTests/ConversationStoreTests.swift`

**Interfaces:**
- Consumes: `LLMMessage`, `LLMContent` (Core).
- Produces:
```swift
public struct ConversationStore: Sendable {
    public struct Turn: Sendable, Equatable { public var question: String; public var userMessage: LLMMessage; public var answer: String }
    public static let resumeWindow: TimeInterval = 600
    public init(now: @escaping @Sendable () -> Date = Date.init)
    public private(set) var turns: [Turn]
    public private(set) var lastInteraction: Date?
    public var messages: [LLMMessage] { get }    // per turn: userMessage, then LLMMessage(role: .assistant, content: [.text(answer)])
    public mutating func beginSummon() -> Bool    // true = resumed; false also clears turns. Does not touch.
    public mutating func appendTurn(question: String, userMessage: LLMMessage, answer: String)   // also touches
    public mutating func touch()                  // lastInteraction = now()  (submit, stream end, close)
    public mutating func reset()                  // turns = [], lastInteraction = nil
}
```
A turn is stored only once its answer exists, so user and assistant messages always alternate. Both adapters require this. That is why this plan uses `appendTurn` where the brief had `appendUser`/`appendAssistant`.
- Test helper: `final class TestClock: @unchecked Sendable`. It holds an NSLock-guarded `now: Date` that starts at `Date(timeIntervalSince1970: 1_800_000_000)`, plus `advance(_ seconds: TimeInterval)` and `var read: @Sendable () -> Date`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func resumesAt599Seconds() {
    let clock = TestClock(); var store = ConversationStore(now: clock.read)
    #expect(store.beginSummon() == false)                         // nothing to resume yet
    let q1 = LLMMessage(role: .user, content: [.text("q1 + context")])
    store.appendTurn(question: "q1", userMessage: q1, answer: "a1")
    clock.advance(599)
    #expect(store.beginSummon() == true)
    #expect(store.messages == [q1, LLMMessage(role: .assistant, content: [.text("a1")])])
}
@Test func resumesAtExactly600Seconds()   // advance(600) → beginSummon() == true
@Test func freshAt601Seconds()            // advance(601) → false; turns.isEmpty; messages.isEmpty
@Test func touchExtendsTheWindow()        // appendTurn; advance(500); touch(); advance(500) → true
@Test func resetClears()                  // reset() → turns.isEmpty, lastInteraction == nil, beginSummon() == false
```

- [ ] **Step 2: Run** `swift test --filter CompanionSessionTests` → FAIL (`ConversationStore` not defined).
- [ ] **Step 3: Implement `ConversationStore`.** `beginSummon()` resumes iff `!turns.isEmpty`, `lastInteraction != nil` and `now() − lastInteraction ≤ 600`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `git add -A Sources/CompanionSession Tests/CompanionSessionTests && git commit -m "feat(session): conversation store with 10-minute resume"`

---

### Task 2: LatencyTrace

**Files:**
- Create: `Sources/CompanionSession/LatencyTrace.swift`
- Test: `Tests/CompanionSessionTests/LatencyTraceTests.swift` (also holds the `ManualClock` helper)

**Interfaces:**
- Produces:
```swift
public enum LatencyMark: String, CaseIterable, Sendable {
    case hotkey, panelVisible, inputReady, contextFirst, contextComplete, submit, firstToken, finished
}
public struct SummonTiming: Sendable, Equatable { public var offsets: [LatencyMark: Duration] }   // relative to .hotkey (= .zero)
@MainActor public final class LatencyTrace {
    public static let capacity = 20
    public init(now: @escaping @MainActor () -> ContinuousClock.Instant = { .now })
    public private(set) var records: [SummonTiming]   // oldest first, ≤ 20; the last one is the current summon
    public func begin()                    // appends a record with .hotkey = .zero; drops the oldest beyond 20
    public func mark(_ mark: LatencyMark)  // first mark of each kind per record wins; ignored before any begin()
    public var summaryText: String { get }
}
```
- Test helper: `@MainActor final class ManualClock` with a fixed base `ContinuousClock.now`, `advance(_ d: Duration)` and `var read: @MainActor () -> ContinuousClock.Instant`.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor @Test func summaryTextFormat() {
    let clock = ManualClock(); let trace = LatencyTrace(now: clock.read)
    let typingMs = Array(repeating: 5000, count: 5)              // evicted by the 20-slot ring
                 + Array(repeating: 30, count: 9) + [42] + Array(repeating: 50, count: 8) + [70, 90]
    for ms in typingMs {
        trace.begin(); clock.advance(.milliseconds(ms)); trace.mark(.inputReady)
        trace.mark(.submit); clock.advance(.milliseconds(1200)); trace.mark(.firstToken)
    }
    #expect(trace.records.count == 20)
    #expect(trace.summaryText == "Last 20 summons — hotkey→typing median 42 ms, p95 70 ms · submit→first token median 1.2 s")
}
@MainActor @Test func firstMarkWinsAndOffsetsAreRelative()
    // begin; +10 ms mark(.panelVisible); +5 ms mark(.panelVisible)
    // → records[0].offsets[.panelVisible] == .milliseconds(10); offsets[.hotkey] == .zero
@MainActor @Test func markBeforeBeginIsIgnored()   // mark(.submit) → records.isEmpty
@MainActor @Test func summaryWithMissingData() {
    // no records → "No summons recorded yet."
    // one summon, inputReady at 40 ms, no submit →
    //   "Last 1 summon — hotkey→typing median 40 ms, p95 40 ms · submit→first token —"
}
```

- [ ] **Step 2: Run** `swift test --filter CompanionSessionTests` → FAIL.
- [ ] **Step 3: Implement `LatencyTrace`.** Metrics: hotkey→typing = `inputReady − hotkey`, submit→first token = `firstToken − submit`. Records missing either mark are skipped for that metric, and a metric with no samples prints as `<name> —`.
  - Percentiles: nearest rank with integer maths on the sorted samples, `index = max(0, (n * pct + 99) / 100 - 1)` for `pct` 50 and 95. This avoids `0.95 * 20` floating-point drift.
  - Formatting: under 1 s → `"\(Int(ms.rounded())) ms"`; otherwise `String(format: "%.1f s", seconds)`. "summon" when the count is 1, else "summons".
  - Instrumentation: `OSSignposter(subsystem: "dev.local.Companion", category: "summon")`. `begin()` calls `beginInterval("summon")` and ends any open interval. Each accepted mark emits `emitEvent("mark", "\(mark.rawValue, privacy: .public)")`. `.finished` calls `endInterval` and logs both metrics with `Logger(subsystem: "dev.local.Companion", category: "latency")` at `.info`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `feat(session): latency trace with signposts and 20-summon summary`

---

### Task 3: UserDefaultsSettingsStore and SettingsMirror

**Files:**
- Create: `Sources/CompanionSession/UserDefaultsSettingsStore.swift`, `Sources/CompanionSession/SettingsMirror.swift`
- Test: `Tests/CompanionSessionTests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: `SettingsStoring`, `AppSettings`, `BlocklistConfig` (Core). Produces:
```swift
@MainActor public final class UserDefaultsSettingsStore: SettingsStoring {
    public static let key = "settings.v1"
    public init(defaults: UserDefaults = .standard)            // missing or undecodable data → AppSettings.default
    public private(set) var settings: AppSettings
    public func update(_ mutate: (inout AppSettings) -> Void)  // unchanged → no-op; else persist JSON, then notify observers synchronously, in registration order
    public func addObserver(_ onChange: @escaping @MainActor (AppSettings) -> Void)
}
/// Lock-protected copy of the settings that background services read (gatherer blocklist, provider base URL).
public final class SettingsMirror: Sendable {
    @MainActor public init(store: any SettingsStoring)         // seeds from store.settings, registers an observer
    public var blocklist: BlocklistConfig { get }
    public var openAICompatibleBaseURL: URL { get }            // http(s) URL with a host, else https://api.openai.com/v1
}
```
`SettingsMirror` stores an `OSAllocatedUnfairLock<AppSettings>`.

- [ ] **Step 1: Write the failing tests** (all `@MainActor`). Each test uses `UserDefaults(suiteName: "companion.tests.\(UUID().uuidString)")!` and calls `removePersistentDomain(forName:)` at the end.

```swift
@Test func emptySuiteGivesDefaults()             // settings == .default
@Test func updatePersistsAcrossInstances()       // update { $0.orbEnabled = false; $0.routing.youtube = ModelCatalog.sonnet55 }
                                                 // → UserDefaultsSettingsStore(defaults: suite).settings == store.settings
                                                 // → JSONDecoder().decode(AppSettings.self, from: suite.data(forKey: "settings.v1")!) == store.settings
@Test func observersRunSynchronouslyInOrder()    // observers append "a" then "b" → right after update returns: log == ["a", "b"], each saw orbEnabled == false
@Test func unchangedUpdateDoesNotNotify()        // update { _ in } → observer never called
@Test func corruptDataFallsBackToDefaults()      // suite.set(Data("nope".utf8), forKey: "settings.v1") → settings == .default
@Test func mirrorTracksUpdatesSynchronously()    // store.update { $0.blocklist.domains.append("example.com") }
                                                 // → mirror.blocklist.domains.contains("example.com") on the very next line
@Test func mirrorBaseURLFallback()               // "" → URL(string: "https://api.openai.com/v1"); "http://localhost:1234/v1" → that URL
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement both types** as declared.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `feat(session): UserDefaults settings store and thread-safe settings mirror`

---

### Task 4: PermissionsService

**Files:**
- Create: `Sources/CompanionSession/PermissionsService.swift`
- Test: `Tests/CompanionSessionTests/PermissionsServiceTests.swift`

**Interfaces:**
- Produces:
```swift
extension PermissionKind {                                   // PermissionKind comes from CompanionCore
    public var settingsURL: URL    // "x-apple.systempreferences:com.apple.preference.security?" + "Privacy_ScreenCapture" / "Privacy_Accessibility"
}
@MainActor protocol PermissionChecking: AnyObject {            // internal seam; Task 6 consumes it
    var screenRecordingGranted: Bool { get }
    var accessibilityGranted: Bool { get }
    func openSettings(for permission: PermissionKind)
}
@MainActor public final class PermissionsService: PermissionChecking {
    public init(open: @escaping @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) })
    public var screenRecordingGranted: Bool { get }   // CGPreflightScreenCaptureAccess(), never prompts
    public var accessibilityGranted: Bool { get }     // AXIsProcessTrusted(), never prompts
    public func request(_ permission: PermissionKind)   // CGRequestScreenCaptureAccess() / AXIsProcessTrustedWithOptions(prompt)
    public func openSettings(for permission: PermissionKind)
}
```
`PermissionKind` and `PermissionStatus` live in `CompanionCore`, so this Wave 1 task uses them directly — no mapping type is needed.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func settingsURLs() {
    #expect(PermissionKind.screenRecording.settingsURL.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    #expect(PermissionKind.accessibility.settingsURL.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
}
@MainActor @Test func openSettingsUsesInjectedOpener()   // openSettings(for: .accessibility) → opened == [PermissionKind.accessibility.settingsURL]
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** Pass the prompt option as `["AXTrustedCheckOptionPrompt": true] as CFDictionary`. Swift 6 strict concurrency rejects the mutable C global `kAXTrustedCheckOptionPrompt`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `feat(session): permissions service with System Settings deep links`

---

### Task 5: ErrorMessages

**Files:**
- Create: `Sources/CompanionSession/ErrorMessages.swift`
- Test: `Tests/CompanionSessionTests/ErrorMessagesTests.swift`

**Interfaces:**
- Produces:
```swift
public struct ErrorCopy: Sendable, Equatable { public var message: String; public var offerModelSwitch: Bool; public var offerSettings: Bool }
public enum ErrorMessages {
    public static func forFailure(_ error: any Error, model: ModelRef, openAICompatibleBaseURL: String) -> ErrorCopy
    public static let screenRecordingMissing: ErrorCopy
    public static let accessibilityMissing: ErrorCopy
}
```
`ErrorCopy` has the same fields as WS6's `BubbleErrorBanner`, so this task needs only Core. Task 6 converts it.

Exact copy (`<Model>` = `model.displayName`). `<host>` is `api.anthropic.com` for provider `anthropic`; otherwise `URL(string: base)?.host ?? base`.

| Input | message | switch | settings |
|---|---|---|---|
| `.missingAPIKey(providerID: "anthropic")` | `Add your Anthropic API key in Settings to start asking.` | – | ✓ |
| `.missingAPIKey(` any other id `)` | `Add an API key for your OpenAI-compatible provider in Settings.` | – | ✓ |
| `.http` 401, 403 | `<Model> rejected the API key. Check it in Settings.` | – | ✓ |
| `.http` 429 | `<Model> is rate-limiting requests. Try again in a moment or switch models.` | ✓ | – |
| `.http` 500, 503, 529 | `<Model> is overloaded right now. Switch models or try again.` | ✓ | – |
| `.http` other `(status, msg)` | `<Model> returned an error (<status>): <msg>` | ✓ | – |
| `.network`, or any `URLError` | `Couldn't reach <host>. Check your internet connection.` | – | – |
| `.decoding` | `Got an unreadable reply from <Model>. Try again.` | ✓ | – |
| any other error | `<Model> ran into an unexpected error. Try again.` | ✓ | – |
| `screenRecordingMissing` | `Companion can't see your screen yet. Grant Screen Recording in System Settings.` | – | ✓ |
| `accessibilityMissing` | `Companion can't read text in other apps yet. Grant Accessibility in System Settings.` | – | ✓ |

- [ ] **Step 1: Write the failing tests** (one assertion per table row; the full rows are shown here)

```swift
let haiku = ModelCatalog.haiku45, base = "https://api.openai.com/v1"
func copy(_ e: any Error, _ m: ModelRef = haiku, _ b: String = base) -> ErrorCopy { ErrorMessages.forFailure(e, model: m, openAICompatibleBaseURL: b) }
@Test func missingKeyCopy() {
    #expect(copy(LLMError.missingAPIKey(providerID: "anthropic")) == ErrorCopy(message: "Add your Anthropic API key in Settings to start asking.", offerModelSwitch: false, offerSettings: true))
    #expect(copy(LLMError.missingAPIKey(providerID: "openai-compatible")) == ErrorCopy(message: "Add an API key for your OpenAI-compatible provider in Settings.", offerModelSwitch: false, offerSettings: true))
}
@Test func httpCopy() {
    for s in [401, 403] { #expect(copy(LLMError.http(status: s, message: "")) == ErrorCopy(message: "Haiku 4.5 rejected the API key. Check it in Settings.", offerModelSwitch: false, offerSettings: true)) }
    #expect(copy(LLMError.http(status: 429, message: "")).message == "Haiku 4.5 is rate-limiting requests. Try again in a moment or switch models.")
    for s in [500, 503, 529] { #expect(copy(LLMError.http(status: s, message: "")) == ErrorCopy(message: "Haiku 4.5 is overloaded right now. Switch models or try again.", offerModelSwitch: true, offerSettings: false)) }
    #expect(copy(LLMError.http(status: 418, message: "teapot")) == ErrorCopy(message: "Haiku 4.5 returned an error (418): teapot", offerModelSwitch: true, offerSettings: false))
}
@Test func networkCopy() {
    #expect(copy(LLMError.network("offline")) == ErrorCopy(message: "Couldn't reach api.anthropic.com. Check your internet connection.", offerModelSwitch: false, offerSettings: false))
    let llama = ModelRef(providerID: "openai-compatible", modelID: "llama", displayName: "Llama")
    #expect(copy(URLError(.notConnectedToInternet), llama, "http://localhost:1234/v1").message == "Couldn't reach localhost. Check your internet connection.")
}
@Test func decodingAndUnknownCopy()   // .decoding("x") → "Got an unreadable reply from Haiku 4.5. Try again." (switch);
                                      // CocoaError(.featureUnsupported) → "Haiku 4.5 ran into an unexpected error. Try again." (switch)
@Test func permissionCopy()           // screenRecordingMissing / accessibilityMissing == the table rows, offerSettings true
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement `ErrorMessages`** with the table above.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `feat(session): exact error copy for model and permission failures`

---

### Task 6: SummonCoordinator core — ask from the bubble

**Gate: requires WS1 and WS6 merged into `main`.** Rebase first.

**Files:**
- Create: `Sources/CompanionSession/Seams.swift`, `Sources/CompanionSession/LiveConformances.swift`, `Sources/CompanionSession/SummonCoordinator.swift`, `Tests/CompanionSessionTests/Doubles.swift`
- Test: `Tests/CompanionSessionTests/SummonCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ModelRouter`, `PromptBuilder`, `ProviderRegistry` (WS1); `BubbleActions`, `BubbleViewModel`, `BubbleController`, `ThreadMessage`, `StepItem`, `BubbleErrorBanner` (WS6); Tasks 1–5.
- Produces:
```swift
// Seams.swift — internal
@MainActor protocol BubblePresenting: AnyObject {
    var isVisible: Bool { get }
    func show(cursor: NSPoint, avoiding: CGRect?); func focusInput(); func hide()
}
protocol ProviderResolving: Sendable { func provider(for model: ModelRef) throws -> any LLMProvider }
// LiveConformances.swift
extension BubbleController: BubblePresenting {}
extension ProviderRegistry: ProviderResolving {}
extension BubbleErrorBanner { init(_ copy: ErrorCopy) }
// SummonCoordinator.swift
@MainActor public final class SummonCoordinator: BubbleActions {
    init(viewModel: BubbleViewModel, presenter: any BubblePresenting, providers: any ProviderResolving,
         settings: any SettingsStoring, permissions: any PermissionChecking, trace: LatencyTrace,
         now: @escaping @Sendable () -> Date = Date.init,
         cursor: @escaping @MainActor () -> NSPoint = { NSEvent.mouseLocation },
         openSettings: @escaping @MainActor () -> Void)                       // internal (tests)
    public convenience init(viewModel: BubbleViewModel, bubble: BubbleController, providers: ProviderRegistry,
                            settings: any SettingsStoring, permissions: PermissionsService, trace: LatencyTrace,
                            openSettings: @escaping @MainActor () -> Void)    // App
    public func summon()
    public func cancelAll()                            // cancel in-flight work, keep partials (quit)
    private(set) var conversation: ConversationStore   // internal, read by tests
    private(set) var context: CapturedContext?         // internal
    func applyContext(_ context: CapturedContext?)     // internal: sets context + viewModel.setContext
    func settle() async                                // internal test hook: awaits every in-flight task
    // + the nine BubbleActions methods (public)
}
```
- Test doubles in `Doubles.swift`:
  - `FakePresenter` (@MainActor) records `showCalls: [(cursor: NSPoint, avoiding: CGRect?)]`, `focusCount` and `hideCount`; `show` sets `isVisible = true`, `hide` sets it false. `FakePermissions: PermissionChecking` has flags defaulting to `true` and records `opened: [PermissionKind]`.
  - `FakeProviders: ProviderResolving, @unchecked Sendable` (locked): `init(_ byModelID: [String: FakeLLMProvider] = [:], fallback: FakeLLMProvider = FakeLLMProvider())`. A settable `missingKeyProviders: Set<String>` makes it throw `LLMError.missingAPIKey(providerID:)`; it records `resolved: [ModelRef]`.
  - `Harness` (@MainActor final class): builds `BubbleViewModel()`, the fakes, `FakeSettingsStore()`, `LatencyTrace()` and a `TestClock`. It uses cursor `NSPoint(x: 500, y: 400)`, counts `openSettingsCount`, and exposes `provider` (the fallback). `func submit(_ q: String) async` calls `bubbleDidSubmit(q)` and then `settle()`.
  - `func waitUntil(_ timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async`: polls every 5 ms and calls `Issue.record` on timeout.

- [ ] **Step 1: Write the failing tests** (`@MainActor`, `@testable import CompanionSession`)

```swift
@Test func showsAtCursorAvoidingCentredRect() {
    let h = Harness(); h.coordinator.summon()
    #expect(h.presenter.showCalls.map(\.avoiding) == [nil])
    #expect(h.trace.records.last?.offsets[.panelVisible] != nil)
}
@Test func doubleSummonMidAnswerFocusesOnly() async {
    let slow = FakeLLMProvider(events: [.textDelta("Hel"), .textDelta("lo"), .finished(stopReason: "end_turn")], delayPerEvent: .milliseconds(100))
    let h = Harness(providers: FakeProviders(fallback: slow))
    h.coordinator.summon(); h.coordinator.bubbleDidSubmit("q")
    await waitUntil { h.vm.thread.last?.markdown == "Hel" }
    h.coordinator.summon()
    #expect(h.presenter.showCalls.count == 1 && h.presenter.focusCount == 1 && h.trace.records.count == 1)
    await h.coordinator.settle()
    #expect(h.vm.thread.map(\.markdown) == ["q", "Hello"] && slow.requests.count == 1)
}
@Test func firstRunWithoutKeyOrPermissions() async {
    let h = Harness(providers: FakeProviders(), permissions: FakePermissions(screenRecording: false, accessibility: false))
    h.providers.missingKeyProviders = ["anthropic"]
    h.coordinator.summon()
    #expect(h.presenter.showCalls.count == 1)                       // shown before any check runs
    await h.coordinator.settle()
    #expect(h.vm.error == BubbleErrorBanner(message: "Add your Anthropic API key in Settings to start asking.", offerModelSwitch: false, offerSettings: true))
    h.coordinator.bubbleDidSubmit("what is a derivative?")
    #expect(h.vm.thread.isEmpty && h.vm.isBusy == false && h.provider.requests.isEmpty)
    h.coordinator.bubbleDidRequestSettings()
    #expect(h.openSettingsCount == 1 && h.permissions.opened.isEmpty)
    h.providers.missingKeyProviders = []                            // key added; Screen Recording still missing
    h.coordinator.bubbleDidClose(); h.coordinator.summon(); await h.coordinator.settle()
    #expect(h.vm.error?.message == "Companion can't see your screen yet. Grant Screen Recording in System Settings.")
    h.coordinator.bubbleDidRequestSettings()
    #expect(h.permissions.opened == [.screenRecording])
    await h.submit("q")
    #expect(h.vm.thread.map(\.markdown) == ["q", "Hello"])          // non-blocking
}
@Test func deltasStreamInOrder() async
    // events a, b, c, finished → thread.last: markdown "abc", isStreaming false; vm.isBusy false;
    // before the first delta vm.steps.map(\.text) == ["Thinking…"]; after it, steps is empty;
    // trace.records.last has .submit, .firstToken, .finished; conversation.turns.count == 1;
    // conversation.turns[0].userMessage == provider.requests[0].messages.last
@Test func resumeWithin600Seconds() async
    // summon; submit "q1"; close; clock.advance(599); summon → vm.thread.map(\.markdown) == ["q1", "Hello"];
    // submit "q2" → requests.last!.messages.count == 3;
    // close; advance(601); summon → vm.thread.isEmpty; submit "q3" → requests.last!.messages.count == 1
@Test func tabOverrideAppliesToOneQuestion() async
    // summon → modelName "Haiku 4.5"; bubbleDidRequestModelCycle → "Sonnet 5.5"; submit q1 → modelName back to "Haiku 4.5";
    // submit q2 → provider.requests.map(\.model) == [ModelCatalog.sonnet55, ModelCatalog.haiku45]
@Test func closeMidStreamCancelsAndKeepsPartial() async
    // events "Part", "ial", finished, delayPerEvent 200 ms; waitUntil thread.last == "Part"; bubbleDidClose(); settle
    // → presenter.hideCount == 1; thread.last: markdown "Part", isStreaming false; conversation.turns.map(\.answer) == ["Part"]
@Test func overloadedOffersModelSwitchAndRetries() async
    // FakeProviders([haiku45.modelID: FakeLLMProvider(failure: LLMError.http(status: 529, message: "Overloaded"))]); submit "q"
    // → vm.error == BubbleErrorBanner(message: "Haiku 4.5 is overloaded right now. Switch models or try again.", offerModelSwitch: true, offerSettings: false)
    // bubbleDidRequestModelSwitchAfterError(); settle → vm.error == nil; fallback.requests.map(\.model) == [sonnet55];
    // vm.thread.map(\.markdown) == ["q", "Hello"]  (question not duplicated)
@Test func settingsChangeMidStreamAffectsNextQuestionOnly() async
    // slow stream; submit q1; waitUntil first delta; settings.update { $0.routing.genericWindow = ModelCatalog.sonnet55 }; settle
    // → thread.last == full answer; submit q2 → requests.map(\.model) == [haiku45, sonnet55]
@Test func blankOrBusySubmitIsIgnored() async
    // submit "  \n" → requests.isEmpty; bubbleDidSubmit("q1"); bubbleDidSubmit("q2"); settle → requests.count == 1
@Test func newChatMidStreamClearsEverything() async
    // slow stream; bubbleDidRequestNewChat → vm.thread.isEmpty, conversation.turns.isEmpty, isBusy false; settle → thread still empty
@Test func hintToggleChangesPrompt() async
    // submit q1; bubbleDidToggleHint → vm.hintMode == true; submit q2 → requests[0].system != requests[1].system
```

- [ ] **Step 2: Run** `swift test --filter CompanionSessionTests` → FAIL.
- [ ] **Step 3: Implement `Seams.swift` and `LiveConformances.swift`** as declared.
- [ ] **Step 4: Implement `SummonCoordinator`** with these behaviours. Where this list says *routed(kind)*, it means `ModelRouter(defaults: s.routing, cycle: s.modelCycle).model(for: kind)` built from the **current** `settings.settings` at each use. That is how settings changes take effect.

  **`summon()`**
  1. If `presenter.isVisible`, call `presenter.focusInput()` and return. Nothing else happens: no trace record, no reset, and the stream keeps going.
  2. Call `trace.begin()`. Then `resumed = conversation.beginSummon()` and `viewModel.resetThread(resumed ? <user/assistant ThreadMessages from turns> : [])`. Clear steps, thumbnails, document choice and error. Set override = nil and call `applyContext(nil)`. Finally `setModelName(routed(.genericWindow).displayName)`.
  3. `let c = cursor()`, then `presenter.show(cursor: c, avoiding: nil)` and `trace.mark(.panelVisible)`. Then `Task { @MainActor in trace.mark(.inputReady) }`: the next main-actor turn approximates "panel accepts keys".
  4. Only after `show`, start a startup task that resolves the routed provider in `Task.detached`, keeping the Keychain read off the main actor. On `missingAPIKey`, show the banner from `ErrorMessages` with the settings target set to app Settings. Otherwise `await provider.prewarm()`, then, if no banner is showing, check permissions in order: Screen Recording missing → `screenRecordingMissing` (target `.screenRecording`); Accessibility missing → `accessibilityMissing` (target `.accessibility`).

  **`bubbleDidSubmit(_:)`**
  1. Trim whitespace and newlines. Ignore the text if it is empty, or if a stream or page task is in flight.
  2. Call `trace.mark(.submit)` and `conversation.touch()`.
  3. Pick model = override ?? routed(context?.kind ?? .genericWindow) and call `try providers.provider(for: model)`. If it throws, show the banner, set the settings target and return. The thread is not touched.
  4. Call `showError(nil)`, `appendUserMessage(q)` and `setBusy(true)`. Remember `(q, model)`.
  5. Call `PromptBuilder().build(question: q, context: context, history: conversation.messages, hintMode: hintMode)`. Build `LLMRequest(model:system:messages:)` from it and start the stream task.
  6. Until the first `.textDelta`, show a single active step `Thinking…` (exact copy) unless a page-finder step list is already showing — strong models can be silent for several seconds and the spec forbids a blank bubble. On the first `.textDelta`: `trace.mark(.firstToken)`, remove the `Thinking…` step (or mark the page-finder steps done) and `beginAssistantMessage()`. Pass every delta to `appendDelta`. Ignore `.toolUse` (v2).
  7. Normal end: `finishAssistantMessage`; `conversation.appendTurn(question: q, userMessage: messages.last!, answer: full)`; `trace.mark(.finished)`; `setBusy(false)`; override = nil, and the model name goes back to the routed model.
  8. Error other than cancellation: finish any partial message. Let `copy = ErrorMessages.forFailure(error, model:, openAICompatibleBaseURL: settings.settings.openAICompatibleBaseURL)` and call `showError(BubbleErrorBanner(message: copy.message, offerModelSwitch: copy.offerModelSwitch, offerSettings: copy.offerSettings))`, with the app Settings target if it offers Settings, then `setBusy(false)`. Keep the failed `(q, model)` for retry; no turn is stored.
  9. Cancellation: finish the partial message, `appendTurn` with it if non-empty, then `setBusy(false)`.

  **Other actions**
  - `bubbleDidClose`: cancel in-flight tasks, keeping partials as in submit step 9. Then `presenter.hide()` (idempotent if WS6 already hid it) and `conversation.touch()`.
  - `bubbleDidRemoveContextItem(id)`: `applyContext(context?.removingItem(id))`.
  - `bubbleDidRequestModelCycle`: set override = `router.next(after: override ?? routed(current kind))` and call `setModelName`.
  - `bubbleDidToggleHint`: toggle hint mode (kept for the app session) and call `setHintMode`.
  - `bubbleDidRequestNewChat`: cancel in-flight work and discard partials. Call `conversation.reset()` and `resetThread([])`, clear steps, thumbnails, choice and error, and call `setBusy(false)`. The context is kept.
  - `bubbleDidRequestSettings`: if the banner's target is a permission, call `permissions.openSettings(for:)`; otherwise call `openSettings()`.
  - `bubbleDidRequestModelSwitchAfterError`: needs a failed question. Set override = `router.next(after: failedModel)`, clear the banner and call `setModelName`. Re-run submit steps 5–9 for the same question without appending a new user message.
  - `bubbleDidSelectDocument`: empty until Task 9.
- [ ] **Step 5: Run** `swift test --filter CompanionSessionTests` → PASS.
- [ ] **Step 6: Commit** — `feat(session): summon coordinator — summon, stream, follow-ups, errors`

---

### Task 7: App shell (M1)

**Gate: requires WS1 and WS6 merged** (same as Task 6).

**Files:**
- Modify: `App/CompanionApp.swift` (replace the WS0 scaffold)
- Create: `App/AppDelegate.swift`, `App/AppEnvironment.swift`, `Sources/CompanionSession/FirstRunPolicy.swift`, `Sources/CompanionSession/PermissionsService+UI.swift`
- Test: `Tests/CompanionSessionTests/FirstRunPolicyTests.swift`

**Interfaces:**
- Consumes: `KeychainSecretStore`, `ProviderRegistry` (WS1); `BubbleViewModel`, `BubbleController`, `OrbController`, `HotkeyManager`, `SettingsWindowController` (WS6); `PermissionStatus`, `PermissionKind` (Core); Tasks 1–6.
- Produces:
```swift
public enum FirstRunPolicy {
    public static let shownKey = "onboarding.settingsShown.v1"
    /// True — and records it — the first time anything required is missing; false afterwards or when nothing is missing.
    public static func shouldOpenSettings(screenRecording: Bool, accessibility: Bool, hasAnyAPIKey: Bool, defaults: UserDefaults) -> Bool
}
extension PermissionsService {
    public var status: PermissionStatus { get }
    public func open(_ kind: PermissionKind)            // → openSettings(for: kind)
}
// App target (internal)
@MainActor final class AppEnvironment { init(); func launch(); let coordinator: SummonCoordinator; let trace: LatencyTrace; let settingsWindow: SettingsWindowController }
final class AppDelegate: NSObject, NSApplicationDelegate { var environment: AppEnvironment? }
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func opensSettingsOnceWhenSomethingIsMissing()  // (screenRecording: false, accessibility: true, hasAnyAPIKey: true) → true; same call again → false;
                                                      // suite.bool(forKey: "onboarding.settingsShown.v1") == true
@Test func missingKeyAloneCounts()                    // (true, true, false) → true
@Test func doesNotOpenWhenEverythingIsReady()         // (true, true, true) → false; suite.object(forKey: shownKey) == nil
@MainActor @Test func permissionKindMapsToPane()      // PermissionsService(open: record).open(.screenRecording) → opened == [PermissionKind.screenRecording.settingsURL]
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement `FirstRunPolicy` and `PermissionsService+UI`.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Implement the app shell.**
  - **`AppEnvironment.init` order:** `KeychainSecretStore()` → `UserDefaultsSettingsStore()` → `SettingsMirror(store:)` → `PermissionsService()` → `LatencyTrace()` → `ProviderRegistry(secrets:, openAICompatibleBaseURL: { mirror.openAICompatibleBaseURL })` → `BubbleViewModel()` → `BubbleController(viewModel:)` (panel built at launch, §5.1) → `SummonCoordinator` convenience init with `openSettings: { [weak self] in self?.settingsWindow.show() }` → `viewModel.actions = coordinator`.
  - Then `SettingsWindowController(settings:, secrets:, bridgeStatus: { nil }, pairingToken: { "" }, regenerateToken: { "" }, permissions: { permissions.status }, openPermission: { permissions.open($0) })`; the bridge closures are placeholders until Task 10. Then `OrbController(settings:, onSummon: { coordinator.summon() })` and `HotkeyManager(onSummon: { coordinator.summon() }, onRegion: {})`; region is wired in Task 8.
  - **`launch()`:** call `orb.setVisible(settings.settings.orbEnabled)` and add an observer that does the same. If `FirstRunPolicy.shouldOpenSettings(...)` returns true (`hasAnyAPIKey` = Anthropic or OpenAI-compatible key non-nil), call `permissions.request(_:)` for each missing permission, then `settingsWindow.show()`. The request is what lists Companion in those System Settings panes.
  - **`CompanionApp`:** `@NSApplicationDelegateAdaptor(AppDelegate.self)` and `MenuBarExtra("Companion", systemImage: "sparkle")` with `Button("Ask…  ⌥Space")` → `summon()`, `Button("Settings…")`, `Button("Latency Report")` → `NSAlert(messageText: "Latency Report", informativeText: trace.summaryText)`, `Divider()`, `Button("Quit")` → `NSApp.terminate(nil)`. `AppDelegate.applicationDidFinishLaunching` creates the environment and calls `launch()`.
- [ ] **Step 6: Verify** — `scripts/run-app.sh` → `** BUILD SUCCEEDED **`. Manual check (M1): with an Anthropic key in Settings, ⌥Space opens the bubble at the cursor, typing works and an answer streams. Esc closes; ⌥Space within 10 min shows the thread. Latency Report shows `Last N summons — …`.
- [ ] **Step 7: Commit** — `feat(app): menu-bar shell wiring coordinator, bubble, hotkeys, settings (M1)`

---

### Task 8: Screen context and region capture (M2)

**Gate: requires WS1, WS5 and WS6 merged.** Rebase first.

**Files:**
- Create: `Sources/CompanionSession/ContextSeams.swift`; modify `Sources/CompanionSession/SummonCoordinator.swift`, `App/AppEnvironment.swift`, `App/CompanionApp.swift`, `Tests/CompanionSessionTests/Doubles.swift`
- Test: `Tests/CompanionSessionTests/SummonContextTests.swift`

**Interfaces:**
- Consumes: `ContextGatherer`, `GatherRequest`, `RegionSelection`, `RegionSelector` (WS5); `CaptureGlow` (WS6).
- Produces:
```swift
// ContextSeams.swift — internal
protocol ContextGathering: Sendable { func gather(_ request: GatherRequest) async -> AsyncStream<CapturedContext> }
@MainActor protocol RegionSelecting { func select() async -> RegionSelection? }
@MainActor protocol GlowFlashing { func flash(_ rect: CGRect) }
extension ContextGatherer: ContextGathering {}
struct LiveRegionSelector: RegionSelecting { func select() async -> RegionSelection? { await RegionSelector.select() } }
struct LiveCaptureGlow: GlowFlashing { func flash(_ rect: CGRect) { CaptureGlow.flash(rect) } }
// SummonCoordinator additions
var gatherer: (any ContextGathering)?                          // internal
var regionSelector: any RegionSelecting = LiveRegionSelector() // internal; tests replace
var glow: any GlowFlashing = LiveCaptureGlow()                 // internal; tests replace
public func attach(gatherer: ContextGatherer)
public func summonRegion()
```
- Doubles:
  - `actor FakeGatherer: ContextGathering` — `init(emissions: [CapturedContext], gap: Duration = .zero)`; records `requests: [GatherRequest]`, yields each emission after `gap`, then finishes. `@MainActor final class FakeRegionSelector: RegionSelecting` — counts `selectCount`; `select()` suspends until `finish(_: RegionSelection?)`. `FakeGlow` records `flashed: [CGRect]`.
  - Helper `ctx(kind: = .genericWindow, frame: CGRect? = CGRect(x: 100, y: 100, width: 800, height: 600), items: [ContextItem] = [], complete: Bool) -> CapturedContext` (`privacy: .allowed`).
  - `Harness` gains `gatherer: FakeGatherer = FakeGatherer(emissions: [])`, exposes `gatherer`, `selector` and `glow`, and assigns all three onto the coordinator.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func gatherFeedsChipsGlowAndPrewarm() async {
    let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
    let text = ContextItem(piece: .focusedText("x^2 - 5x + 6 = 0"))
    let h = Harness(gatherer: FakeGatherer(emissions: [ctx(complete: false), ctx(items: [text], complete: false),
                                                       ctx(kind: .mathPage, items: [text], complete: true)]))
    h.coordinator.summon(); await h.coordinator.settle()
    #expect(await h.gatherer.requests == [.frontWindow])
    #expect(h.vm.context?.isComplete == true && h.glow.flashed == [frame])
    #expect(h.provider.prewarmCount == 1)                 // one provider, prewarmed once per summon
    #expect(h.vm.modelName == "Sonnet 5.5")               // mathPage → strong
    #expect(h.trace.records.last?.offsets[.contextFirst] != nil && h.trace.records.last?.offsets[.contextComplete] != nil)
}
@Test func doubleSummonDoesNotRegather() async
    // summon; submit with a slow stream; summon again → gatherer.requests == [.frontWindow]; stream completes
@Test func removedChipStaysRemovedAndIsNotSent() async
    // emission 1: .selectedText("SECRET-A") + .focusedText("keep me"); bubbleDidRemoveContextItem(<selectedText id>);
    // emission 2 (50 ms gap, NEW ContextItem ids, same pieces, complete) → vm.context has no .selectedText;
    // submit → no .text in provider.requests.last!.messages.last!.content contains "SECRET-A"; one contains "keep me"
@Test func submitWaitsBrieflyForGather() async
    // final emission (200 ms gap) adds .focusedText("late"); bubbleDidSubmit right after summon → request text contains "late"
@Test func regionEscapeChangesNothing() async
    // summonRegion; waitUntil selectCount == 1; finish(nil); settle → showCalls.isEmpty, gatherer.requests.isEmpty, trace.records.isEmpty
@Test func regionSelectionAvoidsAndGathersRegion() async
    // sel = RegionSelection(rect: CGRect(x: 200, y: 150, width: 400, height: 300), displayID: 1); finish(sel); settle
    // → showCalls[0].avoiding == sel.rect; glow.flashed.first == sel.rect; gatherer.requests == [.region(sel)]
@Test func hotkeysIgnoredDuringRegionSelection() async {
    let h = Harness(gatherer: FakeGatherer(emissions: []))
    h.coordinator.summonRegion(); await waitUntil { h.selector.selectCount == 1 }
    h.coordinator.summon(); h.coordinator.summonRegion()
    #expect(h.presenter.showCalls.isEmpty && h.selector.selectCount == 1)
    h.selector.finish(nil); await h.coordinator.settle()
    #expect(h.presenter.showCalls.isEmpty)
}
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement `ContextSeams.swift` and the coordinator changes.**
  - **`summon()` additions.** Return immediately while a region selection is in progress. After `show`, cancel any previous gather task and start one for `.frontWindow`. For each emission: drop removed pieces (below), then `applyContext`. The first emission marks `.contextFirst`. The first emission with a non-nil `front?.windowFrame` calls `glow.flash(frame)`, once per summon. `isComplete` marks `.contextComplete`. With no override, `setModelName` follows routed(kind). Prewarm the routed provider only if its `providerID` hasn't been prewarmed this summon.
  - **Removal stickiness.** `bubbleDidRemoveContextItem` also records, for the current summon, the removed item's `id` and its piece case (`windowImage`, `regionImage`, `youtubeVideo`, `transcriptWindow`, `webPage`, `math`, `pdfPages`, `selectedText`, `focusedText`). Later emissions drop items matching either. The gatherer API doesn't promise stable ids across emissions.
  - **Submit while gathering.** Await gather completion for up to **500 ms**, then continue with the latest context.
  - **`summonRegion()`.** Ignore it if a selection is already in progress; otherwise set the in-progress flag, await `regionSelector.select()`, then clear the flag. On nil, return with nothing changed. Otherwise: if the bubble is visible, `focusInput()`; else run summon steps 2–3 with `trace.begin()` starting now (the drag is not hotkey latency) and `avoiding: sel.rect`. Then `glow.flash(sel.rect)` and gather `.region(sel)` like the front window, which replaces the context and leaves the thread alone.
  - Close, new chat and a new summon cancel the gather task.
- [ ] **Step 4: Wire the app.** `AppEnvironment` builds `ContextGatherer.live(browser: NoBrowserContext(), blocklist: { mirror.blocklist }, ownBundleID: "dev.local.Companion")` and calls `coordinator.attach(gatherer:)`. `NoBrowserContext` is a private struct in `AppEnvironment.swift` conforming to `BrowserContextProviding` that returns `nil`, `nil`, `false`; Task 10 deletes it. `HotkeyManager`'s `onRegion:` calls `coordinator.summonRegion()`, and the menu gains `Button("Capture Region…  ⌥⇧Space")` after "Ask…".
- [ ] **Step 5: Run** `swift test --filter CompanionSessionTests` → PASS; `scripts/run-app.sh` → BUILD SUCCEEDED. Manual check: ⌥Space over Notes shows window + screen-text chips and the glow outlines Notes; ⌥⇧Space shows the crosshair, then a `region` chip.
- [ ] **Step 6: Commit** — `feat(session): screen context, capture glow and region capture (M2)`

---

### Task 9: Page-finder flow

**Gate: requires WS2 merged** (plus WS1 and WS6 via Task 6). It may run before Task 8. Rebase first.

**Files:**
- Create: `Sources/CompanionSession/PageFinding.swift`, `Sources/CompanionSession/SummonCoordinator+PageFinder.swift`; modify `Sources/CompanionSession/SummonCoordinator.swift` (stored state, submit branch, `bubbleDidSelectDocument`) and `Tests/CompanionSessionTests/Doubles.swift`
- Test: `Tests/CompanionSessionTests/PageFinderFlowTests.swift`

**Interfaces:**
- Consumes: `PageReferenceParser`, `PageReference`, `PageFinderStep` (`displayText`), `PageFinderOutcome`, `PageFinder` (WS2); `BrowserContextProviding`, `DocumentChoice`, `RenderedPage` (Core).
- Produces:
```swift
protocol PageFinding: Sendable {                                           // internal
    func find(_ reference: PageReference, question: String, tab: TabContext?, lastUsed: DriveFileRef?,
              preferred: DriveFileRef?, progress: @escaping @Sendable (PageFinderStep) -> Void) async -> PageFinderOutcome
}
extension PageFinder: PageFinding {}
// SummonCoordinator additions
var pageFinder: (any PageFinding)?; var browser: (any BrowserContextProviding)?   // internal
private(set) var lastUsedDocument: DriveFileRef?                                   // internal, read by tests
public func attach(pageFinder: PageFinder, browser: any BrowserContextProviding)
```
- Exact copy: cap note `Only the first 10 pages will be sent (you asked for <N>).` · sending `Sending pages to <model displayName>…` · not found `Couldn't find p. <page> in “<document title>”.` · no document (assistant message) `I couldn't find a PDF on this page. Open the textbook or its Classroom assignment and ask again.`
- Doubles: `actor FakePageFinder: PageFinding` — `init(outcome: PageFinderOutcome, steps: [PageFinderStep] = [])`; records `calls: [(reference: PageReference, tab: TabContext?, lastUsed: DriveFileRef?, preferred: DriveFileRef?)]` and emits `steps` through `progress` before returning `outcome`. `Harness` gains `pageFinder: FakePageFinder? = nil` and `browser: FakeBrowserContextProvider? = nil`, set on the coordinator when non-nil.
- Fixtures: `classroomTab` decodes `Fixtures.bridgeFixture("ext-tabContext-classroom.json")` as `ExtensionToApp.tabContext`. `textbook = DriveFileRef(fileId: "1AbCdEfGhIjKlMnOpQrStUvWxYz012345", title: "Algebra 2 Textbook.pdf", mimeType: "application/pdf")`; `worksheet` is the fixture's second attachment. `pages` have printed labels "231"/"232" at `pdfIndex` 246/247, each with `Fixtures.samplePNG()`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func foundPagesAreShownAttachedAndRoutedStrong() async {
    let steps: [PageFinderStep] = [.downloading(title: "Algebra 2 Textbook.pdf"), .downloaded(pageCount: 412),
                                   .matched(printed: 231, pdfIndex: 246, method: .pageLabels)]
    let finder = FakePageFinder(outcome: .found(choice: DocumentChoice(current: textbook, alternatives: [worksheet]), pages: pages, missing: []), steps: steps)
    let h = Harness(pageFinder: finder, browser: FakeBrowserContextProvider(cached: classroomTab))
    h.coordinator.summon(); await h.submit("explain pages 231–232")
    #expect(h.vm.steps.map(\.text) == steps.map(\.displayText) + ["Sending pages to Sonnet 5.5…"])
    #expect(h.vm.steps.allSatisfy { $0.state == .done })
    #expect(await finder.calls.first?.tab?.tabId == 33)
    #expect(h.vm.pageThumbnails == pages && h.vm.documentChoice?.current == textbook)
    #expect(h.vm.context?.items.map(\.chipLabel).contains("pp. 231–232") == true)
    #expect(h.provider.requests.last?.model == ModelCatalog.sonnet55 && h.coordinator.lastUsedDocument == textbook)
}
@Test func capNoteWhenMoreThanTenPagesAsked() async
    // "explain pages 500–520" → vm.steps.first == done step "Only the first 10 pages will be sent (you asked for 21)."
@Test func noDocumentAnswersWithoutModelCall() async
    // .noDocument → vm.thread.last?.markdown == "I couldn't find a PDF on this page. Open the textbook or its Classroom assignment and ask again.";
    // provider.requests.isEmpty; vm.isBusy == false; conversation.turns.isEmpty
@Test func notFoundSaysSoThenAnswersFromVisibleContext() async
    // .notFound(document: textbook, pages: [231, 232]) → a .failed step "Couldn't find p. 231 in “Algebra 2 Textbook.pdf”.";
    // requests.count == 1; requests[0].model == ModelCatalog.haiku45
@Test func failedShowsMessageThenAnswers() async
    // .failed(message: "The extension didn't answer.") → a .failed step with exactly that text; requests.count == 1
@Test func lastUsedDocumentIsPassedNextTime() async          // two page questions → calls[1].lastUsed == textbook
@Test func choosingAnotherDocumentReRuns() async
    // after .found: bubbleDidSelectDocument(worksheet); settle → calls.last?.preferred == worksheet;
    // vm.thread.filter { $0.role == .user }.count == 1; exactly one .pdfPages item in vm.context; requests.count == 2
@Test func backgroundBrowserTabIsIgnoredWhenFrontAppIsNotABrowser() async  // front Notes + cached classroom tab → calls.last?.tab == nil
@Test func plainMathDoesNotTriggerFinder() async             // "solve x^2 - 5x + 6 = 0" → calls.isEmpty; requests.count == 1
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement the page branch.** It runs in submit after step 4, when `pageFinder != nil` and `PageReferenceParser.parse(q)` is non-nil:
  1. Set steps to `[]`. If `requestedCount > pages.count`, add the cap note as a done step.
  2. Read `tab = await browser?.cachedActiveTabContext()`. Drop it if `blocked`, if the current context's front app is not a browser (`!KnownBrowsers.isBrowser(front.bundleID)` — e.g. Notes is in front while a Classroom tab sits in the background), or if `currentContext.tabId` is set and differs from `tab.tabId`. A dropped tab means the finder falls back to `lastUsed`.
  3. Progress: the `@Sendable` callback yields into an `AsyncStream<PageFinderStep>` continuation. One `@MainActor` loop consumes it in order; separate `Task { @MainActor }` hops could reorder steps. For each step, mark the previous active step done, append `StepItem(text: displayText, state: .active)` and call `setSteps`. When `find` returns, finish the continuation and await the loop.
  4. Handle the outcome:
     - **`.found(choice, pages, missing)`:** call `setPageThumbnails(pages)` and `setDocumentChoice(choice)`, and set `lastUsedDocument = choice.current`. Start from the current context, or `CapturedContext(front: nil, privacy: .allowed, kind: .pdfPages, items: [], isComplete: true)` if there is none. Remove any earlier `.pdfPages` item, append `ContextItem(piece: .pdfPages(pages))`, set kind `.pdfPages` and `applyContext`. If `missing` is non-empty, add a failed not-found step for `missing[0]`. Model = override ?? routed(.pdfPages). The sending step is active until the first token (then done) or an error (then failed). Then run the normal stream.
     - **`.noDocument`:** write the no-document assistant message (begin, delta, finish). No model call, no stored turn, and `setBusy(false)`.
     - **`.notFound(document, pages)`:** add a failed not-found step using `pages[0]` and `document.title`, then run the normal stream on the current context.
     - **`.failed(message)`:** add a failed step with `message`, then run the normal stream on the current context.
  5. Remember `(q, reference)` as the last page question.

  **`bubbleDidSelectDocument(file)`:** needs a last page question. Cancel any in-flight stream (the partial is kept), then re-run steps 1–4 with `preferred: file` without appending a user message.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `feat(session): page-finder flow with live steps and document choice`

---

### Task 10: Full composition — bridge, page finder, clean quit (M3, M4)

**Gate: requires WS1–WS6 all merged and Tasks 8–9 done.** WS3 isn't needed to build, only for the manual check. Rebase first.

**Files:**
- Create: `Sources/CompanionSession/Shutdown.swift`; modify `App/AppEnvironment.swift`, `App/AppDelegate.swift`
- Test: `Tests/CompanionSessionTests/ShutdownTests.swift`

**Interfaces:**
- Consumes: `BridgeServer`, `BridgePairing` (WS4); `PDFSessionCache`, `PageFinder` (WS2); `ContextGatherer.live` (WS5).
- Produces:
```swift
public enum Shutdown {
    /// Runs steps in order, each bounded by `perStepTimeout`; an overrunning step is abandoned (not awaited)
    /// and the next one runs. Returns the indices of the steps that timed out.
    public static func run(perStepTimeout: Duration, _ steps: [@Sendable () async -> Void]) async -> [Int]
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func stepsRunInOrder() async     // three steps appending "cancel", "stop", "clear" to an actor log → log == ["cancel", "stop", "clear"]; result == []
@Test func hangingStepDoesNotBlockLaterSteps() async {
    let log = Log(); let start = ContinuousClock.now
    let timedOut = await Shutdown.run(perStepTimeout: .milliseconds(100), [
        { try? await Task.sleep(for: .seconds(30)) },        // bridge.stop() stuck mid-PDF-transfer
        { await log.append("clear") }])
    #expect(timedOut == [0] && (await log.entries) == ["clear"])
    #expect(ContinuousClock.now - start < .seconds(1))
}
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement `Shutdown.run`.** Race each step, run in an unstructured `Task`, against `Task.sleep(for: perStepTimeout)`, and resume a `CheckedContinuation` exactly once through a lock-guarded flag. Don't use a task group: it waits for a child that ignores cancellation, which is exactly the hung-transfer case.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Complete `AppEnvironment` and `AppDelegate`.**
  - Bridge: `BridgeServer(secrets: secrets, blocklist: settings.settings.blocklist, appVersion: <CFBundleShortVersionString ?? "0.1.0">)`.
  - Gatherer: `ContextGatherer.live(browser: bridge.browserContext, blocklist: { mirror.blocklist }, ownBundleID: "dev.local.Companion")`. Delete `NoBrowserContext`.
  - Page finder: `cache = PDFSessionCache()`, then `PageFinder(fetcher: bridge.documentFetcher, viewer: bridge.viewerDriver, cache: cache)` and `coordinator.attach(pageFinder:browser: bridge.browserContext)`.
  - Settings window: `bridgeStatus: { await bridge.status() }`, `pairingToken: { (try? BridgePairing.token(in: secrets)) ?? "" }`, `regenerateToken: { (try? BridgePairing.regenerate(in: secrets)) ?? "" }`.
  - **`launch()`:** `Task { await cache.clearAll(); do { _ = try await bridge.start() } catch { logger.error(...) } }`. Clearing at launch removes leftovers from a crash or force-quit. If the bridge fails to start, the app is still usable and Settings shows no port.
  - **Settings observer:** when `blocklist` changed, yield it into one `AsyncStream<BlocklistConfig>` whose single consumer task calls `await bridge.updateBlocklist(_:)`. A `Task` per change could apply updates out of order. The orb observer from Task 7 stays.
  - **`applicationShouldTerminate`:** call `environment.coordinator.cancelAll()` and return `.terminateLater`. In a `Task`, run `await Shutdown.run(perStepTimeout: .seconds(1), [{ await bridge.stop() }, { await cache.clearAll() }])`, then `NSApp.reply(toApplicationShouldTerminate: true)`.
- [ ] **Step 6: Verify** — `scripts/run-app.sh` → BUILD SUCCEEDED. Manual check: load the WS3 extension in Dia and paste the pairing token from Settings, and Settings shows the port and "Dia" connected. On YouTube, ⌥Space shows the transcript chip. On a Classroom assignment, "explain pages 231–232" shows live steps and thumbnails. Quit during the download: the app exits within 2 s and `ls "$TMPDIR/Companion-PDFCache"` is empty or missing.
- [ ] **Step 7: Commit** — `feat(app): full composition — bridge, page finder, blocklist sync, clean quit (M3/M4)`

---

### Task 11: End-to-end verification

**Gate: WS1–WS6 and WS3 merged; Tasks 1–10 done.**

**Files:**
- Create: `docs/superpowers/verification/2026-11-01-v1-e2e.md`, `docs/superpowers/verification/daily-use-log.md`

- [ ] **Step 1: Write `2026-11-01-v1-e2e.md`.** It has a header (date, commit SHA, macOS version, display setup, Dia + extension versions), a table `# | Scenario | Steps | Expected | Result (✅/❌) | Notes` with one row per item below, a "Latency Report" section (paste `summaryText` and the targets), and a "Follow-ups" section for every ❌. Rows (scenario → expected):
  1. **First run, no key:** remove keys in Settings, then `defaults delete dev.local.Companion onboarding.settingsShown.v1` and relaunch. Settings opens once. ⌥Space opens the bubble instantly with "Add your Anthropic API key in Settings to start asking.", and its button opens app Settings.
  2. **No Screen Recording:** `tccutil reset ScreenCapture dev.local.Companion`, then ⌥Space. The bubble opens with "Companion can't see your screen yet. Grant Screen Recording in System Settings." Its button opens the Screen Recording pane, and asking still works.
  3. **⌥Space over Notes:** window + screen-text chips, the glow outlines Notes, Haiku 4.5, and the answer streams.
  4. **YouTube in Dia, about 12 min in:** "explain the concept they were just talking about". Expect `▶ <time> · <chapter>` and `transcript <from>–<to>` chips (a ~3 min window), Haiku 4.5, and an answer about what was just said.
  5. **KaTeX math page:** `math ×N` chip, Sonnet 5.5, and no "Reading:" line.
  6. **Region capture of a math image** (⌥⇧Space, drag): `region` chip, glow on the rect, the bubble beside the region rather than over it, and the answer starts with `Reading: …`.
  7. **Classroom assignment:** "explain pages 231–232". Steps show live (download → matches → `Sending pages to Sonnet 5.5…`), the chip reads `pp. 231–232`, thumbnails show printed pp. 231–232, and choosing another attachment re-runs.
  8. **Follow-up:** within 10 min the previous thread resumes and is used. After more than 10 min idle, a fresh thread starts.
  9. **1Password in front:** only the `context off for this app` chip, with no window or text chips.
  10. **Banking site in Dia** (e.g. chase.com): blocked, with no page-text or screenshot chips.
  11. **Dia quit**, then relaunched and summoned before the extension reconnects (or another Chromium browser without the extension). Expect the `extension not connected` chip, window chips present, and a bubble with no delay. While Dia is quit, Settings lists no connected browser.
  12. **Double ⌥Space mid-answer:** the same bubble is focused, the answer keeps streaming, and there is no second glow.
  13. **Esc mid-answer**, then ⌥Space within 10 min: the partial answer is in the thread.
  14. **Multi-monitor:** with the cursor on the second display (and over a full-screen app), the bubble opens on that display, inside its visible frame, above the full-screen app.
  15. **⌥⇧Space, then ⌥Space while the crosshair is up:** nothing happens until Esc or a drag.
  16. **Quit during a page-finder download:** the app exits within 2 s and `$TMPDIR/Companion-PDFCache` is empty or missing.
  17. **Latency Report after 20 or more summons:** hotkey→typing p95 < 100 ms (target) and < 800 ms (hard fail); submit→first token median ≤ 1.5 s on Haiku 4.5.
- [ ] **Step 2: Write `daily-use-log.md`.** One paragraph restating the success test (spec §2: daily use for two weeks, no more screenshot-and-paste). A table `Date | What I asked | App / site | Fell back to screenshot-and-paste? (Y/N) | Why | Notes`. A "Weekly summary" block for week 1 and week 2: fallback count, top reasons, pasted Latency Report.
- [ ] **Step 3: Run the checklist.** Launch with `scripts/run-app.sh` and fill in Result/Notes. Rows 4, 7, 9 and 10 need the owner's accounts; leave them for the human if you can't do them. Record each ❌ under Follow-ups; don't fix anything in this task.
- [ ] **Step 4: Commit** — `git add docs/superpowers/verification && git commit -m "docs(verification): v1 end-to-end checklist and daily-use log"`
