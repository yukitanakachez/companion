# WS6 — Companion UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read `2026-11-01-companion-00-overview.md` (rules, global constraints, the CompanionUI API you produce) and the spec first.

**Goal:** Build `CompanionUI` — the instant cursor bubble (panel, view model, streamed Markdown+KaTeX answers, pop-out), the idle orb, the capture glow, global hotkeys and the Settings window — plus `CompanionUIDemo`, which reproduces the approved mockup with fake data.

**Architecture:** All AppKit/SwiftUI types are `@MainActor`. The bubble is one non-activating floating `NSPanel` built at `BubbleController.init` and reused; it hosts a SwiftUI `BubbleView` driven by an `@Observable` `BubbleViewModel` that WS7 mutates and that reports user intents through `BubbleActions`. Answers render in a pre-loaded transparent `WKWebView` running a small bundled renderer (markdown-it + KaTeX, built from `ui-web/` and committed into `Resources/web/`), fed by a Swift-side diff that sends either a full render or an appended delta. Geometry (bubble placement/sizing, orb position) and settings logic are pure and unit-tested; windows are tested for flags, focus and timing.

**Tech Stack:** Swift 6.4 (language mode 6), SwiftUI + AppKit (NSPanel, NSTextView, NSVisualEffectView, Core Animation), Observation, WebKit, KeyboardShortcuts 2.x, Swift Testing; `ui-web/`: markdown-it 14, KaTeX 0.16, esbuild, vitest, jsdom (Node 24).

**Spec:** `docs/superpowers/specs/2026-11-01-screen-companion-design.md` (§5.1 step 1, §5.2, §5.7, §7). Visual sources of truth: `.superpowers/brainstorm/8115-1793558137/content/bubble-flow.html` (bubble, frames 1–4) and `design/glow-prototype.html` (orb **look** only — not its ~1 s glide-into-bar opening).

## Global Constraints

All of the overview's Global Constraints apply. The ones that shape this workstream:
- macOS 14.0+, Swift 6 strict concurrency; AppKit/SwiftUI code is `@MainActor`; values crossing modules are `Sendable`.
- `CompanionUI` depends only on `CompanionCore` and KeyboardShortcuts. Owned paths: `Sources/CompanionUI/` (incl. `Resources/web/`, a `.copy` resource read via `Bundle.module`), `Tests/CompanionUITests/`, `Sources/CompanionUIDemo/`, `ui-web/`. `Package.swift` is frozen.
- Hotkey → bubble visible and accepting keystrokes: hard < 0.8 s, target < 0.1 s; `BubbleController.show` returns in **< 50 ms**. Any user action → visible change < 0.1 s; never a blank bubble.
- Default hotkeys: summon **⌥Space**, region capture **⌥⇧Space**; both rebindable.
- Secrets only through `SecretStoring`; nothing captured is written to disk.
- `Resources/web/` is build output of `ui-web/`, committed so `swift build` never needs npm. Never hand-edit it.

