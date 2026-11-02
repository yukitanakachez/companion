# Companion v1 — Parallel Build Overview (read this first)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement your workstream plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. You implement exactly ONE workstream file; this overview gives you the rules, the shared contracts, and the APIs your neighbours expose.

**Goal:** Build v1 of the Screen Companion: a macOS menu-bar app whose hotkey opens a cursor bubble that already knows what you're looking at (window, YouTube video, web math, named Classroom textbook pages) and streams answers from Claude or any OpenAI-compatible model.

**Architecture:** One Swift package (`Package.swift`) with one library target per workstream plus a thin XcodeGen-generated app target; a TypeScript Manifest V3 extension feeds browser context to the app over a token-authenticated WebSocket on 127.0.0.1. Shared types and protocols live in `CompanionCore` and `contracts/`, frozen after WS0, so workstreams build and test independently against them.

**Tech Stack:** Swift 6.4 (language mode 6), SwiftUI + AppKit, ScreenCaptureKit, Accessibility (AX), PDFKit, Vision, Network.framework, WKWebView + KaTeX + markdown-it, Swift Testing; KeyboardShortcuts (sindresorhus); XcodeGen; TypeScript, esbuild, vitest, jsdom (extension); Node 24.

**Spec:** `docs/superpowers/specs/2026-11-01-screen-companion-design.md` — every agent reads it before starting.

---

## Workstreams

| ID | Plan file | Owns (only these paths) | Depends on | Produces |
|---|---|---|---|---|
| **WS0** | `2026-11-01-companion-ws0-foundation.md` | `Package.swift`, `project.yml`, `AGENTS.md`, `CLAUDE.md`, `.gitignore`, `Config/`, `scripts/`, `contracts/`, `Sources/CompanionCore/`, `Sources/CompanionTestSupport/`, `Tests/CompanionCoreTests/`, `App/` (placeholder only) | — | Skeleton, all targets, frozen contracts, fakes |
| **WS1** | `…-ws1-llm.md` | `Sources/CompanionLLM/`, `Tests/CompanionLLMTests/` | WS0 | Claude + OpenAI-compatible adapters, router, prompt builder, Keychain store |
| **WS2** | `…-ws2-pagefinder.md` | `Sources/CompanionPageFinder/`, `Tests/CompanionPageFinderTests/` | WS0 | Page-reference parser, printed→PDF page mapping, renderer, document resolver, viewer fallback |
| **WS3** | `…-ws3-extension.md` | `extension/` | WS0 | Chromium MV3 extension + dev bridge tool |
| **WS4** | `…-ws4-bridge.md` | `Sources/CompanionBridge/`, `Tests/CompanionBridgeTests/` | WS0 | WebSocket server, auth, context cache, PDF/viewer requests |
| **WS5** | `…-ws5-capture.md` | `Sources/CompanionCapture/`, `Tests/CompanionCaptureTests/` | WS0 | Window/region capture, AX reader, privacy gate, context assembly + gatherer |
| **WS6** | `…-ws6-ui.md` | `Sources/CompanionUI/`, `Tests/CompanionUITests/`, `Sources/CompanionUIDemo/`, `ui-web/` | WS0 | Bubble panel + view model, answer renderer, orb, glow, hotkeys, settings UI, demo app |
| **WS7** | `…-ws7-integration.md` | `Sources/CompanionSession/`, `Tests/CompanionSessionTests/`, `App/` (after WS0), `docs/superpowers/verification/` | WS0; later tasks gate on WS1–WS6 merges | Summon coordinator, conversation store, latency trace, settings store, permissions, app wiring, E2E checklist |

### Dependency graph and waves

```
            ┌──► WS1 LLM ─────────────┐
            ├──► WS2 PageFinder ──────┤
            ├──► WS3 Extension ───────┤
WS0 ────────┼──► WS4 Bridge ──────────┼──► WS7 integration tasks (gated per task)
(first,     ├──► WS5 Capture ─────────┤
 alone)     ├──► WS6 UI ──────────────┤
            └──► WS7 early tasks ─────┘  (conversation store, latency, settings, permissions)
```

- **Wave 0 — 1 agent:** WS0. Nothing else starts until WS0 is merged into `main`.
- **Wave 1 — up to 7 agents in parallel:** WS1, WS2, WS3, WS4, WS5, WS6, and WS7's ungated tasks.
- **Wave 2 — WS7 continues** as its gated tasks unblock (each WS7 task lists which workstreams must be merged first).

