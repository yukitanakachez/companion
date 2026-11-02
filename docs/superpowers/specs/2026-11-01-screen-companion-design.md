# Screen Companion — Design

*Date: 2026-11-01 · Status: draft for approval · Working name: "Companion" (no product name chosen yet)*

## 1. Intent

A macOS study companion that is always one keystroke away. You press a hotkey (or click a small idle orb), a bubble appears next to your cursor almost instantly, and and when you press Enter it **reads what you're looking at right then** — the YouTube video and what was just said, the math problem on a web page, the textbook pages you name — so you just type the question, and can still move tabs first.

**Why it exists.** Existing tools (ChatGPT/Claude desktop apps, screenshot-and-paste) fail in two ways the owner cares about:

1. **Too many steps** — screenshot, switch app, paste, re-explain.
2. **Too little context** — a single frame doesn't know what was said in the video, which textbook pages you mean, or what the page's math actually is.

A third differentiator: **provider-agnostic.** Similar products are tied to one AI provider; this one isn't.

**Who it's for.** v1 is for the owner alone (a student, Python background, learning Swift for this). If it proves itself in daily use, it scales to other students. Build for one user, but don't paint into a corner.

## 2. Success, goals, non-goals, anti-goals

**Success test:** the owner uses it daily for two weeks and stops pasting screenshots into ChatGPT/Claude.