WS6 values (exact):
- Bubble: width **380 pt**; height min **72**, max **520**, then the answer area scrolls; corner radius **14**; offset from cursor **(16, −16)** (AppKit global coords, bottom-left origin). Pop-out window content **640×720**, min **480×400**, resizable, same view model.
- Placement candidates in order: right-below, left-below, right-above, left-above of the cursor; then, only when `avoid` is given, beside the avoided rect with a **12 pt** gap: right-of, left-of, below, above.
- Bubble panel: created once; style mask `[.borderless, .nonactivatingPanel]` set at init and never mutated; `isFloatingPanel = true`; `level = .floating`; `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]`; `hidesOnDeactivate = false`; `canBecomeKey = true`; `becomesKeyOnlyIfNeeded = false`; `animationBehavior = .none`; `isReleasedWhenClosed = false`.
- Mockup tokens: bubble fill #1C1C1E at 92 % over a dark blur, text #F2F2F7; chip bg white 12 %, text #D8D8DE, radius 6, ✕ at 55 % opacity; window thumbnail **26×17**, 1 pt white-25 % border, radius 3; input bg white 8 %, radius 8, caret #0A84FF, placeholder #8E8E93; footer #8E8E93 with keycaps (1 pt white-25 % border, radius 3); question #A1A1A6; answer #ECECF0, line-height 1.45; `Reading:` line #A1A1A6 serif with a 2 pt #0A84FF left rule; steps text #D1D1D6, ✓ #30D158, ● #FFD60A, ✕ #FF453A; page thumbnails **34×44** with the printed label bottom-right; `↗ pop out` #0A84FF.
- Copy: placeholder `Ask about this…`; follow-up placeholder `Follow up…`; footer left `<modelName> ⇥ switch` (plus ` · new chat ⌘N` once the thread is non-empty); footer right `Hints ⌘H` (#0A84FF on an 18 % tint when on) and `Esc to close`; document chip `using: <title>`; banner buttons `Switch model`, `Open Settings`; pop-out button `↗ pop out`.
- Bubble keys: Return submits; Shift-Return newline; Esc closes; Tab cycles model; ⌘H hint; ⌘N new chat. While an IME composition is active every key goes to the input method.
- Orb: **30 pt**, Aurora palette from the glow prototype (`#FF5FA2`, `#FFB35C`, `#6E7BFF`, `#37E0D0`), radial body highlight at (0.35, 0.35), breathing halo period **2.4 s**; default center = main screen (`NSScreen.screens.first`, not `NSScreen.main`) visibleFrame inset **24 pt** from bottom-right → `(maxX − 39, minY + 39)`; drag threshold **3 pt**; `AppSettings.orbPosition` stores the orb **center** in global AppKit coords.
- Capture glow: frame `rect.insetBy(dx: −6, dy: −6)`, 3 pt rounded stroke (corner radius 12), fade in **0.08 s**, hold **0.25 s**, fade out **0.3 s**, then close; click-through; never key.
- Renderer: JS API `window.companion.render(threadJSON)`, `window.companion.appendDelta(id, text)`; re-render throttled to one per **33 ms**; markdown-it `html: false`, images disabled; KaTeX `throwOnError: false`.
- Tests: every suite that creates an `NSWindow`/`WKWebView` nests inside `@MainActor @Suite(.serialized) enum WindowTests` so `swift test --filter CompanionUITests` never interleaves window tests.

## Review Focus

1. **Typing into a non-activating panel**: after ⌥Space the user types at once and every key lands in the bubble while the front app stays active; ⌘H toggles hints instead of hiding the app; Return during a Japanese IME composition commits the text instead of sending. *(Task 5 `imeCompositionKeysGoToInputMethod`, `escClosesInsteadOfCompleting`; Task 6 `showIsFastFocusesInputAndDoesNotActivate`, `commandKeysAreHandledBeforeTheMainMenu`)*
2. **Multiple displays and full-screen apps** (overview Review Focus #5, owned here): the bubble appears on the display under the cursor — including one at negative x, and with the cursor on a display's top edge — inside its visible frame, flipped away from edges, above full-screen apps; a saved orb position on an unplugged display falls back to the default. *(Task 1 `secondaryDisplayAtNegativeX`, `cursorOnTopEdgeOfSecondaryDisplay`, `flipsNearRightAndBottomEdges`, `avoidRectForcesAlternative`, `fullScreenSpaceStaysInside`; Task 6 `panelFlags`; Task 7 `savedPositionOnMissingDisplayFallsBack`)*
3. **Dollar signs and malformed LaTeX**: prices (`$5 and $6`), shell code (`` `echo $HOME` ``), escaped `\$`, half-streamed `$$\int x` and broken `$\frac{1}{$` render as readable text; underscores inside math never become emphasis; backslashes survive Swift → JS. *(Task 3 `math.test.js`; Task 4 `deltaTextSurvivesTheBridge`)*
4. **Very long streamed answers and huge code/math blocks**: the bubble grows to 520 then scrolls internally, stays inside the screen while growing, re-renders at most ~30×/s however fast tokens arrive, and wide blocks scroll horizontally instead of widening the bubble. *(Task 1 `resizedKeepsTheCursorSideEdgeAndStaysInside`; Task 3 `appendDelta is throttled…`, `wide blocks scroll inside the answer…`; Task 4 `reportsContentHeightForLongAnswers`; Task 6 `contentGrowthClampsInsideTheScreen`)*
5. **Rapid show/hide** (hotkey/Esc mashing, repeated summons): one panel instance, visible and opaque after the last show, no stray glow windows, a stale glow timer never closes a newer glow. *(Task 6 `rapidShowHideKeepsOnePanel`; Task 8 `rapidFlashesKeepOneGlow`)*

---

### Task 1: Bubble geometry (placement and sizing)

**Files:**
- Delete: `Sources/CompanionUI/CompanionUI.swift`, `Tests/CompanionUITests/PlaceholderTests.swift` (WS0 placeholders)
- Create: `Sources/CompanionUI/Bubble/BubbleGeometry.swift`
- Test: `Tests/CompanionUITests/BubblePlacementTests.swift`

**Interfaces:**
- Produces (internal):
```swift
typealias ScreenGeometry = (frame: CGRect, visibleFrame: CGRect)
enum BubbleMetrics {
    static let width: CGFloat = 380, minHeight: CGFloat = 72, maxHeight: CGFloat = 520, cornerRadius: CGFloat = 14
    static let cursorOffset = CGVector(dx: 16, dy: -16)
    static let popOutSize = CGSize(width: 640, height: 720), popOutMinSize = CGSize(width: 480, height: 400)
    static func clampedHeight(_ contentHeight: CGFloat) -> CGFloat            // min(max(h, 72), 520)
}
enum BubblePlacement {
    static func frame(cursor: CGPoint, size: CGSize, screens: [ScreenGeometry], avoid: CGRect?) -> CGRect
    /// Keeps the top edge (anchorTop) or bottom edge fixed, then shifts/clamps into visibleFrame.
    static func resized(_ frame: CGRect, toHeight height: CGFloat, anchorTop: Bool, visibleFrame: CGRect) -> CGRect
    static func screen(for point: CGPoint, in screens: [ScreenGeometry]) -> ScreenGeometry?   // max edges inclusive
    @MainActor static func currentScreens() -> [ScreenGeometry]                                // NSScreen.screens, in order
}
```

- [ ] **Step 1: Write the failing tests**

```swift
let main = (frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 60, width: 1512, height: 889))
let left = (frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055))
let size = CGSize(width: 380, height: 200)
func place(_ x: CGFloat, _ y: CGFloat, _ screens: [ScreenGeometry] = [main], avoid: CGRect? = nil, size: CGSize = size) -> CGRect {
    BubblePlacement.frame(cursor: CGPoint(x: x, y: y), size: size, screens: screens, avoid: avoid)
}
func resize(_ f: CGRect, _ h: CGFloat, top: Bool) -> CGRect { BubblePlacement.resized(f, toHeight: h, anchorTop: top, visibleFrame: main.visibleFrame) }
func r(_ x: CGFloat, _ y: CGFloat, _ h: CGFloat = 200) -> CGRect { CGRect(x: x, y: y, width: 380, height: h) }
@Test func rightBelowByDefault() { #expect(place(600, 600) == r(616, 384)) }
@Test func secondaryDisplayAtNegativeX() { let f = place(-1000, 600, [main, left]); #expect(f == r(-984, 384) && left.visibleFrame.contains(f)) }
@Test func cursorOnTopEdgeOfSecondaryDisplay() { #expect(place(-1000, 1080, [main, left]) == r(-984, 855)) }   // mouseLocation.y can equal maxY
@Test func flipsNearRightAndBottomEdges() {
    #expect(place(1400, 600) == r(1004, 384)); #expect(place(200, 150) == r(216, 166)); #expect(place(1400, 150) == r(1004, 166))
}
@Test func avoidRectForcesAlternative() { #expect(place(600, 600, avoid: CGRect(x: 610, y: 300, width: 500, height: 290)) == r(204, 384)) }
@Test func unavoidableAvoidFallsBackToFirstInside() {
    #expect(place(600, 600, avoid: main.visibleFrame) == r(616, 384))
}
@Test func avoidAroundCursorMovesBesideIt() {   // region selection under the cursor: cursor candidates all overlap → right-of the selection
    #expect(place(600, 600, avoid: CGRect(x: 450, y: 500, width: 300, height: 200)) == r(762, 384))
}
@Test func fullScreenSpaceStaysInside() {
    let fs = (frame: main.frame, visibleFrame: main.frame); let f = place(1500, 10, [fs])
    #expect(f == r(1104, 26) && fs.visibleFrame.contains(f))
}
@Test func oversizeAndOffscreenAreClamped() {
    #expect(place(600, 600, size: CGSize(width: 380, height: 2000)) == r(616, 60, 889))
    #expect(main.visibleFrame.contains(place(5000, 5000, [main, left])))   // cursor off every screen → first screen
}
@Test func resizedKeepsTheCursorSideEdgeAndStaysInside() {
    #expect(resize(r(616, 384), 300, top: true) == r(616, 284, 300)); #expect(resize(r(616, 100, 72), 520, top: true) == r(616, 60, 520))
    #expect(resize(r(216, 166), 400, top: false) == r(216, 166, 400)); #expect(resize(r(216, 700), 2000, top: false) == r(216, 60, 889))
}
@Test func clampedHeight() { #expect([10, 300, 5000].map(BubbleMetrics.clampedHeight) == [72, 300, 520]) }
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter CompanionUITests` → FAIL (`BubblePlacement` not defined).

- [ ] **Step 3: Implement `BubbleGeometry.swift`**

`frame`: screen = `screen(for: cursor)` ?? `screens.first` (no screens → right-below unclamped). Candidates with offset (16, −16), w/h = size: right-below `(c.x+16, c.y−16−h)`, left-below `(c.x−16−w, c.y−16−h)`, right-above `(c.x+16, c.y+16)`, left-above `(c.x−16−w, c.y+16)`. Then, when `avoid` is non-nil, the beside-avoid candidates: right-of `(avoid.maxX+12, c.y−16−h)`, left-of `(avoid.minX−12−w, c.y−16−h)`, below `(c.x+16, avoid.minY−12−h)`, above `(c.x+16, avoid.maxY+12)`. Return the first candidate (cursor ones first) inside `visibleFrame` that doesn't intersect `avoid`; else the first cursor candidate inside `visibleFrame`; else right-below with its size capped to `visibleFrame.size` and its origin clamped into `visibleFrame`. `resized` caps height to `visibleFrame.height`, keeps `maxY` (anchorTop) or `minY`, then shifts vertically into `visibleFrame`.

- [ ] **Step 4: Run to verify pass** — `swift test --filter CompanionUITests` → PASS.

- [ ] **Step 5: Commit** — `git add Sources/CompanionUI Tests/CompanionUITests && git commit -m "feat(ui): bubble placement and sizing geometry"`

---

### Task 2: Bubble model types, key commands, view model

**Files:**
- Create: `Sources/CompanionUI/Bubble/BubbleModels.swift`, `Sources/CompanionUI/Bubble/BubbleKeyCommand.swift`, `Sources/CompanionUI/Bubble/BubbleViewModel.swift`
- Create: `Tests/CompanionUITests/Support/TestSupport.swift`
- Test: `Tests/CompanionUITests/BubbleViewModelTests.swift`, `Tests/CompanionUITests/BubbleKeyCommandTests.swift`

**Interfaces:**
- Consumes: `CapturedContext` (`removingItem`), `ContextItem` (`chipLabel`, `isRemovable`), `RenderedPage`, `DocumentChoice`, `DriveFileRef`, `LLMRole` from CompanionCore.
- Produces — the overview's API, verbatim:
```swift
@MainActor public protocol BubbleActions: AnyObject {
    func bubbleDidSubmit(_ text: String)
    func bubbleDidRemoveContextItem(_ id: UUID)
    func bubbleDidRequestModelCycle()
    func bubbleDidToggleHint()
    func bubbleDidRequestNewChat()
    func bubbleDidClose()
    func bubbleDidRequestSettings()
    func bubbleDidSelectDocument(_ file: DriveFileRef)
    func bubbleDidRequestModelSwitchAfterError()
}
public struct ThreadMessage: Identifiable, Equatable, Sendable {
    public var id: UUID; public var role: LLMRole; public var markdown: String; public var isStreaming: Bool
}
public enum StepState: Sendable, Equatable { case done, active, failed }
public struct StepItem: Identifiable, Equatable, Sendable { public var id: UUID; public var text: String; public var state: StepState }
public struct BubbleErrorBanner: Equatable, Sendable {
    public var message: String; public var offerModelSwitch: Bool; public var offerSettings: Bool
}
@MainActor @Observable public final class BubbleViewModel {
    public init()
    public weak var actions: (any BubbleActions)?
    public var inputText: String
    public private(set) var context: CapturedContext?
    public private(set) var thread: [ThreadMessage]
    public private(set) var steps: [StepItem]
    public private(set) var pageThumbnails: [RenderedPage]
    public private(set) var documentChoice: DocumentChoice?
    public private(set) var modelName: String
    public private(set) var hintMode: Bool
    public private(set) var isBusy: Bool
    public private(set) var error: BubbleErrorBanner?
    public func setContext(_ context: CapturedContext?)
    public func setModelName(_ name: String)
    public func setHintMode(_ on: Bool)
    public func resetThread(_ messages: [ThreadMessage])
    @discardableResult public func appendUserMessage(_ text: String) -> UUID
    public func beginAssistantMessage() -> UUID
    public func appendDelta(_ text: String, to id: UUID)
    public func finishAssistantMessage(_ id: UUID)
    public func setSteps(_ steps: [StepItem])
    public func setPageThumbnails(_ pages: [RenderedPage])
    public func setDocumentChoice(_ choice: DocumentChoice?)
    public func showError(_ banner: BubbleErrorBanner?)
    public func setBusy(_ busy: Bool)
}
```
- Produces — WS6 additions:
```swift
// public memberwise inits (Swift synthesizes only internal ones; WS7 constructs these)
public init(id: UUID = UUID(), role: LLMRole, markdown: String, isStreaming: Bool = false)      // ThreadMessage
public init(id: UUID = UUID(), text: String, state: StepState)                                  // StepItem
public init(message: String, offerModelSwitch: Bool = false, offerSettings: Bool = false)       // BubbleErrorBanner
// internal
enum BubbleKeyCommand: Equatable {
    case submit, insertNewline, close, cycleModel, toggleHint, newChat
    static func from(keyCode: UInt16, charactersIgnoringModifiers: String?, modifiers: NSEvent.ModifierFlags) -> BubbleKeyCommand?
}
// internal members of BubbleViewModel
var inputPlaceholder: String { get }          // "Ask about this…" when thread is empty, else "Follow up…"
func submit(); func removeContextItem(_ id: UUID); func cycleModel(); func toggleHint(); func newChat()
func close(); func openSettings(); func switchModelAfterError(); func selectDocument(_ file: DriveFileRef)
@discardableResult func handle(_ command: BubbleKeyCommand) -> Bool   // false only for .insertNewline (caller inserts it)
// Tests/CompanionUITests/Support/TestSupport.swift
@MainActor final class RecordingBubbleActions: BubbleActions {
    enum Call: Equatable { case submit(String), removeItem(UUID), cycleModel, toggleHint, newChat, close, settings,
                           selectDocument(DriveFileRef), switchModelAfterError }
    private(set) var calls: [Call]
}
@MainActor @Suite(.serialized) enum WindowTests {}            // parent of every window/web-view suite
@MainActor enum TestApp { static func ensure() }              // NSApplication.shared + .accessory policy, once
func keyEvent(_ keyCode: UInt16, _ chars: String, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent   // .keyDown
let youtubeSample: YouTubeContext   // "Solving Quadratics by Factoring", chapter "Finding the roots", playhead 761
```

Rules (decisions): `init()` defaults are empty/nil/false and `modelName == ""`. Mutators set only their own field. `beginAssistantMessage` appends `(role: .assistant, markdown: "", isStreaming: true)`; `appendDelta` appends only to the message with that id **and** `isStreaming == true`; `finishAssistantMessage` clears `isStreaming`. Each intent calls exactly one `actions` method and changes no state, except: `submit()` trims whitespace/newlines, ignores an empty result (no call, input untouched), otherwise calls `bubbleDidSubmit(trimmed)` and sets `inputText = ""`; `removeContextItem` ignores absent or non-removable ids, otherwise removes the item locally at once (`context.removingItem`) and then calls `bubbleDidRemoveContextItem`. The view model never echoes model/hint/new-chat/close state — WS7 answers with `setModelName`, `setHintMode`, `resetThread`, `BubbleController.hide()`.

Key mapping: modifiers masked to `[.command, .shift, .option, .control]`. Return (36) / keypad Enter (76): no modifiers → `.submit`, `[.shift]` → `.insertNewline`. Tab (48), no modifiers → `.cycleModel`. Esc (53) → `.close`. `[.command]` with `charactersIgnoringModifiers` lowercased `"h"` → `.toggleHint`, `"n"` → `.newChat` (characters, not key codes, so non-QWERTY layouts work). Anything else → `nil`.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor struct BubbleViewModelTests {
    let vm = BubbleViewModel(); let rec = RecordingBubbleActions()
    init() { vm.actions = rec }
    @Test func submitTrimsClearsAndIgnoresEmpty() {
        vm.inputText = "   \n"; vm.submit(); #expect(rec.calls.isEmpty); #expect(vm.inputText == "   \n")
        vm.inputText = "  why does 3 become x here?\n"; vm.submit()
        #expect(rec.calls == [.submit("why does 3 become x here?")]); #expect(vm.inputText == "")
    }
    @Test func removingAChipRemovesLocallyAndNotifies() {
        let win = ContextItem(piece: .windowImage(Fixtures.samplePNG())), note = ContextItem(piece: .notice(.extensionNotConnected))
        vm.setContext(CapturedContext(front: nil, privacy: .allowed, kind: .genericWindow, items: [win, note], isComplete: true))
        vm.removeContextItem(win.id); vm.removeContextItem(note.id); vm.removeContextItem(UUID())
        #expect(rec.calls == [.removeItem(win.id)]); #expect(vm.context?.items.map(\.id) == [note.id])
    }
    @Test func intentsRouteToActions() {
        let ws = DriveFileRef(fileId: "w", title: "Worksheet 5.2.pdf", mimeType: nil)
        for c in [BubbleKeyCommand.cycleModel, .toggleHint, .newChat, .close] { #expect(vm.handle(c)) }
        #expect(vm.handle(.insertNewline) == false)
        vm.openSettings(); vm.switchModelAfterError(); vm.selectDocument(ws)
        #expect(rec.calls == [.cycleModel, .toggleHint, .newChat, .close, .settings, .switchModelAfterError, .selectDocument(ws)])
        #expect(vm.hintMode == false)            // no optimistic echo
    }
    @Test func appendDeltaOnlyToStreamingMessage() {
        let u = vm.appendUserMessage("q"); vm.appendDelta("x", to: u); #expect(vm.thread[0].markdown == "q")
        let a = vm.beginAssistantMessage(); vm.appendDelta("Hel", to: a); vm.appendDelta("lo", to: a)
        #expect(vm.thread[1] == ThreadMessage(id: a, role: .assistant, markdown: "Hello", isStreaming: true))
        vm.finishAssistantMessage(a); vm.appendDelta("!", to: a); vm.appendDelta("?", to: UUID())
        #expect(vm.thread[1].markdown == "Hello" && vm.thread[1].isStreaming == false)
    }
    @Test func settersStoreValues() { /* each of setContext(nil), setModelName("Sonnet 5.5"), setHintMode(true), resetThread([m]),
        setSteps([s]), setPageThumbnails([p]), setDocumentChoice(c), showError(b) then showError(nil), setBusy(true):
        the matching property equals what was set and nothing else changed */ }
    @Test func placeholderFollowsThread() {
        #expect(vm.inputPlaceholder == "Ask about this…"); vm.appendUserMessage("q"); #expect(vm.inputPlaceholder == "Follow up…")
    }
}
struct BubbleKeyCommandTests {
    func cmd(_ k: UInt16, _ c: String, _ m: NSEvent.ModifierFlags = []) -> BubbleKeyCommand? {
        BubbleKeyCommand.from(keyCode: k, charactersIgnoringModifiers: c, modifiers: m)
    }
    @Test func mapping() {
        #expect(cmd(36, "\r") == .submit); #expect(cmd(76, "\u{3}", [.numericPad]) == .submit)
        #expect(cmd(36, "\r", [.shift]) == .insertNewline); #expect(cmd(48, "\t") == .cycleModel); #expect(cmd(53, "\u{1b}") == .close)
        #expect(cmd(4, "h", [.command]) == .toggleHint); #expect(cmd(38, "h", [.command]) == .toggleHint)   // Dvorak position
        #expect(cmd(45, "n", [.command]) == .newChat)
        #expect(cmd(4, "h", [.command, .shift]) == nil); #expect(cmd(0, "a") == nil)
        #expect(cmd(48, "\t", [.shift]) == nil); #expect(cmd(36, "\r", [.command]) == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter CompanionUITests` → FAIL (types not defined).
- [ ] **Step 3: Implement** `BubbleModels.swift`, `BubbleKeyCommand.swift`, `BubbleViewModel.swift` and `TestSupport.swift` with the declarations and rules above.
- [ ] **Step 4: Run to verify pass** — `swift test --filter CompanionUITests` → PASS.
- [ ] **Step 5: Commit** — `git add Sources/CompanionUI Tests/CompanionUITests && git commit -m "feat(ui): bubble view model, actions and key commands"`

---

### Task 3: Answer renderer (`ui-web/` → `Resources/web/`)

**Files:**
- Create: `ui-web/package.json`, `ui-web/package-lock.json`, `ui-web/build.mjs`, `ui-web/vitest.config.js`, `ui-web/static/index.html`, `ui-web/src/math.js`, `ui-web/src/markdown.js`, `ui-web/src/companion.js`, `ui-web/src/main.js`
- Test: `ui-web/test/math.test.js`, `ui-web/test/companion.test.js`, `ui-web/test/styles.test.js`
- Generated and committed: `Sources/CompanionUI/Resources/web/index.html` (replaces the WS0 placeholder), `renderer.js`, `katex.min.css`, `fonts/*.woff2`

**Interfaces:**
- Produces (plain ES modules; no TypeScript — the devDependencies are exactly markdown-it, katex, esbuild, vitest, jsdom):
```js
// src/math.js
export function protectMath(markdown)            // → { text, spans: [{ tex, display }] }; each span replaced by "<n>"
export function restoreMath(html, spans, renderTex)   // → html with tokens replaced by renderTex(tex, display)
// src/markdown.js
export function renderMarkdown(markdown)         // → HTML; markdown-it { html: false, linkify: false }, md.disable('image'),
                                                 //   KaTeX renderToString(tex, { displayMode, throwOnError: false })
export function renderAssistant(markdown)        // a first line starting "Reading:" → <div class="reading">…</div>, rest via renderMarkdown
// src/companion.js
export function createCompanion(root, { post = () => {}, minIntervalMs = 33 } = {})
//   → { render(thread), appendDelta(id, text), debugMarkdown(id), renderCount() }
//   thread: JSON string or array of { id, role: "user" | "assistant", markdown, isStreaming }
// src/main.js — window.companion = createCompanion(#thread, { post: m => window.webkit?.messageHandlers?.companion?.postMessage(m) });
//   then post({ type: "ready" })
```
- Messages to Swift: `{ type: "ready" }` once; `{ type: "height", value: <integer px> }` after every render (read `root.scrollHeight`, which forces layout) and on `ResizeObserver` changes.
- DOM: `#thread > .msg.user[data-id] > .q` (user markdown) and `.msg.assistant[data-id]` (`renderAssistant`); a streaming assistant message with empty markdown shows `.typing` (three animated dots) so the bubble is never blank.

Math rules (the tests pin them): (1) fenced code blocks and inline code spans are copied verbatim, never math; (2) `\$` stays literal; (3) `$$…$$` and `\[…\]` are display, `\(…\)` and `$…$` inline; (4) inline `$…$` only when the character after the opening `$` is not whitespace, the closing `$` is not preceded by whitespace and not followed by a digit, and no blank line lies between; (5) unclosed delimiters stay literal; (6) KaTeX output is memoized by `(display, tex)` in a `Map` cleared above 500 entries, so re-rendering a streaming message doesn't re-typeset unchanged math.

Companion behaviour: `render` replaces everything. `appendDelta` appends to the stored markdown of that id (unknown id → ignored) and schedules a re-render of only that message with `setTimeout`, at most once per `minIntervalMs`. After a render, if any message is streaming and the scroller was within 24 px of the bottom before the render, scroll to the bottom.

`static/index.html`: `<link rel="stylesheet" href="katex.min.css">`, `<div id="thread"></div>`, `<script src="renderer.js"></script>`, and a `<style>` with the mockup tokens: `html, body { background: transparent; margin: 0 }`, body `-apple-system` 13px / 1.45 #ECECF0, `.q` #A1A1A6, `.reading` (serif #A1A1A6, 2px #0A84FF left border, 6px left padding), `code` monospace on white 8 %, links #0A84FF, `.typing` dots, and — written as longhands so jsdom computes them — `pre { overflow-x: auto; white-space: pre }`, `.katex-display { overflow-x: auto; overflow-y: hidden }`.

`build.mjs`: empties `../Sources/CompanionUI/Resources/web/`, bundles `src/main.js` with esbuild (`bundle`, `format: 'iife'`, `target: 'safari17'`, `minify`, `legalComments: 'eof'`) to `renderer.js`, copies `static/index.html`, `node_modules/katex/dist/katex.min.css`, and `node_modules/katex/dist/fonts/*.woff2` into `fonts/`. `package.json`: `"private": true`, `"type": "module"`, scripts `build` = `node build.mjs`, `test` = `vitest run`. `vitest.config.js`: `environment: 'jsdom'`.

- [ ] **Step 1: Scaffold** — create `package.json` (scripts above), then `cd ui-web && npm install --save-dev markdown-it@14 katex@0.16 esbuild vitest jsdom` (writes the lockfile; `ui-web/node_modules/` is already git-ignored).

- [ ] **Step 2: Write the failing tests**

```js
// test/math.test.js
import { renderMarkdown, renderAssistant } from '../src/markdown.js';
const dom = (md, f = renderMarkdown) => { const d = document.createElement('div'); d.innerHTML = f(md); return d; };
const katexCount = (md) => dom(md).querySelectorAll('.katex').length;
test('math renders with KaTeX', () => {
  expect(katexCount('$x^2$')).toBe(1); expect(dom('$$\\int x\\,dx$$').querySelector('.katex-display')).not.toBeNull();
  expect(katexCount('\\(a\\) and \\[b\\]')).toBe(2);
  const d = dom('$a_1 + b_1$ and $c_2$'); expect(d.querySelectorAll('.katex').length).toBe(2); expect(d.querySelector('em')).toBeNull();
});
test('dollar signs that are not math stay literal', () => {
  for (const s of ['It costs $5 and $6 today.', "That's $5.", 'costs $5\n\nthen $6', '\\$x\\$', '$$\\int x']) expect(katexCount(s)).toBe(0);
  expect(dom('It costs $5 and $6 today.').textContent).toContain('$5 and $6');
  expect(dom('\\$x\\$').textContent).toContain('$x$'); expect(dom('$$\\int x').textContent).toContain('$$\\int x');   // unclosed while streaming
  expect(dom('`echo $HOME $PATH`').querySelector('code').textContent).toBe('echo $HOME $PATH');
  expect(dom('```\n$x$\n```').querySelector('pre').textContent).toContain('$x$'); expect(katexCount('```\n$x$\n```')).toBe(0);
});
test('malformed LaTeX never throws and keeps the rest', () => {
  const d = dom('before $\\frac{1}{$ after'); expect(d.querySelector('.katex-error')).not.toBeNull(); expect(d.textContent).toContain('after');
});
test('raw HTML and images from the model are not rendered', () => {
  expect(dom('<script>alert(1)</script> ![x](http://example.com/a.png)').querySelector('script, img')).toBeNull();
});
test('Reading line', () => {
  const d = dom('Reading: $x^2-5x+6=0$\n\nAt 12:20 he factored it.', renderAssistant);
  expect(d.querySelector('.reading .katex')).not.toBeNull(); expect(d.querySelector('.reading').textContent).not.toContain('12:20');
});
```
```js
// test/companion.test.js
import { createCompanion } from '../src/companion.js';
let root, post, c;
beforeEach(() => { document.body.innerHTML = '<div id="thread"></div>'; root = document.getElementById('thread');
  post = vi.fn(); c = createCompanion(root, { post }); vi.useFakeTimers(); });
afterEach(() => vi.useRealTimers());
const msg = (id, role, markdown, isStreaming) => ({ id, role, markdown, isStreaming });
test('render builds one element per message and reports height', () => {
  c.render(JSON.stringify([msg('u', 'user', 'why?', false), msg('a', 'assistant', '', true)]));
  expect(root.querySelectorAll('.msg').length).toBe(2); expect(root.querySelector('.msg.user .q').textContent.trim()).toBe('why?');
  expect(root.querySelector('[data-id="a"] .typing')).not.toBeNull();
  expect(post).toHaveBeenCalledWith(expect.objectContaining({ type: 'height' }));
});
test('appendDelta is throttled to one render per 33 ms', () => {
  c.render([msg('a', 'assistant', '', true)]); const r0 = c.renderCount();
  for (let i = 0; i < 1000; i++) c.appendDelta('a', 'x ');
  expect(c.renderCount()).toBe(r0); vi.advanceTimersByTime(33); expect(c.renderCount()).toBe(r0 + 1);
  expect(root.textContent.match(/x/g).length).toBe(1000);
  for (let i = 0; i < 300; i++) { c.appendDelta('a', '$y$ '); vi.advanceTimersByTime(5); }
  vi.advanceTimersByTime(33);
  expect(c.renderCount() - r0 - 1).toBeLessThanOrEqual(Math.ceil(1500 / 33) + 2); expect(c.debugMarkdown('a').length).toBe(3200);
  c.appendDelta('zzz', 'x'); expect(c.debugMarkdown('zzz')).toBeNull();   // unknown ids are ignored
});
```
```js
// test/styles.test.js
import { JSDOM } from 'jsdom'; import fs from 'node:fs';
test('wide blocks scroll inside the answer instead of widening the bubble', () => {
  const { window } = new JSDOM(fs.readFileSync(new URL('../static/index.html', import.meta.url), 'utf8'));
  const d = window.document; d.body.insertAdjacentHTML('beforeend', '<pre>x</pre><span class="katex-display">y</span>');
  for (const sel of ['pre', '.katex-display']) expect(window.getComputedStyle(d.querySelector(sel)).overflowX).toBe('auto');
});
```

- [ ] **Step 3: Run to verify failure** — `cd ui-web && npm test` → FAIL (modules missing).
- [ ] **Step 4: Implement** `src/math.js`, `src/markdown.js`, `src/companion.js`, `src/main.js`, `static/index.html`, `build.mjs`, `vitest.config.js` per the rules above.
- [ ] **Step 5: Run to verify pass** — `cd ui-web && npm test` → all tests PASS.
- [ ] **Step 6: Build and check the output** — `cd ui-web && npm run build && ls ../Sources/CompanionUI/Resources/web ../Sources/CompanionUI/Resources/web/fonts` → `index.html`, `renderer.js`, `katex.min.css`, `fonts/` with `KaTeX_Main-Regular.woff2` among ~20 woff2 files. Then `swift build` → succeeds.
- [ ] **Step 7: Commit** — `git add ui-web Sources/CompanionUI/Resources/web && git commit -m "feat(ui): markdown + KaTeX answer renderer with throttled streaming"`

---

### Task 4: Answer web view (Swift side)

**Files:**
- Create: `Sources/CompanionUI/Answer/AnswerRenderDiff.swift`, `Sources/CompanionUI/Answer/AnswerWebController.swift`, `Sources/CompanionUI/Answer/AnswerWebView.swift`
- Test: `Tests/CompanionUITests/AnswerRenderDiffTests.swift`, `Tests/CompanionUITests/AnswerWebViewTests.swift`

**Interfaces:**
- Consumes: `ThreadMessage` (Task 2); the JS API and `ready`/`height` messages (Task 3); `WindowTests`, `TestApp` (Task 2).
- Produces (internal):
```swift
enum AnswerRenderCommand: Equatable { case none, render([ThreadMessage]), append(id: UUID, text: String) }
enum AnswerRenderDiff { static func command(from old: [ThreadMessage], to new: [ThreadMessage]) -> AnswerRenderCommand }
enum AnswerScript { static func script(for command: AnswerRenderCommand) -> String? }   // nil for .none; arguments JSON-encoded
@MainActor final class AnswerWebController: NSObject {
    init()                                   // creates the WKWebView and loads web/index.html from Bundle.module immediately
    let webView: WKWebView
    private(set) var isReady: Bool
    var onContentHeight: ((CGFloat) -> Void)?
    func apply(_ thread: [ThreadMessage])    // before ready: keep only the latest; on ready: full render of it, then diffs
    func waitUntilReady(timeout: Duration) async throws
    func evaluate(_ script: String) async throws -> Any?
}
struct AnswerWebView: NSViewRepresentable { let controller: AnswerWebController; let thread: [ThreadMessage] }
// makeNSView returns controller.webView; updateNSView calls controller.apply(thread)
```

Diff rule: `.none` when equal; `.append(id:text:)` only when both threads have the same ids, roles and `isStreaming` flags, every message but the last is unchanged, the last is streaming, and its new markdown strictly extends the old one; otherwise `.render(new)`. Scripts: `window.companion.render(<JSON array of {id, role, markdown, isStreaming}>)` (ids as `uuidString`) and `window.companion.appendDelta(<JSON string>, <JSON string>)`, encoded with `JSONEncoder` (never string interpolation — LaTeX backslashes and quotes must survive).

Web view decisions: transparent via `webView.setValue(false, forKey: "drawsBackground")`; message handler `companion` registered through a weak proxy (`WKUserContentController` retains its handlers); `loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())` with `Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "web")`; the navigation delegate allows only that initial file load and sends `.linkActivated` URLs to `NSWorkspace.shared.open` (cancelling in-view navigation). Created once per bubble at launch, so the first summon never pays WebKit start-up.

- [ ] **Step 1: Write the failing tests**

```swift
struct AnswerRenderDiffTests {
    let u = ThreadMessage(role: .user, markdown: "q"), a = ThreadMessage(role: .assistant, markdown: "Hel", isStreaming: true)
    func with(_ m: ThreadMessage, _ change: (inout ThreadMessage) -> Void) -> ThreadMessage { var c = m; change(&c); return c }
    @Test func diffs() {
        #expect(AnswerRenderDiff.command(from: [u], to: [u]) == .none)
        #expect(AnswerRenderDiff.command(from: [u, a], to: [u, with(a) { $0.markdown = "Hello" }]) == .append(id: a.id, text: "lo"))
        for new in [[u, a, ThreadMessage(role: .user, markdown: "again")], [u, with(a) { $0.markdown = "Help" }],
                    [u, with(a) { $0.isStreaming = false }], []] {
            #expect(AnswerRenderDiff.command(from: [u, a], to: new) == .render(new))
        }
    }
    @Test func scriptsUseJSONArguments() throws {
        let id = UUID(); let s = try #require(AnswerScript.script(for: .append(id: id, text: "\"q\" \\frac{1}{2} </script>")))
        #expect(s.hasPrefix("window.companion.appendDelta(\"\(id.uuidString)\",") && !s.contains("</script>"))
        #expect(AnswerScript.script(for: .none) == nil)
    }
}
extension WindowTests { @MainActor @Suite struct AnswerWebViewTests {
    // each test: TestApp.ensure(); c = AnswerWebController() hosted in an off-screen 380×300 NSWindow
    @Test func webResourcesArePresent() {
        for f in ["index.html", "renderer.js", "katex.min.css"] { #expect(Bundle.module.url(forResource: f, withExtension: nil, subdirectory: "web") != nil) }
        // and every "fonts/<name>.woff2" referenced in katex.min.css exists under web/fonts
    }
    @Test func rendersKaTeXInWebView() async throws {
        c.apply([ThreadMessage(role: .assistant, markdown: "$x^2$")])     // before the page has loaded
        try await c.waitUntilReady(timeout: .seconds(10))
        #expect(try await c.evaluate("document.querySelectorAll('.katex').length > 0") as? Bool == true)
    }
    @Test func deltaTextSurvivesTheBridge() async throws {
        let id = UUID(), tricky = "\\frac{1}{2} \"q\" </script>\n\u{2028}$5 and $6 \\$"
        c.apply([ThreadMessage(id: id, role: .assistant, markdown: "", isStreaming: true)]); try await c.waitUntilReady(timeout: .seconds(10))
        c.apply([ThreadMessage(id: id, role: .assistant, markdown: tricky, isStreaming: true)])
        #expect(try await c.evaluate("window.companion.debugMarkdown('\(id.uuidString)')") as? String == tricky)
    }
    @Test func reportsContentHeightForLongAnswers() async throws {
        var heights: [CGFloat] = []; c.onContentHeight = { heights.append($0) }
        c.apply([ThreadMessage(role: .assistant, markdown: (1...60).map { "Paragraph \($0) with $x_\($0)$." }.joined(separator: "\n\n"))])
        try await c.waitUntilReady(timeout: .seconds(10))   // then poll up to 2 s (50 ms sleeps) for a height message
        #expect((heights.last ?? 0) > 520)
    }
}}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter CompanionUITests` → FAIL (types not defined).
- [ ] **Step 3: Implement** the three files per the rules above. `waitUntilReady` throws `AnswerWebError.timeout` (internal enum) when `ready` hasn't arrived in time.
- [ ] **Step 4: Run to verify pass** — `swift test --filter CompanionUITests` → PASS. A timeout here means WebKit couldn't load the bundle (check the `web/` subdirectory name and read access); fix that, don't mock WebKit.
- [ ] **Step 5: Commit** — `git add Sources/CompanionUI Tests/CompanionUITests && git commit -m "feat(ui): answer web view with diffed streaming updates"`

---

### Task 5: Bubble view and input field

**Files:**
- Create: `Sources/CompanionUI/Theme.swift`, `Sources/CompanionUI/Bubble/ChipModel.swift`, `Sources/CompanionUI/Bubble/BubbleInputTextView.swift`, `Sources/CompanionUI/Bubble/BubbleView.swift`
- Test: `Tests/CompanionUITests/ChipModelTests.swift`, `Tests/CompanionUITests/BubbleInputTests.swift`

**Interfaces:**
- Consumes: `BubbleViewModel`, `BubbleKeyCommand`, test support (Task 2); `AnswerWebController`, `AnswerWebView` (Task 4); `BubbleMetrics` (Task 1).
- Produces (internal):
```swift
enum Theme { /* the mockup tokens from Global Constraints as Color/NSColor/CGFloat constants */ }
struct ChipModel: Identifiable, Equatable {
    let id: UUID; let label: String; let isRemovable: Bool; let thumbnailPNG: Data?   // PNG only for .windowImage / .regionImage
    static func chips(from context: CapturedContext?) -> [ChipModel]
}
final class BubbleInputTextView: NSTextView {
    init(viewModel: BubbleViewModel)
    func syncFromViewModel()                 // string = viewModel.inputText when they differ
}
struct BubbleView: View {
    enum Style { case bubble, window }       // .bubble: width 380, height ≤ 520; .window: fills its window
    init(viewModel: BubbleViewModel, answer: AnswerWebController, input: BubbleInputTextView, style: Style,
         onPopOut: @escaping () -> Void, onContentHeight: @escaping (CGFloat) -> Void)
}
```

Input decisions: an `NSTextView` (not a SwiftUI `TextField`) because focus must be set synchronously in a non-activating panel and Return/Tab/Esc must be intercepted before AppKit's defaults (Esc would trigger `complete:`). `keyDown(with:)`: if `hasMarkedText()` → `super` (IME owns every key); else map with `BubbleKeyCommand.from`; `.insertNewline` → `insertNewlineIgnoringFieldEditor(nil)`; any other command → `viewModel.handle`, then `syncFromViewModel()`; no command → `super`. `didChangeText` writes `string` to `viewModel.inputText`. 13 pt system font, white text, caret #0A84FF, transparent background; grows to 5 lines, then scrolls inside an `NSScrollView`. The placeholder is a SwiftUI overlay of `viewModel.inputPlaceholder` shown while `inputText` is empty.

`BubbleView` layout, top to bottom (each block only when it has content), padding 12, spacing 8:
1. Header: chips in a wrapping `Layout` (thumbnail 26×17 decoded once per chip id with `CGImageSourceCreateThumbnailAtIndex`, max 64 px, cached; label; `✕` button → `viewModel.removeContextItem` only when removable); trailing `↗ pop out` (style `.bubble`, thread non-empty) → `onPopOut`.
2. Document chip `using: <current.title>` as a `Menu` listing `alternatives` minus `current` → `viewModel.selectDocument`.
3. Steps: `✓` / `●` / `✕` glyph in its colour + text.
4. Page thumbnails: 34×44 images from `RenderedPage.image.png`, `printedLabel` bottom-right.
5. Answer: `AnswerWebView` when the thread is non-empty; ideal height = the last JS content height, compressible to fill what's left under 520 (the web view then scrolls itself).
6. Error banner: message + `Switch model` (`offerModelSwitch` → `switchModelAfterError`) and `Open Settings` (`offerSettings` → `openSettings`).
7. Input field (bg white 8 %, radius 8).
8. Footer: left — small spinner while `isBusy`, `modelName`, keycap `⇥`, `switch`, plus ` · new chat ⌘N` once the thread is non-empty; right — `Hints ⌘H` (highlighted when `hintMode`), `Esc to close`.

Background: `NSVisualEffectView` (`.hudWindow`, `.behindWindow`, **`state = .active`** — the app is never active, and an inactive effect view goes flat) under the #1C1C1E 92 % fill, `.darkAqua` appearance, corner radius 14. The view reports its ideal height (measured with `fixedSize(horizontal: false, vertical: true)` in a background `GeometryReader` → `PreferenceKey`) through `onContentHeight`.

- [ ] **Step 1: Write the failing tests**

```swift
struct ChipModelTests {
    @Test func chipsFromContext() {
        let png = Fixtures.samplePNG()
        let ctx = CapturedContext(front: nil, privacy: .allowed, kind: .youtube, items: [
            ContextItem(piece: .windowImage(png)), ContextItem(piece: .youtubeVideo(youtubeSample)),
            ContextItem(piece: .transcriptWindow(segments: [], from: 581, to: 761)), ContextItem(piece: .notice(.extensionNotConnected))],
            isComplete: true)
        let chips = ChipModel.chips(from: ctx)
        #expect(chips.map(\.label) == ["window", "▶ 12:41 · Finding the roots", "transcript 9:41–12:41", "extension not connected"])
        #expect(chips.map(\.isRemovable) == [true, true, true, false])
        #expect(chips[0].thumbnailPNG == png.png && chips[1].thumbnailPNG == nil)
        #expect(ChipModel.chips(from: nil).isEmpty)
    }
}
extension WindowTests { @MainActor @Suite struct BubbleInputTests {
    // each test: vm + RecordingBubbleActions; input hosted in an off-screen NSWindow and made first responder;
    // type with input.insertText(_:replacementRange: NSRange(location: NSNotFound, length: 0))
    @Test func returnSubmitsAndClears() { type "hi"; input.keyDown(with: keyEvent(36, "\r"))
        #expect(rec.calls == [.submit("hi")]); #expect(input.string == "" && vm.inputText == "") }
    @Test func shiftReturnInsertsNewline() { type "a"; keyDown(keyEvent(36, "\r", [.shift]))
        #expect(input.string == "a\n" && vm.inputText == "a\n" && rec.calls.isEmpty) }
    @Test func tabCyclesModelWithoutInsertingATab() { keyDown(keyEvent(48, "\t")); #expect(rec.calls == [.cycleModel] && !input.string.contains("\t")) }
    @Test func escClosesInsteadOfCompleting() { type "x"; keyDown(keyEvent(53, "\u{1b}")); #expect(rec.calls == [.close]) }
    @Test func imeCompositionKeysGoToInputMethod() {
        input.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        for (code, ch) in [(36, "\r"), (48, "\t"), (53, "\u{1b}")] as [(UInt16, String)] { input.keyDown(with: keyEvent(code, ch)) }
        #expect(rec.calls.isEmpty)
    }
    @Test func bubbleViewLaysOutTheMockupState() {
        // vm: 3 chips (window/youtube/transcript), steps (done, done, active), 2 page thumbnails, a document choice,
        // an error banner, a 2-message thread; BubbleView(style: .bubble, onContentHeight: { h = $0 }) in an NSHostingView
        hosting.layoutSubtreeIfNeeded(); #expect(hosting.fittingSize.width == 380); #expect(h >= 72)
    }
}}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter CompanionUITests` → FAIL.
- [ ] **Step 3: Implement** `Theme.swift`, `ChipModel.swift`, `BubbleInputTextView.swift` (+ a `BubbleInputField: NSViewRepresentable` that returns the given instance and calls `syncFromViewModel()` in `updateNSView`), `BubbleView.swift`.
- [ ] **Step 4: Run to verify pass** — `swift test --filter CompanionUITests` → PASS.
- [ ] **Step 5: Commit** — `git add Sources/CompanionUI Tests/CompanionUITests && git commit -m "feat(ui): bubble view, chips and keyboard input"`

---

### Task 6: Bubble panel, controller and pop-out

**Files:**
- Create: `Sources/CompanionUI/Bubble/BubblePanel.swift`, `Sources/CompanionUI/Bubble/BubbleController.swift`, `Sources/CompanionUI/Bubble/PopOutWindowController.swift`
- Test: `Tests/CompanionUITests/BubbleControllerTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 2, 4, 5.
- Produces — the overview's API, verbatim:
```swift
@MainActor public final class BubbleController {
    public init(viewModel: BubbleViewModel)
    public var isVisible: Bool { get }
    public func show(cursor: NSPoint, avoiding: CGRect?)   // position + show + focus input; returns in < 50 ms
    public func focusInput()
    public func hide()
    public func popOut()
}
```
- Internal test hooks: `panel: BubblePanel`, `input: BubbleInputTextView`, `popOutWindow: NSWindow?`, `popOutViewModel: BubbleViewModel?`, `func contentHeightDidChange(_ height: CGFloat)`.

Semantics (write them as doc comments — WS7 relies on them):
- `init` builds the panel with the Global-Constraints flags, an `NSHostingView` (`sizingOptions = []`, so SwiftUI never resizes the panel) holding `BubbleView(style: .bubble)`, the input and a pre-loaded `AnswerWebController` (`onPopOut` → `popOut()`); forces one layout pass so the input is in the window before the first `show`. Panel: `isOpaque = false`, clear background, `hasShadow = true`.
- `show`: if the pop-out window is open, order it front and focus its input (the panel stays hidden). Otherwise frame = `BubblePlacement.frame(cursor:size: (380, clampedHeight(lastContentHeight)), screens: currentScreens(), avoid:)`, then `setFrame(_, display: false)` (no animation), `alphaValue = 1`, `orderFrontRegardless()`, `makeKey()`, `makeFirstResponder(input)`. Calling it while visible repositions. Never activates the app.
- `contentHeightDidChange`: `BubblePlacement.resized(…, anchorTop: frame is below the cursor, visibleFrame: the cursor's screen)` then `invalidateShadow()`.
- `hide()` orders the panel out and closes the pop-out; idempotent. The bubble never hides itself on Esc: `bubbleDidClose` is the signal and WS7 calls `hide()`.
- `isVisible` = panel visible || pop-out visible. `focusInput()` focuses whichever is visible.
- `popOut()` (no-op unless the panel is visible): order the panel out; show `PopOutWindowController`'s window — titled `Companion`, closable/resizable/miniaturizable, content 640×720 centred on the bubble's screen, `contentMinSize` 480×400, `BubbleView(style: .window)` on the **same** view model with its own input and answer controller (created on first pop-out, reused) — then `NSApp.activate()` and focus its input. Closing it with the red button calls `viewModel.close()`.
- `BubblePanel`: `canBecomeKey` true, `canBecomeMain` false; `performKeyEquivalent(with:)` maps command keys through `BubbleKeyCommand` and calls `viewModel.handle`, returning true when handled, so ⌘H never reaches the main menu's "Hide"; `cancelOperation(_:)` → `viewModel.handle(.close)` (Esc when the input isn't focused).

- [ ] **Step 1: Write the failing tests**

```swift
extension WindowTests { @MainActor @Suite struct BubbleControllerTests {
    // each test: TestApp.ensure(); vm + RecordingBubbleActions; c = BubbleController(viewModel: vm); ends with c.hide()
    var screen: CGRect { NSScreen.screens[0].visibleFrame }
    @Test func panelFlags() {
        let p = c.panel
        #expect(p.styleMask.contains(.nonactivatingPanel) && p.isFloatingPanel && p.level == .floating)
        #expect(p.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]))
        #expect(!p.hidesOnDeactivate && p.canBecomeKey && !p.becomesKeyOnlyIfNeeded && p.animationBehavior == .none && !p.isReleasedWhenClosed)
    }
    @Test func showIsFastFocusesInputAndDoesNotActivate() {
        let wasActive = NSApp.isActive
        let t = ContinuousClock().measure { c.show(cursor: CGPoint(x: screen.midX, y: screen.midY), avoiding: nil) }
        #expect(t < .milliseconds(50)); #expect(c.isVisible && c.panel.isKeyWindow)
        #expect(c.panel.firstResponder === c.input); #expect(NSApp.isActive == wasActive)
        #expect(c.panel.frame.width == 380 && screen.contains(c.panel.frame))
    }
    @Test func commandKeysAreHandledBeforeTheMainMenu() {
        c.show(cursor: CGPoint(x: screen.midX, y: screen.midY), avoiding: nil)
        #expect(c.panel.performKeyEquivalent(with: keyEvent(4, "h", [.command])))
        #expect(c.panel.performKeyEquivalent(with: keyEvent(45, "n", [.command])))
        c.panel.cancelOperation(nil)
        #expect(rec.calls == [.toggleHint, .newChat, .close])
    }
    @Test func rapidShowHideKeepsOnePanel() {
        let p = c.panel
        for i in 0..<50 { c.show(cursor: CGPoint(x: screen.minX + 300 + CGFloat(i), y: screen.midY), avoiding: nil); c.hide() }
        let last = CGPoint(x: screen.minX + 400, y: screen.midY); c.show(cursor: last, avoiding: nil)
        #expect(c.panel === p && c.isVisible && p.alphaValue == 1)
        #expect(NSApp.windows.filter { $0 is BubblePanel && $0.isVisible }.count == 1)
        #expect(p.frame == BubblePlacement.frame(cursor: last, size: p.frame.size, screens: BubblePlacement.currentScreens(), avoid: nil))
    }
    @Test func contentGrowthClampsInsideTheScreen() {
        c.show(cursor: CGPoint(x: screen.midX, y: screen.midY), avoiding: nil)
        c.contentHeightDidChange(5000); #expect(c.panel.frame.height == 520 && screen.contains(c.panel.frame))
        c.contentHeightDidChange(10);   #expect(c.panel.frame.height == 72)
    }
    @Test func popOutSharesTheThread() throws {
        vm.resetThread([ThreadMessage(role: .user, markdown: "q")]); c.show(cursor: CGPoint(x: screen.midX, y: screen.midY), avoiding: nil)
        c.popOut(); let w = try #require(c.popOutWindow)
        #expect(!c.panel.isVisible && w.isVisible && c.isVisible && c.popOutViewModel === vm)
        #expect(w.contentRect(forFrameRect: w.frame).size == CGSize(width: 640, height: 720))
        #expect(w.contentMinSize == CGSize(width: 480, height: 400) && w.styleMask.contains(.resizable))
        c.show(cursor: .zero, avoiding: nil); #expect(!c.panel.isVisible && w.isVisible)   // show focuses the pop-out
        c.hide(); #expect(!c.isVisible && !w.isVisible)
    }
}}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter CompanionUITests` → FAIL.
- [ ] **Step 3: Implement** the three files per the semantics above.
- [ ] **Step 4: Run to verify pass** — `swift test --filter CompanionUITests` → PASS.
- [ ] **Step 5: Commit** — `git add Sources/CompanionUI Tests/CompanionUITests && git commit -m "feat(ui): non-activating bubble panel, controller and pop-out"`

---

### Task 7: Idle orb

**Files:**
- Create: `Sources/CompanionUI/Orb/OrbPlacement.swift`, `Sources/CompanionUI/Orb/OrbView.swift`, `Sources/CompanionUI/Orb/OrbController.swift`
- Test: `Tests/CompanionUITests/OrbTests.swift`

**Interfaces:**
- Consumes: `SettingsStoring`, `AppSettings.orbEnabled` / `.orbPosition` (CompanionCore); `ScreenGeometry`, `BubblePlacement.currentScreens()` (Task 1); `FakeSettingsStore` (tests).
- Produces — overview, verbatim:
```swift
@MainActor public final class OrbController {
    public init(settings: any SettingsStoring, onSummon: @escaping @MainActor () -> Void)
    public func setVisible(_ visible: Bool)
}
```
- Produces (internal):
```swift
enum OrbPlacement {
    static let diameter: CGFloat = 30, inset: CGFloat = 24, panelSize: CGFloat = 58, dragThreshold: CGFloat = 3
    static func defaultCenter(mainVisibleFrame: CGRect) -> CGPoint          // (maxX − 39, minY + 39)
    static func resolve(saved: CGPoint?, screens: [ScreenGeometry]) -> CGPoint   // saved if inside some visibleFrame inset by 15, else default on screens[0]
    static func isDrag(from: CGPoint, to: CGPoint) -> Bool                   // distance ≥ 3
    static func panelFrame(center: CGPoint) -> CGRect                       // 58×58 centred
}
// OrbController hooks: panel: NSPanel; func handleMouseUp(dragged: Bool, center: CGPoint)
```

Decisions: visible ⇔ `settings.orbEnabled && requested` (`requested` starts true; `setVisible` sets it); observer registered with `addObserver { [weak self] in self?.apply($0) }`. Panel `[.borderless, .nonactivatingPanel]`, level `.floating`, collection `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `canBecomeKey` false, clear, no window shadow, `hidesOnDeactivate` false, placed at `panelFrame(center: resolve(saved: settings.orbPosition, …))`. `OrbView` is layer-backed so Core Animation runs the breathing on the render server (an always-on orb must cost ~0 CPU): body `CAGradientLayer(type: .radial)` from (0.35, 0.35) — white 85 % → `#6E7BFF` → `#2A2F6B` — overlaid by a circle-masked `.conic` Aurora layer at 55 % rotating once per 12 s; behind it a blurred `.conic` Aurora halo whose opacity 0.35↔0.7 and scale 1.0↔1.15 animate with `CABasicAnimation` (1.2 s, `autoreverses`, ease-in-out, infinite → 2.4 s period). No animations when `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`. `acceptsFirstMouse` true; mouse-down records the point, mouse-dragged moves the panel once `isDrag`, mouse-up calls `handleMouseUp`: click → `onSummon()`; drag → `resolve` the drop centre (snaps back if dropped off-screen), move there, `settings.update { $0.orbPosition = center }`.

- [ ] **Step 1: Write the failing tests**

```swift
struct OrbPlacementTests {   // main/left as in BubblePlacementTests
    let home = CGPoint(x: 1473, y: 99), far = CGPoint(x: -500, y: 500)
    @Test func defaultIsBottomRightInset24() { #expect(OrbPlacement.defaultCenter(mainVisibleFrame: main.visibleFrame) == home) }
    @Test func savedPositionOnMissingDisplayFallsBack() {
        #expect(OrbPlacement.resolve(saved: far, screens: [main, left]) == far)
        #expect(OrbPlacement.resolve(saved: far, screens: [main]) == home && OrbPlacement.resolve(saved: nil, screens: [main]) == home)
    }
    @Test func dragThreshold() { #expect(!OrbPlacement.isDrag(from: .zero, to: CGPoint(x: 2, y: 2)) && OrbPlacement.isDrag(from: .zero, to: CGPoint(x: 3, y: 0))) }
}
extension WindowTests { @MainActor @Suite struct OrbControllerTests {
    let spot = CGPoint(x: 700, y: 300)
    @Test func followsOrbEnabledAndSetVisible() {
        let store = FakeSettingsStore(); let c = OrbController(settings: store) {}; let p = c.panel
        #expect(p.isVisible && !p.canBecomeKey && p.level == .floating && p.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary]))
        store.update { $0.orbEnabled = false }; #expect(!p.isVisible)
        store.update { $0.orbEnabled = true }; #expect(p.isVisible)
        c.setVisible(false); #expect(!p.isVisible)
    }
    @Test func clickSummonsDragSavesAndRestores() {
        let store = FakeSettingsStore(); var summons = 0; let c = OrbController(settings: store) { summons += 1 }
        c.handleMouseUp(dragged: false, center: spot); #expect(summons == 1 && store.settings.orbPosition == nil)
        c.handleMouseUp(dragged: true, center: spot)
        #expect(summons == 1 && store.settings.orbPosition == spot && c.panel.frame == OrbPlacement.panelFrame(center: spot))
        #expect(OrbController(settings: store) {}.panel.frame == OrbPlacement.panelFrame(center: spot))   // a new controller starts there
    }
}}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter CompanionUITests` → FAIL.
- [ ] **Step 3: Implement** the three files per the decisions above.
- [ ] **Step 4: Run to verify pass** — `swift test --filter CompanionUITests` → PASS.
- [ ] **Step 5: Commit** — `git add Sources/CompanionUI Tests/CompanionUITests && git commit -m "feat(ui): draggable breathing idle orb"`

---

### Task 8: Capture glow and hotkeys

**Files:**
- Create: `Sources/CompanionUI/Overlay/CaptureGlow.swift`, `Sources/CompanionUI/Hotkeys/HotkeyManager.swift`
- Test: `Tests/CompanionUITests/CaptureGlowTests.swift`, `Tests/CompanionUITests/HotkeyManagerTests.swift`

**Interfaces:**
- Produces — overview, verbatim:
```swift
@MainActor public enum CaptureGlow { public static func flash(_ rect: CGRect) }   // global AppKit coords
@MainActor public final class HotkeyManager {
    public init(onSummon: @escaping @MainActor () -> Void, onRegion: @escaping @MainActor () -> Void)
}
```
- Produces — WS6 additions:
```swift
extension KeyboardShortcuts.Name {   // public: the Settings recorders use them; WS7 may too
    public static let summon = Self("summon", default: .init(.space, modifiers: [.option]))
    public static let regionCapture = Self("regionCapture", default: .init(.space, modifiers: [.option, .shift]))
}
// internal: CaptureGlow.outset = 6, lineWidth = 3, cornerRadius = 12, fadeIn = 0.08, hold = 0.25, fadeOut = 0.3,
//           CaptureGlow.activePanel: NSPanel?; HotkeyManager.handle(_ name: KeyboardShortcuts.Name)
```
If Swift 6 rejects those statics as not concurrency-safe (depends on whether the resolved KeyboardShortcuts marks `Name` `Sendable`), declare them `@MainActor`.

Glow decisions: at most one glow — a new `flash` closes the previous panel at once, and a generation counter stops a stale timer from closing the newer glow. Empty or null rect → no-op. Panel `[.borderless, .nonactivatingPanel]`, `ignoresMouseEvents = true`, `canBecomeKey`/`canBecomeMain` false, level one below `.floating` (never over the bubble), collection `[.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]`, shown only with `orderFrontRegardless()`. Content: SwiftUI `RoundedRectangle(cornerRadius: 12).strokeBorder(AngularGradient(Aurora), lineWidth: 3)` with a #6E7BFF 60 % shadow (radius 8). Fades via `NSAnimationContext` on `alphaValue`; the close is scheduled with `Task { @MainActor in try await Task.sleep(…) }` (0.63 s total), not an animation completion handler. `flash` returns immediately. HotkeyManager registers `KeyboardShortcuts.onKeyDown(for:)` for both names → `handle(_:)` (wrapped in `MainActor.assumeIsolated`; KeyboardShortcuts calls on the main thread).

- [ ] **Step 1: Write the failing tests**

```swift
extension WindowTests { @MainActor @Suite struct CaptureGlowTests {
    let r1 = CGRect(x: 100, y: 100, width: 300, height: 200), r2 = CGRect(x: 500, y: 300, width: 300, height: 200)
    @Test func flashShowsClickThroughGlowThenCloses() async throws {
        TestApp.ensure(); let keyBefore = NSApp.keyWindow
        let t = ContinuousClock().measure { CaptureGlow.flash(r1) }; let p = try #require(CaptureGlow.activePanel)
        #expect(t < .milliseconds(20) && p.frame == r1.insetBy(dx: -6, dy: -6) && p.ignoresMouseEvents && !p.canBecomeKey && NSApp.keyWindow === keyBefore)
        try await Task.sleep(for: .milliseconds(900)); #expect(CaptureGlow.activePanel == nil && !p.isVisible)
        CaptureGlow.flash(.zero); #expect(CaptureGlow.activePanel == nil)   // empty rect ignored
        #expect(CaptureGlow.fadeIn == 0.08 && CaptureGlow.hold == 0.25 && CaptureGlow.fadeOut == 0.3)
    }
    @Test func rapidFlashesKeepOneGlow() async throws {
        CaptureGlow.flash(r1); let first = CaptureGlow.activePanel
        try await Task.sleep(for: .milliseconds(300)); CaptureGlow.flash(r2); #expect(first?.isVisible == false)
        try await Task.sleep(for: .milliseconds(400)); #expect(CaptureGlow.activePanel?.frame == r2.insetBy(dx: -6, dy: -6))   // r1's stale timer fired
        try await Task.sleep(for: .milliseconds(400)); #expect(CaptureGlow.activePanel == nil)
    }
}}
struct HotkeyManagerTests {
    @Test func defaults() {
        #expect(KeyboardShortcuts.Name.summon.defaultShortcut == .init(.space, modifiers: [.option]))
        #expect(KeyboardShortcuts.Name.regionCapture.defaultShortcut == .init(.space, modifiers: [.option, .shift]))
    }
    @MainActor @Test func routesNamesToCallbacks() {
        var s = 0, r = 0; let m = HotkeyManager(onSummon: { s += 1 }, onRegion: { r += 1 })
        m.handle(.summon); m.handle(.regionCapture); m.handle(.regionCapture); #expect(s == 1 && r == 2)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter CompanionUITests` → FAIL.
- [ ] **Step 3: Implement** both files per the decisions above.
- [ ] **Step 4: Run to verify pass** — `swift test --filter CompanionUITests` → PASS.
- [ ] **Step 5: Commit** — `git add Sources/CompanionUI Tests/CompanionUITests && git commit -m "feat(ui): capture glow overlay and global hotkeys"`

---

### Task 9: Settings window

**Files:**
- Create: `Sources/CompanionUI/Settings/SettingsTab.swift`, `Sources/CompanionUI/Settings/SettingsViewModel.swift`, `Sources/CompanionUI/Settings/SettingsView.swift`, `Sources/CompanionUI/Settings/SettingsWindowController.swift`
- Test: `Tests/CompanionUITests/SettingsViewModelTests.swift`

**Interfaces:**
- Consumes: `SettingsStoring`, `SecretStoring`, `SecretKey`, `AppSettings`, `ModelRef`, `ModelCatalog`, `RoutingDefaults`, `ContextKind`, `BridgeStatus`, `PermissionStatus`, `PermissionKind` (all CompanionCore — do not redeclare the permission types); `KeyboardShortcuts.Name.summon/.regionCapture` (Task 8); `FakeSettingsStore`, `FakeSecretStore` (tests).
- Produces — overview, verbatim:
```swift
@MainActor public final class SettingsWindowController {
    public init(settings: any SettingsStoring, secrets: any SecretStoring,
                bridgeStatus: @escaping @MainActor () async -> BridgeStatus?,
                pairingToken: @escaping @MainActor () -> String,
                regenerateToken: @escaping @MainActor () -> String,
                permissions: @escaping @MainActor () -> PermissionStatus,
                openPermission: @escaping @MainActor (PermissionKind) -> Void)
    public func show()
}
```
- Produces — WS6 additions:
```swift
public enum SettingsTab: Sendable, CaseIterable { case general, models, privacy, browserExtension, permissions }
extension SettingsWindowController { public func show(tab: SettingsTab) }   // show() keeps the last tab (first time .general)
@MainActor @Observable final class SettingsViewModel {                     // internal
    init(settings:secrets:bridgeStatus:pairingToken:regenerateToken:permissions:openPermission:, pollInterval: Duration = .seconds(2))
    private(set) var settings: AppSettings                                   // mirror, refreshed through addObserver
    var anthropicKeyDraft: String; var openAIKeyDraft: String; var baseURLDraft: String   // start from stored values
    private(set) var keyError: String?; private(set) var baseURLError: String?
    func commitAnthropicKey(); func commitOpenAIKey(); func commitBaseURL(); func commitAll()
    func setOrbEnabled(_ on: Bool)
    @discardableResult func addModel(providerID: String, modelID: String, displayName: String) -> Bool
    @discardableResult func removeModel(_ model: ModelRef) -> Bool          // false when it is the last one
    func setDefault(_ model: ModelRef, for kind: ContextKind)
    func addBlockedApp(_ bundleID: String); func removeBlockedApp(_ bundleID: String)
    func addBlockedDomain(_ domain: String); func removeBlockedDomain(_ domain: String)
    private(set) var pairingToken: String; func copyToken(); func regenerateToken()
    private(set) var bridgeStatus: BridgeStatus?; private(set) var permissionStatus: PermissionStatus
    func startPolling(); func stopPolling()       // refresh bridge status + permissions now, then every pollInterval
    func openPermission(_ kind: PermissionKind)
    static func bridgeStatusText(_ status: BridgeStatus?) -> String
    static func label(for kind: ContextKind) -> String
}
extension RoutingDefaults { mutating func set(_ model: ModelRef, for kind: ContextKind) }   // internal helper
```

Rules: keys are trimmed of whitespace and newlines; empty → `setSecret(nil, …)` (delete); a thrown error → `keyError`. Base URL trimmed and saved only when `URL(string:)` has an `http`/`https` scheme and a host, else `baseURLError = "Enter a URL starting with http:// or https://"`. `addModel` trims, rejects an empty model ID or a duplicate (same `providerID` + `modelID`), uses the model ID when the display name is empty. `removeModel` refuses the last model; every routing default equal to the removed model becomes the new `modelCycle[0]`. Domains trimmed, lowercased, scheme and path stripped; bundle IDs trimmed; empties and duplicates ignored. Window: `show(tab:)` calls `NSApp.activate()`, creates the window once (title `Companion Settings`, content 560×480, closable, not resizable), selects the tab, `startPolling()`; `windowWillClose` → `commitAll()` + `stopPolling()`.

Copy (exact): tabs `General`, `Models`, `Privacy`, `Browser Extension`, `Permissions`. General: toggle `Show orb`; `KeyboardShortcuts.Recorder` rows `Summon:` and `Region capture:`; note `⌥Space is also ChatGPT's default shortcut. If both apps use it, change one here.` Models: `Anthropic API key` (SecureField, commit on submit), `OpenAI-compatible base URL`, `OpenAI-compatible API key`; section `Models (Tab cycles in this order)` with rows + remove buttons (disabled for the last), provider picker `Anthropic` / `OpenAI-compatible`, `Model ID`, `Display name`, `Add`; section `Default model by context` with six pickers over the cycle labelled `YouTube`, `Math on a web page`, `Web page`, `Textbook pages`, `Any other window`, `Region capture` (`label(for:)` for youtube, mathPage, webPage, pdfPages, genericWindow, region). Privacy: `Apps (bundle IDs)` and `Sites (domains)` lists with remove buttons and an add field. Browser Extension: monospaced token with `Copy` and `Regenerate`; `Paste this code into the Companion Bridge extension's options page.`; status line. Permissions: rows `Screen Recording` and `Accessibility`, `Granted` (green) / `Not granted` (orange), `Open System Settings`. `bridgeStatusText`: nil or no port → `Bridge not running`; no browsers → `Listening on port 47823 · no browser connected`; else `Connected: Dia (port 47823)` (names joined by `, `).

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor struct SettingsViewModelTests {
    // make(settings:secrets:pollInterval:) builds vm over FakeSettingsStore `store` / FakeSecretStore `secrets` with stub closures
    let haiku = ModelCatalog.haiku45, sonnet = ModelCatalog.sonnet55
    @Test func keysAreTrimmedAndEmptyDeletes() {   // secrets start with [anthropicAPIKey: "old"]
        #expect(vm.anthropicKeyDraft == "old")
        vm.anthropicKeyDraft = "  sk-ant-123 \n"; vm.openAIKeyDraft = "\tsk-oa\n"; vm.commitAll()
        #expect(secrets.secret(for: SecretKey.anthropicAPIKey) == "sk-ant-123" && secrets.secret(for: SecretKey.openAICompatibleAPIKey) == "sk-oa")
        vm.anthropicKeyDraft = "   "; vm.commitAnthropicKey(); #expect(secrets.secret(for: SecretKey.anthropicAPIKey) == nil)
    }
    @Test func baseURLValidation() {
        vm.baseURLDraft = "  https://openrouter.ai/api/v1 "; vm.commitBaseURL(); vm.baseURLDraft = "not a url"; vm.commitBaseURL()
        #expect(store.settings.openAICompatibleBaseURL == "https://openrouter.ai/api/v1" && vm.baseURLError != nil)
    }
    @Test func removingADefaultReassignsItToTheFirst() {
        #expect(vm.removeModel(sonnet)); let r = store.settings.routing
        #expect(store.settings.modelCycle == [haiku] && r.mathPage == haiku && r.pdfPages == haiku && r.region == haiku)
    }
    @Test func removingTheFirstReassignsToTheNewFirst() {
        vm.removeModel(haiku); let r = store.settings.routing; #expect(r.youtube == sonnet && r.webPage == sonnet && r.genericWindow == sonnet)
    }
    @Test func cycleCannotBecomeEmpty() {   // settings with modelCycle [haiku]
        #expect(vm.removeModel(haiku) == false && store.settings.modelCycle == [haiku])
    }
    @Test func addModelTrimsDefaultsNameAndDedupes() {
        #expect(vm.addModel(providerID: ModelRef.openAICompatibleProviderID, modelID: " gpt-5 ", displayName: ""))
        #expect(store.settings.modelCycle.last == ModelRef(providerID: "openai-compatible", modelID: "gpt-5", displayName: "gpt-5"))
        #expect(!vm.addModel(providerID: "openai-compatible", modelID: "gpt-5", displayName: "x") && !vm.addModel(providerID: "anthropic", modelID: " ", displayName: ""))
        vm.setDefault(sonnet, for: .youtube); #expect(store.settings.routing.youtube == sonnet)
    }
    @Test func blocklistEditing() {
        vm.addBlockedDomain("  HTTPS://Www.Example.com/login "); vm.addBlockedDomain("www.example.com"); vm.addBlockedApp(" com.foo.bar ")
        #expect(store.settings.blocklist.domains.filter { $0 == "www.example.com" }.count == 1 && store.settings.blocklist.bundleIDs.contains("com.foo.bar"))
        vm.removeBlockedDomain("www.example.com"); vm.removeBlockedApp("com.foo.bar")
        #expect(!store.settings.blocklist.domains.contains("www.example.com") && !store.settings.blocklist.bundleIDs.contains("com.foo.bar"))
        vm.setOrbEnabled(false); #expect(store.settings.orbEnabled == false)
    }
    @Test func bridgeAndToken() {   // pairingToken → "aaa", regenerateToken → "bbb"
        #expect(SettingsViewModel.bridgeStatusText(nil) == "Bridge not running")
        #expect(SettingsViewModel.bridgeStatusText(BridgeStatus(port: 47823, connectedBrowsers: [])) == "Listening on port 47823 · no browser connected")
        #expect(SettingsViewModel.bridgeStatusText(BridgeStatus(port: 47823, connectedBrowsers: ["Dia"])) == "Connected: Dia (port 47823)")
        #expect(vm.pairingToken == "aaa"); vm.regenerateToken(); #expect(vm.pairingToken == "bbb")
    }
    @Test func pollingRefreshesUntilStopped() async throws {   // pollInterval .milliseconds(20); bridgeStatus closure counts `calls`
        vm.startPolling(); try await Task.sleep(for: .milliseconds(110)); let n = calls; #expect(n >= 3)
        vm.stopPolling(); try await Task.sleep(for: .milliseconds(60)); #expect(calls <= n + 1)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter CompanionUITests` → FAIL.
- [ ] **Step 3: Implement** the four files per the rules and copy above. Polling is one `Task` on the main actor looping `bridgeStatus = await bridgeStatusClosure(); permissionStatus = permissions(); try await Task.sleep(for: pollInterval)` until cancelled.
- [ ] **Step 4: Run to verify pass** — `swift test --filter CompanionUITests` → PASS.
- [ ] **Step 5: Commit** — `git add Sources/CompanionUI Tests/CompanionUITests && git commit -m "feat(ui): settings window and view model"`

---

### Task 10: `CompanionUIDemo` and the manual checklist

**Files:**
- Replace: `Sources/CompanionUIDemo/main.swift`
- Create: `Sources/CompanionUIDemo/DemoCoordinator.swift`, `Sources/CompanionUIDemo/DemoStores.swift`, `Sources/CompanionUIDemo/DemoContent.swift`

**Interfaces:**
- Consumes: every public CompanionUI API above; CompanionCore types. The demo target cannot see `CompanionTestSupport`, so `DemoStores.swift` has its own in-memory `DemoSettingsStore: SettingsStoring` and `DemoSecretStore: SecretStoring`, and `DemoContent.swift` draws its images with `NSImage` → PNG.
- Produces: `swift run CompanionUIDemo`.

`main.swift` (top-level code is main-actor isolated): `NSApplication.shared`, `.accessory` policy, an `NSStatusItem` `Demo` with `Settings…` / `Quit`; builds `BubbleViewModel`, `BubbleController`, `DemoCoordinator` (the `actions`), `OrbController(settings: demoSettings, onSummon: coordinator.summon)`, `HotkeyManager(onSummon: coordinator.summon, onRegion: coordinator.summonRegion)`, `SettingsWindowController` with fake closures (`BridgeStatus(port: 47823, connectedBrowsers: ["Dia"])`, a random 64-hex token, both permissions granted, `openPermission` prints); `app.run()`.

`DemoCoordinator: BubbleActions` (fake data, mockup frames 2–4):
- `summon()`: visible → `focusInput()`; else `CaptureGlow.flash(screens[0].visibleFrame.insetBy(dx: 160, dy: 120))`, `setModelName("Haiku 4.5")`, `show(cursor: NSEvent.mouseLocation, avoiding: nil)`, then chips land at 0 / 60 / 120 ms: `.windowImage` (dark 300×190 frame reading “x² − 5x + 6 = 0”), `.youtubeVideo` (“Solving Quadratics by Factoring”, chapter “Finding the roots”, playhead 761), `.transcriptWindow(from: 581, to: 761)`. `summonRegion()`: same with a `.regionImage` chip and a glow around a 400×260 rect at the cursor.
- Submit (user message, `setBusy(true)`), by question text: `pages 231–232` / `pages 231-232` → steps at 0 / 500 / 900 ms (`Downloading “Algebra 2 Textbook.pdf”…` ●, then `Got the PDF from Drive (412 pages)` ✓, `Book p.231 → PDF p.247 (page labels)` ✓, `Sending pages to Sonnet 5.5…` ●), `setModelName("Sonnet 5.5")`, document `Algebra 2 Textbook.pdf` with alternative `Worksheet 5.2.pdf`, thumbnails 231/232, then stream; `error` → banner `Anthropic API error 529 — overloaded.` (`offerModelSwitch`); `key` → `No Anthropic API key yet.` (`offerSettings`); `long` → 40 numbered paragraphs + an 8×8 `pmatrix` display + a 200-column code block; otherwise the standard answer below. Streaming = one word per 40 ms via `appendDelta`, then `finishAssistantMessage`, `setBusy(false)`, last step ✓.
- Model cycle toggles `Haiku 4.5` ⇄ `Sonnet 5.5`; hint flips and echoes `setHintMode`; new chat → `resetThread([])` + clear steps/thumbnails/document/error; close → cancel streaming + `hide()`; settings → `settingsWindow.show(tab: .models)`; switch-after-error → cycle, clear banner, stream the standard answer; select document → swap current and alternative.

Standard answer (exact):
```
Reading: $x^2 - 5x + 6 = 0 \Rightarrow (x-2)(x-3) = 0$

At 12:20 he factored it into $(x-2)(x-3)$. A product is zero only if one factor is zero, so

$$x - 3 = 0 \quad\Longrightarrow\quad x = 3$$

**Check:** $3^2 - 5\cdot 3 + 6 = 0$ ✓ — and renting both videos costs $5 and $6 (prices, not math).
```

- [ ] **Step 1: Implement** the four files; `swift build --product CompanionUIDemo` → builds.
- [ ] **Step 2: Manual checklist** — `swift run CompanionUIDemo`; fix every failure before committing.
  1. *Frame 1 · Idle:* orb 24 pt in from the bottom-right of the visible frame, breathing ~2.4 s; drag moves it; click without drag opens the bubble; Settings → `Show orb` off/on hides it and brings it back where it was dropped.
  2. *Frame 2 · Summoned:* Dia/Safari in front, ⌥Space → bubble at the cursor with no visible delay; typing lands in the bubble at once while the browser's menu bar stays (not activated); glow outlines and fades; chips: thumbnail + `window`, `▶ 12:41 · Finding the roots`, `transcript 9:41–12:41`, ✕ removes; footer `Haiku 4.5 ⇥ switch` / `Hints ⌘H` `Esc to close`; Tab → `Sonnet 5.5`; ⌘H highlights Hints and doesn't hide the app.
  3. *Frame 3 · Answer:* `why does 3 become x here?` ⏎ → muted question, blue-ruled `Reading:` line with typeset math, word-by-word streaming with formulas typesetting as they close, `$5 and $6` stays prose; placeholder `Follow up…`; footer gains `· new chat ⌘N`; `↗ pop out` → 640×720 window with the same thread; Esc closes.
  4. *Frame 4 · Pages:* `explain the example on pages 231–232` → ✓ ✓ ● steps as in the mockup, thumbnails 231/232, `using: Algebra 2 Textbook.pdf` whose menu offers `Worksheet 5.2.pdf`, footer `Sonnet 5.5`.
  5. *Review Focus:* `long` grows to 520 then scrolls and auto-scrolls; matrix and code scroll sideways inside; second display (incl. one left of main) and a full-screen app → bubble on the cursor's display, above the app; ⌥Space/Esc mashed 20× → no stray windows; Japanese IME composition + Return commits without sending; Shift-Return adds a line.
  6. *Settings:* five tabs; ⌥Space note exact; a rebound Summon shortcut works; status `Connected: Dia (port 47823)`.
- [ ] **Step 3: Full verification** — `swift test --filter CompanionUITests` → PASS; `cd ui-web && npm test` → PASS; `cd ui-web && npm run build && git diff --exit-code -- ../Sources/CompanionUI/Resources/web` → no diff (committed renderer is current).
- [ ] **Step 4: Commit** — `git add Sources/CompanionUIDemo && git commit -m "feat(ui-demo): mockup demo app with fake streaming and page-finder steps"`