### Integration milestones (what you can try, in order)

| Milestone | Needs merged | You can… |
|---|---|---|
| M1 "Ask from the bubble" | WS0, WS1, WS6 + WS7 Tasks 6–7 | Press ⌥Space, type, get a streamed Claude answer (no screen context yet) |
| M2 "It sees my screen" | + WS5 + WS7 Task 8 | Window/region capture, chips, privacy gate |
| M3 "It knows the video" | + WS3, WS4 + WS7 Task 10 (Task 10 also needs WS2 merged) | YouTube transcript + playhead, web-page math |
| M4 "Pages 231–232" | + WS2 + WS7 Tasks 9–10 | Page finder on Classroom PDFs (download path) |
| M5 "Downloads blocked" | WS2 viewer task + WS3 viewer task | Viewer-scroll fallback (may slip to v1.1 per spec) |

---

## Rules every agent follows

1. **Stay in your paths.** Edit only the paths your workstream owns (table above). Reading anything is fine.
2. **Frozen contracts.** After WS0 merges, these are frozen: `Package.swift`, `project.yml`, `contracts/`, `Sources/CompanionCore/`, `Sources/CompanionTestSupport/`, `scripts/`, `AGENTS.md`. If your task truly needs a change, **stop and tell the human** with the exact proposed diff and why. Do not work around it by duplicating a contract type.
3. **Use the APIs below verbatim.** The "Cross-workstream APIs" section is the contract between workstreams. If you are the producer, implement those exact public names, parameters and types (you may add more public API). If you are the consumer, use only what's listed.
4. **One branch + worktree per workstream**, cut from `main`:
   ```bash
   scripts/new-workstream.sh ws1-llm     # creates ../companion-ws1-llm on branch ws/ws1-llm
   ```
   (Or create a Superset workspace per workstream on a branch of the same name.)
5. **TDD, small commits.** Follow your plan's steps. Commit after each task with a conventional message (`feat(llm): …`, `test(bridge): …`).
6. **Before merging:** `git fetch && git rebase main`, then `scripts/test-all.sh` must pass. Merge into `main` with `git merge --no-ff ws/<id>` (or a PR). Because paths don't overlap, rebases should be conflict-free; if one isn't, you touched a path you don't own.
7. **Swift 6 strict concurrency** is on. AppKit/SwiftUI types are `@MainActor`. Cross-module values are `Sendable`.
8. **Never commit secrets** (API keys, pairing tokens, real textbook PDFs).
9. **Public structs get public memberwise inits.** Every `public struct` you expose across modules declares an explicit `public init` with all stored properties in declared order — Swift won't synthesize a public one, and neighbours construct your types.

---

## Global Constraints

Every task in every workstream implicitly includes these. Values are copied from the spec or fixed here for all agents.

- Platform: macOS 14.0 minimum deployment target; Apple Silicon; built with Xcode 27.2 / Swift 6.4, `swift-tools-version: 6.0`, Swift language mode 6.
- Only external Swift dependency: `https://github.com/sindresorhus/KeyboardShortcuts` from `2.0.0`. No other packages without a contract change.
- Extension: Manifest V3, TypeScript, built with esbuild; dev-only npm dependencies (no runtime npm code except what esbuild bundles from `extension/src` and `contracts/ts`).
- Bundle identifier: `dev.local.Companion`. App is a menu-bar app (`LSUIElement = YES`), not sandboxed, signed with a stable Apple Development certificate (see `Config/Signing.local.xcconfig`).
- Speed budgets (spec §2): hotkey → bubble visible and accepting keystrokes **< 0.8 s hard limit, target < 0.1 s**; any user action → visible change **< 0.1 s**; Enter → first token on a simple question ≈ **1–1.5 s**; slow work (hard math, page finding, viewer scrolling) always shows live progress steps.
- Capture only on summon: nothing leaves the Mac and nothing reaches a model until the user summons. The extension may keep the active tab's context in memory locally.
- Screenshot downscale: long edge **1500 px**, PNG.
- YouTube transcript window: **180 s** before the playhead up to the playhead.
- Web page visible text cap: **20,000** characters; math snippets cap: **50**; focused-element text cap: **8,000** characters.
- Page finder cap: **10** pages per question.
- Conversation resume window: **600 s** (10 minutes) after the last interaction.
- Extension wait on the hot path: **300 ms**, then fall back to screenshot + AX.
- Bridge: `ws://127.0.0.1`, ports tried in order **47823, 47824, 47825, 47826, 47827**; protocol version **1**; pairing token = 32 random bytes as 64 lowercase hex chars; `hello` must arrive within **5 s**; binary chunks ≤ **1,048,576** bytes.
- Default hotkeys: summon **⌥Space**, region capture **⌥⇧Space**; both rebindable.
- Default models: fast = `claude-haiku-4-5-20251001` ("Haiku 4.5"), strong = `claude-sonnet-5-5` ("Sonnet 5.5"). Routing defaults: youtube, webPage, genericWindow → fast; mathPage, pdfPages, region → strong.
- Secrets (API keys, pairing token) live only in the Keychain (service `dev.local.Companion`). Captured images/text are never written to disk except the session PDF cache, cleared on quit.
- Notion, coding readers, Preview page finding, persistent history, auto-routing, embedded (non-youtube.com) video players: **out of v1**.