**Speed budgets** (the core of the product — lag is the #1 anti-goal):

| Moment | Budget |
|---|---|
| Hotkey → bubble visible and accepting keystrokes | **< 0.8 s hard limit; target < 0.1 s** |
| Any user action → something visibly changes | < 0.1 s (never a frozen or blank bubble) |
| Enter → first answer token, simple question, fast model | ≈ 1–1.5 s, including the screen capture that now starts at Enter (waited for up to 500 ms) |
| Hard math (strong model), page finding, viewer scrolling | Several seconds allowed, **always with live progress steps** |

**v1 goals**
- Global hotkey + idle orb → cursor bubble; streamed answers; follow-ups; 10-minute conversation continuation.
- Context capture of the front window (screenshot + macOS accessibility text) with a second hotkey for region capture.
- Browser context from Dia via a Chromium extension: YouTube (title, chapter, playhead, last ~3 min of transcript) and web pages (visible text + exact LaTeX when the page uses MathJax/KaTeX).
- **Page finder**: "explain pages 231–232" fetches the Google Classroom/Drive PDF, maps *printed* page numbers to PDF pages, and sends those pages to the model.
- Provider-agnostic model layer with two adapters: native Anthropic (Claude) and generic OpenAI-compatible.
- Per-context default model + one-key override.
- Hint mode toggle; "Reading: …" line for problems read from pixels.
- Privacy blocklist.

**Non-goals for v1** (deliberately deferred, see §9): coding-specific context, Notion, video editing, visible agentic screen control beyond the page-finder fallback, other browsers' special handling, Preview-PDF page finding, persistent chat history, Windows, distribution to others (notarization, accounts, backend, billing), auto-routing by difficulty, animated pet.

**Anti-goals** (failure even if it "works"):
- Lag: bubble slow to appear, or a blank/frozen bubble with no progress.
- Capturing anything from a blocklisted app or site.
- Touching Notion without an explicit request.
- Silently answering about the wrong pages or wrong context — the user must always be able to see *what* was used (context chips, page thumbnails, "Reading:" line).
- Always-on screen watching. The screen is captured only when a question is sent or a region is selected.

## 3. Constraints

- **Platform:** macOS only, Apple Silicon. Native Swift app (SwiftUI where convenient, AppKit where needed for panels/hotkeys/capture).
- **Builder:** solo student, strong in Python, new to Swift and JS, building with heavy AI-coding assistance. Prefer boring, well-documented Apple APIs over clever ones.
- **Browser:** Dia (Chromium) is the test browser. Extension is Manifest V3 and should work unmodified in Chrome/Arc/other Chromium browsers.
- **Permissions:** Screen Recording + Accessibility. Debug builds must be signed with a **stable development certificate** from day one, or macOS resets these grants on every rebuild. Periodic macOS re-prompts for screen recording are accepted.
- **Distribution:** none in v1 (runs from Xcode / local build). Mac App Store is out long-term (sandbox blocks the needed APIs); future distribution = Developer ID + notarization.
- **Model access:** owner has an Anthropic API key with billing. Keys live in the macOS Keychain. No backend in v1.
- **Existing visual direction** (in `design/`, made separately): `glow-prototype.html` — a resting glowing orb that opens into the assistant on ⌥Space; `pet-casting.html` — five original characters with states *waiting / reading your screen / thinking / answering / asleep*, for the later pet skin. The orb in v1 should follow the glow prototype.

## 4. Approaches considered

| | Approach | Trade-off | Verdict |
|---|---|---|---|
| **A** | **Mac app is the brain; extension is eyes and hands.** Swift app owns hotkey, bubble, capture, model calls, page finder, conversation state. Extension pre-collects per-tab context and pushes it to the app; fetches Drive PDFs; scrolls the viewer when needed. | Most code is Swift (the language being learned). Swift MCP tooling is less mature than JS (matters in v2). | **Chosen** — only option where context is pre-collected *and* the model call starts from an always-awake process, which is what the speed budget needs. |
| B | Extension is the brain; app is a thin shell (hotkey, screenshot, bubble). | More JS (more examples, more portable to Windows/ChromeOS). But MV3 service workers sleep after ~30 s idle and pay a wake-up cost on the next question; UI and logic split across processes; non-browser contexts still need Swift logic. | Rejected — fights the #1 anti-goal (lag). |
| — | Swift UI + local Python "brain" process | Plays to Python strength, but two processes to bundle, launch and keep in sync. | Rejected during planning. |
| — | Extension-only with its own side panel | Cross-platform and easy to distribute, but blind outside the browser and breaks "one bubble everywhere". | Rejected. |

## 5. Architecture (Approach A)

```
┌──────────────────────── macOS app (Swift, menu-bar, no Dock icon) ────────────────────────┐
│ HotkeyManager ──► BubbleController (pre-built NSPanel, non-activating, floating) ◄── Orb   │
│        │                 ▲ chips / progress / streamed markdown+KaTeX (WKWebView)          │
│        ▼                 │                                                                 │
│ ContextEngine ──► PrivacyGate ──► ContextAssembler ──► Router ──► LLM layer               │
│  • WindowCapture (ScreenCaptureKit, single window, excludes own windows)   ├─ AnthropicAdapter│
│  • AXReader (app, window title, selected/focused text)                     └─ OpenAICompat.  │
│  • BrowserContextCache ◄──────────────┐                                                    │
│  • PageFinder (PDFKit + Vision OCR)   │      ConversationStore (in-memory, 10-min resume)  │
│  BridgeServer (WebSocket, 127.0.0.1, token-authenticated)                                  │
└───────────────────────────────────────┼────────────────────────────────────────────────────┘
                                        │ push: active tab + context updates; request/response: PDF fetch, viewer scroll
┌───────────────────────────────────────┴──── Chromium extension (MV3, JS) ─────────────────┐
│ Service worker: holds the WebSocket, tracks active tab, routes messages                   │
│ Content scripts: youtube.com (transcript/playhead/chapter) · any page (visible text,      │
│   MathJax/KaTeX LaTeX) · Drive viewer (file id, download-blocked detection, scroll+capture)│
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

### 5.1 The summon sequence (where the speed comes from)

1. **Hotkey (t=0).** The bubble panel is created at launch and kept hidden; summoning only positions and shows it, and gives its text field keyboard focus without activating the app (so the front app stays "front" for capture). Target < 0.1 s.
2. **While the user types:** nothing is captured, gathered or outlined. Startup checks run and the HTTPS connection to the default routed model is pre-warmed (the context kind isn't known yet). The user can move to another tab or app; the panel is non-activating, so whatever they move to stays frontmost.
3. **Enter (every question, follow-ups included).** A fresh front-window capture starts, and a live `Reading screen…` step shows so the bubble is never blank. The capture does the following in parallel:
   - Identify front app (bundle id) and window; run the **PrivacyGate** first. If blocked, capture nothing and show a "context off for this app" chip; only that notice is sent.
   - Capture the front window image via ScreenCaptureKit with a filter that excludes the app's own windows; downscale (~1500 px long edge).
   - Read accessibility text: app name, window title, selected text, focused element text.
   - If the front app is a known Chromium browser, read the **already-cached** context for its active tab from `BrowserContextCache` (pushed earlier by the extension — no round-trip on the hot path).
   - Each piece appears as a removable **chip** as it lands, showing what was used. The capture glow flashes when the window frame lands.
4. **After the capture, or after 500 ms with whatever has landed** (later pieces are dropped, so the chips stay true to what was sent). Route the model, then detect page references in the question (§5.5). If none: assemble context and stream. If present: run PageFinder, using the tab from this capture, with live steps, then stream.

**Exceptions.**
- *Region:* selecting a region captures immediately (§5.3). That region is the context for the next question and for follow-ups while this bubble stays open, with no new capture. A new region replaces it. Closing the bubble, or removing the region's chip, goes back to capture on send.
- *Pop-out:* while the pop-out window is key, Companion can itself be frontmost. A capture that reports Companion, or no front app, keeps the previous context rather than replacing it with an empty one.
- *Removed chips:* a chip the user removes excludes that kind of piece from later captures until the bubble closes or New Chat. There is no pre-send preview. Selecting a new region is an explicit request, so it brings region images back.

Instrument every step (hotkey → panel visible → first keystroke accepted, then submit → context first → context complete → first token) and log timings; the success test depends on these numbers. Submit → first token includes capture time.

### 5.2 Bubble UI (approved mockup: `.superpowers/brainstorm/.../bubble-flow.html`)

- Opens near the cursor. A selected region is avoided so the bubble doesn't cover it; nothing has been captured when a normal summon opens, so there's nothing else to avoid.
- **Movable:** drag the bubble by any empty part (the chrome around the content, the chip row's gaps, the footer). Dragging in the input or the answer still selects text, and buttons still work. Dragging doesn't activate the app or change the front app. Once dragged, its top-left corner holds while the answer grows and through follow-ups, kept inside the visible frame of the display it is on. The next fresh summon opens at the cursor again; the position isn't saved.
- Top row: context chips (window thumbnail, `▶ 12:41 · Ch. 3`, `transcript 9:41–12:41`, `pp. 231–232`), each removable with ✕. Chips appear when a question is sent (§5.1), or at once for a selected region.
- Input; footer shows current model (Tab cycles models for this question) and Hint mode (⌘H).
- Answers stream as Markdown with KaTeX math. Bubble grows to a max size then scrolls; **↗ pop out** moves the thread into a larger draggable window.
- Esc closes; ⌘N starts a new chat.
- **Conversation continuation:** if summoned again within **10 minutes** of the last interaction, the previous thread resumes and each new question's capture becomes that turn's context. Otherwise a fresh thread starts.
- **Idle orb:** small always-on-top orb, draggable, hideable in settings; click = summon. Its **look** follows `design/glow-prototype.html`; the prototype's ~1 s glide-into-a-bar opening is **not** used, because typing must be possible in < 0.1 s — the bubble opens instantly at the cursor as in the approved mockup. Later a pet character can "own" the orb and bubble.
- **Capture glow:** when a question's capture lands (at selection for a region), a brief glow outlines the window (or region) being captured, so the user sees what was read. Implemented as a transparent, click-through overlay window that never takes focus and is excluded from capture (it's the app's own window). Purely visual; must not delay the bubble.
- **Hotkeys:** main = ⌥Space (matches the prototypes), region capture = a second configurable hotkey (crosshair drag). Both rebindable. Note: ⌥Space is also ChatGPT's desktop default — the settings screen must make rebinding obvious.

### 5.3 Context readers

**Generic window (any app):** screenshot + accessibility text. This also covers PDFs viewed in Preview (treated as screenshots in v1) and coding questions asked from Terminal/docs pages.

**Region capture:** crosshair overlay; the selected rectangle replaces the window screenshot as the image context.

**YouTube (extension, pushed on page load and as playback advances).** Scope is **youtube.com tabs** — that's where the owner watches. YouTube players embedded in other sites (Classroom, Slides, Edpuzzle, Khan) are out of v1 and fall back to generic window capture.
- Title, channel, chapter name (if chapters exist), playhead time.
- Transcript with timestamps; the app sends **from ~3 minutes before the playhead up to the playhead** by default.
- The current frame comes from the window screenshot (equations on screen are visible to the model).
- If the question needs earlier material ("the formula from the start"), the full transcript is available on request (the model can ask for it via an internal "get more transcript" step, or the app can include it when the question references earlier parts — builder's choice, see §10).
- No captions → title/chapter/playhead + screenshot only.

**Web pages (extension):** visible text of the page (bounded size), plus **exact LaTeX** extracted from MathJax/KaTeX/MathML annotations when present. When LaTeX is extracted, the "Reading:" line is skipped.

**Privacy gate:** a built-in, user-editable blocklist of apps (password managers, Keychain Access, Messages, Discord, banking apps) and sites (banking domains, password-manager web vaults). Secure text fields are never read. No review step — context is attached instantly; the visible chips are the user's check.

*Unknown site (designer's call):* when the front app is a browser but the extension has no context for the tab (not connected yet, incognito, a browser without the extension), the app reads the URL from the browser's address bar via Accessibility and applies the site blocklist to that. If the URL still can't be determined, it captures anyway (the owner prioritized instant context) and shows a "site not checked" chip so it's visible.

### 5.4 Model layer (provider-agnostic)

- A single internal message format: system prompt, turns, content blocks (text, image), streamed events (text delta, done, error), and **tool-call blocks designed in from the start** (unused in v1, needed for Notion in v2).
- **AnthropicAdapter** (native Messages API, streaming) and **OpenAICompatibleAdapter** (chat-completions shape, configurable base URL + key → OpenAI, Gemini, OpenRouter, Groq, local servers).
- **Routing (hybrid):** each context type has a default model; Tab overrides for the current question.
  - Defaults (my call, editable in settings): YouTube / generic window → fast model (Claude Haiku 4.5); page-finder results and pages where LaTeX was extracted → strong model (Claude Sonnet 5.5).
  - Auto-routing by difficulty is deferred until scaling makes cost matter.
- **Prompting behaviors:** answer the question actually asked ("hint?", "check my work", "solve"); **Hint mode** (⌘H) switches to Socratic hints; when the problem was read from pixels, begin with a one-line `Reading: <problem in LaTeX>` so misreads are obvious.

### 5.5 Page finder (named textbook pages)

Triggered when the question names pages ("pages 231–232", "p. 231", "#4 on page 231"). Steps, each shown live in the bubble:

1. **Find the document.** The owner usually asks **from the Classroom assignment page** (the textbook is an attachment there), not from an open PDF tab. Resolution order:
   1. Front tab is a Drive PDF viewer → use that file.
   2. Front tab is a Classroom assignment page → the extension lists its attachments (Drive file ids + titles). One PDF → use it. Several → prefer a title matching the question ("textbook", "worksheet", a name), otherwise the PDF with the most pages, and show the choice as a chip the user can switch with one click.
   3. Nothing on the current page → reuse the **last document the page finder used** this session (designer's call), shown as a "using: Algebra 2 Textbook.pdf" chip.
   4. Still nothing → say so plainly.
2. **Get the file.** The extension downloads the PDF from Drive with the user's logged-in session (downloads **usually work** for the owner's files, so this is the main path) and hands the bytes to the app. Downloaded PDFs and their page maps are **cached by Drive file id for the session** (temporary cache folder, cleared on quit — designer's call) so follow-up questions about the same textbook skip the download.
2. **Map printed page numbers → PDF pages**, in order of preference:
   1. PDF page labels (PDFKit exposes them when the publisher set them).
   2. Numbers printed in each page's header/footer text.
   3. On-device OCR (Vision) of header/footer regions for scanned books.
3. **Send the pages**: render matched pages to images (+ extracted text) and attach. Show "Found pp. 231–232 → PDF pp. 247–248" with **thumbnails** so the user can confirm.
4. **Cap:** at most ~10 pages per question (my call, to protect speed and cost).

**Fallback when the teacher has disabled downloads** (rare for the owner's files, so built **last in v1** and allowed to slip to a v1.1 if the main path takes longer): the extension opens/drives the Drive viewer — jumps/scrolls, captures the visible page, the app OCRs the printed page number, and it converges on the target (use the observed offset between printed and viewer page numbers to jump close, then step) — captures the target pages, then returns the viewer to where the user was. Progress shows "Scrolling the viewer to find p. 231…". Expected 5–20 s.

**If it still can't find the pages:** say so plainly and answer from what's visible; never guess silently.

The user does not need to see the viewer move in the normal path — only correct capture matters.

### 5.6 App ↔ extension bridge

- The app runs a WebSocket server bound to **127.0.0.1** only.
- **Pairing:** the app shows a one-time token; the user pastes it into the extension's options page once. Every connection must present it. (Avoids browser-specific native-messaging host registration, which is undocumented for Dia.)
- **Push model:** content scripts send context updates to the service worker, which forwards them to the app; the app caches the latest context per tab and knows the active tab. This keeps the hot path free of extension round-trips and tolerates service-worker sleep (an open WebSocket with periodic traffic keeps the worker alive in current Chromium; if it sleeps, the next content-script event wakes it and it reconnects).
- **What "only on send" means (designer's call):** *nothing leaves the Mac and nothing reaches a model until the user sends a question.* To meet the speed budget, the extension keeps the **active tab's** context ready locally in memory (YouTube transcript fetched once per video; page text/LaTeX refreshed on navigation and debounced scroll). The extension applies the site blocklist itself before reading anything, so blocked sites are never read even locally. Pre-loaded context is kept in memory for open tabs (so switching back to a video is instant) and dropped when a tab closes, its URL changes, or its site becomes blocked. A Notion page open in the browser is ordinary screen content; the "Notion only on request" rule governs the Notion *integration* (search/save via MCP), not seeing a Notion page you are looking at.
- **Fallback:** if the cache is empty for the active tab, the app requests context during the capture at Enter (still within budget), then falls back to screenshot + AX if the extension doesn't answer in ~300 ms.
- **Request/response messages** (slow path only): `fetchDrivePdf`, `scrollViewerAndCapture`, `getFullTranscript`.

### 5.7 Settings & storage

- API keys: Keychain. Provider list, model per context, hotkeys, orb on/off, blocklist: local preferences.
- Conversations: **in memory only** in v1 (enough for 10-minute continuation). Persistent history is a later opt-in.
- Captured images/text are never written to disk, except the session PDF cache (§5.5), which lives in a temporary cache folder and is cleared on quit.

## 6. Decisions log

| Area | Decision | Source |
|---|---|---|
| Why | Fewer steps + richer-than-one-frame context; provider-agnostic | Owner |
| Audience | Owner first; scale to students if good | Owner |
| Priority | YouTube → math (Classroom PDFs, web pages) → coding (deferred) | Owner |
| Stack | Native Swift app + Chromium MV3 extension; learn Swift + a little JS; Python later for a backend | Owner |
| Brain location | Approach A (app is the brain) | Owner |
| Models | Claude native + OpenAI-compatible adapters in v1 | Owner |
| Routing | Per-context default + one-key override | Owner |
| Capture | Front window by default + region hotkey; only when a question is sent or a region is selected (changed after first real use: the owner opens the bubble, then moves tabs) | Owner |
| Bubble position | Draggable; sticks until the bubble closes; next summon opens at the cursor | Owner |
| UI | Cursor bubble, smart placement, grow-then-scroll, pop-out; optional idle orb | Owner |
| YouTube context | Last ~3 min of transcript + frame + title/chapter | Owner approved proposal |
| PDFs | Google Classroom/Drive via extension download (usually allowed → main path); viewer-scroll fallback if blocked, built last; Preview = screenshot only | Owner |
| Where page questions are asked | Usually from the Classroom **assignment page** → find the PDF among its attachments | Owner |
| Video source | youtube.com tabs only in v1; embedded players fall back to generic capture | Owner |
| Orb | Look of the glow prototype + instant capture glow; no slow opening animation | Owner |
| Math answers | Answer what's asked; Hint mode toggle; non-blocking "Reading:" line | Proposal, not objected to |
| Memory | Resume thread if summoned within 10 min | Owner |
| Privacy | Always-skip blocklist; otherwise instant context, no review step | Owner |
| Notion | v2, read + save, **only on explicit request** | Owner |
| Success | 2 weeks daily use; < 0.8 s hotkey→typing | Owner |
| Coding | Out of v1, kept on the future list | Owner |

**Calls made by the designer (owner should check):** fast/strong model defaults per context; ~10-page cap; WebSocket + pasted token for the bridge; in-memory-only conversations; Notion save target = named page or a settings-chosen inbox page; region hotkey binding; unknown-site capture rule (§5.3); extension pre-loads the active tab locally but sends nothing until a question is sent (§5.6); reuse of the last textbook when the page has none (§5.5); session PDF cache (§5.5).

## 7. Error handling principles

- Every failure is visible and specific in the bubble ("Couldn't download — teacher disabled downloads. Scrolling the viewer instead…", "Extension not connected", "Anthropic API error 529 — retry / switch model").
- Missing context never blocks a question: degrade to whatever was captured and show which chips are missing.
- Model errors offer a one-key switch to another configured model.
- Permissions missing → the bubble still opens and explains which permission to grant, with a button to open the right System Settings pane.

## 8. Testing approach

- **Unit-testable cores** (pure logic, test-first): page-reference parsing; printed-page → PDF-page mapping (fixture PDFs: with labels, offset without labels, scanned — plus 2–3 of the owner's real Classroom textbook PDFs, kept out of the repo); Classroom attachment selection (saved assignment-page HTML fixtures); transcript windowing; LaTeX extraction from saved HTML fixtures; router rules; adapter request building and stream parsing (recorded responses); conversation-resume timing; privacy gate matching.
- **Manual/instrumented:** summon latency, first-token latency, capture correctness across apps, extension reconnection after the browser sleeps — tracked via the timing log in §5.1.
- **Daily-use log** during the two-week test: note every time the owner fell back to screenshot-and-paste and why.

## 9. Roadmap beyond v1

**v2**
- **Notion via MCP, explicit only:** "check my Notion …" / `@notion` searches; "save this to Notion" saves context + question + answer to a named page, else to an inbox page chosen in settings, where the owner's existing organizer AI sorts it. Requires the tool-call path in both adapters and an MCP client in the app.
- On-device OCR/redaction pass before sending, if privacy or cost needs it.
- Cost meter.

**Later**
- Coding: VS Code/Cursor extension for exact file + diagnostics (only if daily use shows a need).
- Preview PDFs via the page finder (app resolves the open file, same PDFKit pipeline).
- System-audio capture for lectures/Zoom/local video.
- Opt-in encrypted history; flashcards from saved notes; link to the assignment tracker.
- Expose captured context to other AI tools (e.g. Claude Code, Cursor) via MCP.
- Pet skin using `design/pet-casting.html` characters and states.
- Agentic actions / general screen control.
- Auto-routing by difficulty; Python backend (API proxy, accounts, billing) for scaling to other students; Developer ID signing + notarization; Windows.

## 10. Left to the builder

- Project structure, module boundaries inside the app, SwiftUI vs AppKit split, minimum macOS version (ScreenCaptureKit single-frame capture needs macOS 14+).
- Exact YouTube transcript retrieval technique (page player data vs. transcript panel), and whether "earlier in the video" uses a model tool call or a heuristic.
- Bubble placement algorithm details; KaTeX/Markdown bundling in WKWebView.
- WebSocket port selection and reconnection policy; message schema.
- Drive download mechanics and how "downloads disabled" is detected; viewer-navigation strategy details.
- Starter blocklist contents.
- System prompt wording for answer style, Hint mode and the "Reading:" line.