## Review Focus

Inputs the spec implies but that ordinary happy-path tests miss — each has a pinned test in the owning workstream:

1. **First run with no API key or missing permissions** → bubble still opens instantly and shows what's missing with an "Open Settings" action, never a hang or crash. *(WS7, SummonCoordinator tests)*
2. **Hotkey pressed while the bubble is already open or mid-answer** → focuses the existing bubble; no second panel, no re-capture, the stream keeps going. *(WS7, SummonCoordinator tests)*
3. **Extension not connected / service worker asleep / browser just launched** → gather still completes within budget with screenshot + AX and an "extension not connected" chip after 300 ms. *(WS5, ContextGatherer tests)*
4. **Page references in odd forms or out of range** ("pp. 231–232" en dash, "pages 231, 233", "pages 500–520" > cap, page beyond the book, no "page" keyword) → correct parse, cap at 10 with a note, plain "couldn't find" message, no false triggers on plain math. *(WS2, parser + façade tests)*
5. **Multiple displays and full-screen apps** → bubble appears on the display under the cursor, inside its visible frame, above full-screen apps. *(WS6, placement + panel tests)*

---

## Cross-workstream APIs (the contract)

`CompanionCore` and `contracts/` are written by WS0 (see that plan for the full code). The module APIs below are written by their owning workstream; consumers rely on exactly these signatures.

### CompanionCore (WS0) — summary
Types: `ContextKind`, `ImageAttachment`, `TranscriptSegment`, `TranscriptStatus`, `YouTubeContext`, `MathSnippet`, `WebPageContext`, `DriveFileRef`, `ClassroomContext`, `DriveViewerContext`, `TabContext`, `FrontAppInfo`, `RenderedPage`, `ContextNotice`, `ContextPiece`, `ContextItem`, `CapturedContext`, `BlocklistConfig`, `PrivacyDecision`, `ModelRef`, `ModelCatalog`, `LLMRole`, `LLMContent`, `LLMMessage`, `LLMToolSpec`, `LLMRequest`, `LLMStreamEvent`, `LLMError`, `RoutingDefaults`, `AppSettings`, `SecretKey`, `DocumentChoice`, `BridgeStatus`, `PermissionKind`, `PermissionStatus`, `KnownBrowsers`, `JSONValue`, bridge message types (`ExtensionToApp`, `AppToExtension`, `BridgeRequest`, `BridgeResponse`, result structs, `BridgeErrorCode`, `BinaryFrame`), `BridgeConstants`, `formatTimestamp(_:)`.
Protocols: `LLMProvider`, `SecretStoring`, `SettingsStoring`, `BrowserContextProviding`, `DocumentFetching`, `ViewerDriving`.
`CapturedContext.tabId: Int?` records which browser tab the context came from. Every public struct in Core has an explicit public memberwise `init` (declared order).
Test support (`CompanionTestSupport`): `Fixtures`, `FakeSecretStore`, `FakeSettingsStore`, `FakeLLMProvider`, `FakeBrowserContextProvider`, `FakeDocumentFetcher`, `FakeViewerDriver`.

### CompanionLLM (WS1)
```swift
public final class KeychainSecretStore: SecretStoring {
    public init(service: String = "dev.local.Companion")
}
public struct ModelRouter: Sendable {
    public init(defaults: RoutingDefaults, cycle: [ModelRef])
    public func model(for kind: ContextKind) -> ModelRef
    public func next(after current: ModelRef) -> ModelRef   // wraps; if current ∉ cycle → cycle[0]; empty cycle → current.
                                                            // Membership compares providerID + modelID (not displayName).
}
public struct PromptBuilder: Sendable {
    public init()
    /// Returns the system prompt and the message list for the request: `history` plus the new user turn.
    /// It may merge consecutive same-role turns and strip images from older turns, so callers must not
    /// assume `messages.count == history.count + 1`.
    public func build(question: String, context: CapturedContext?, history: [LLMMessage],
                      hintMode: Bool) -> (system: String, messages: [LLMMessage])
}
public final class ProviderRegistry: Sendable {
    public init(secrets: SecretStoring, openAICompatibleBaseURL: @escaping @Sendable () -> URL,
                session: URLSession = ProviderRegistry.makeSession())
    public static func makeSession() -> URLSession
    /// Throws `LLMError.missingAPIKey(providerID:)` when the provider's key is absent.
    public func provider(for model: ModelRef) throws -> any LLMProvider
}
```

### CompanionPageFinder (WS2)
```swift
public struct PageReference: Equatable, Sendable {
    public var pages: [Int]          // sorted, unique, at most 10
    public var requestedCount: Int   // before the cap (> pages.count means it was capped)
}
public enum PageReferenceParser { public static func parse(_ question: String) -> PageReference? }

public enum MappingMethod: String, Sendable, Equatable { case pageLabels, printedNumbers, textRecognition, viewer }
public enum PageFinderStep: Sendable, Equatable {
    case downloading(title: String)
    case downloaded(pageCount: Int)
    case downloadBlocked
    case matched(printed: Int, pdfIndex: Int, method: MappingMethod)   // pdfIndex is 0-based
    case scrollingViewer(target: Int)
    public var displayText: String
}
// `DocumentChoice` comes from CompanionCore (WS0) — do not redeclare.
public enum PageFinderOutcome: Sendable, Equatable {
    case found(choice: DocumentChoice, pages: [RenderedPage], missing: [Int])
    case noDocument
    case notFound(document: DriveFileRef, pages: [Int])
    case failed(message: String)
}
public actor PDFSessionCache {
    public init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Companion-PDFCache"))
    public func clearAll()
}
public actor PageFinder {
    public init(fetcher: any DocumentFetching, viewer: any ViewerDriving, cache: PDFSessionCache)
    public func find(_ reference: PageReference, question: String, tab: TabContext?,
                     lastUsed: DriveFileRef?, preferred: DriveFileRef?,
                     progress: @escaping @Sendable (PageFinderStep) -> Void) async -> PageFinderOutcome
}
```
`displayText` copy (exact): `downloading` → `Downloading “<title>”…`; `downloaded` → `Got the PDF from Drive (<n> pages)` (`(1 page)` when n == 1); `downloadBlocked` → `Couldn't download — teacher disabled downloads. Scrolling the viewer instead…`; `matched` → `Book p.<printed> → PDF p.<pdfIndex+1> (<method label>)` where labels are `page labels`, `printed page numbers`, `text recognition`, `viewer`; `scrollingViewer` → `Scrolling the viewer to find p.<target>…`.

### CompanionBridge (WS4)
```swift
public actor BridgeServer {
    public init(secrets: any SecretStoring, blocklist: BlocklistConfig,
                ports: [UInt16] = BridgeConstants.ports, appVersion: String)
    public func start() async throws -> UInt16          // the bound port
    public func stop() async
    public func updateBlocklist(_ config: BlocklistConfig) async
    public nonisolated var browserContext: any BrowserContextProviding { get }
    public nonisolated var documentFetcher: any DocumentFetching { get }
    public nonisolated var viewerDriver: any ViewerDriving { get }
    public func status() async -> BridgeStatus      // `BridgeStatus` comes from CompanionCore (WS0)
}
public enum BridgePairing {
    public static func token(in secrets: any SecretStoring) throws -> String       // creates if missing
    public static func regenerate(in secrets: any SecretStoring) throws -> String
}
```

### CompanionCapture (WS5)
```swift
public struct RegionSelection: Sendable, Equatable {
    public var rect: CGRect                 // global AppKit coordinates (bottom-left origin)
    public var displayID: CGDirectDisplayID
}
public enum GatherRequest: Sendable, Equatable { case frontWindow, region(RegionSelection) }
public actor ContextGatherer {
    public static func live(browser: any BrowserContextProviding,
                            blocklist: @escaping @Sendable () -> BlocklistConfig,
                            ownBundleID: String) -> ContextGatherer
    /// First element within 50 ms (front app + privacy decision); emits again as each piece lands;
    /// the final element is complete. Finishes after the final element.
    /// Item ids are stable across the emissions of one gather (the same piece keeps its id), and
    /// `tabId` is set whenever browser tab context was used.
    public func gather(_ request: GatherRequest) -> AsyncStream<CapturedContext>
}
@MainActor public enum RegionSelector { public static func select() async -> RegionSelection? }  // nil on Esc
```

### CompanionUI (WS6)
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
@MainActor public final class BubbleController {
    public init(viewModel: BubbleViewModel)
    public var isVisible: Bool { get }
    public func show(cursor: NSPoint, avoiding: CGRect?)   // position + show + focus input; returns in < 50 ms
    public func focusInput()
    public func hide()
    public func popOut()
}
@MainActor public final class OrbController {
    public init(settings: any SettingsStoring, onSummon: @escaping @MainActor () -> Void)
    public func setVisible(_ visible: Bool)
}
@MainActor public enum CaptureGlow { public static func flash(_ rect: CGRect) }   // global AppKit coords
@MainActor public final class HotkeyManager {
    public init(onSummon: @escaping @MainActor () -> Void, onRegion: @escaping @MainActor () -> Void)
}
// `PermissionStatus` and `PermissionKind` come from CompanionCore (WS0) — do not redeclare.
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
`CompanionUI` depends only on `CompanionCore` and KeyboardShortcuts — never on WS1/WS2/WS4/WS5 modules. That's why `DocumentChoice` and `BridgeStatus` live in `CompanionCore`.

### CompanionSession (WS7)
Owns `SummonCoordinator` (implements `BubbleActions`), `ConversationStore`, `LatencyTrace`, `UserDefaultsSettingsStore: SettingsStoring`, `PermissionsService`, and the app composition root in `App/`. Nothing depends on WS7.

---

## Known v1 limitations (accepted)

- **One browser with the extension.** `TabContext` doesn't identify which browser it came from; with two connected browsers the most recently activated tab wins. Fine for v1 (Dia only).
- **Keychain failures look like a missing key.** `SecretStoring.secret(for:)` can't throw, so a locked keychain surfaces as "add your API key".
- **Strong-model silence.** Sonnet 5.5 may think silently for a few seconds before its first token; WS7 shows a "Thinking…" step until the first token arrives.
- **Bubble placement can't see the focal area.** No contract carries the video player's (or any focal element's) frame, so window summons open the bubble right-below the cursor; only region capture moves the bubble beside what it covers. Spec §5.2's "slide off the video" is deferred.
- **No full-transcript request.** The `.youtubeVideo` item carries the whole transcript; the prompt builder sends only the 180 s window by default.

## Out of v1 (not planned here)

Notion via MCP (v2 — needs an `LLMContent` case for thinking blocks so tool-use turns can replay them), on-device redaction pass, cost meter, VS Code/Cursor reader, Preview-PDF page finder, system audio, persistent history, flashcards/assignment-tracker link, MCP context export, pet skin, agentic actions, auto-routing, Python backend, notarization, Windows.

## How to launch the agents

1. **Human, once:** merge this planning branch into `main` (or run WS0 directly on `main`).
2. Start one CLI on WS0: *"Implement docs/superpowers/plans/2026-11-01-companion-ws0-foundation.md. Read the overview and spec first."* Merge it.
3. For each Wave 1 workstream: `scripts/new-workstream.sh <id>`, open a CLI in that worktree, and give it: *"Implement docs/superpowers/plans/2026-11-01-companion-<id>.md. Read 2026-11-01-companion-00-overview.md and the spec first. Stay in your owned paths."*
4. Merge each workstream to `main` as it finishes; tell the WS7 agent when its gates open.
