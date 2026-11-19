# Companion

A macOS study companion that is one keystroke away. Press **⌥Space** and a small bubble opens next to your cursor, ready for typing at once. Type a question and press Enter. At that moment Companion reads what you're looking at: the front window, the YouTube video and what was just said, the math on a web page, or the textbook pages you name. It then streams an answer from Claude or any OpenAI-compatible model.

It exists to replace "screenshot, switch app, paste, re-explain" with one step, and to give the model more than a single frame of context.

> Status: v1, built for one user (the author) and in daily use. Runs locally from a build; not notarized or distributed.

## What it does

- **Instant bubble.** A pre-built, non-activating panel opens at the cursor in well under 100 ms. The app you were using stays frontmost. You can drag the bubble by any empty part of it.
- **Capture on send.** Nothing is captured when the bubble opens. Each question, follow-ups included, captures the front window when you press Enter, so you can open the bubble and then switch tabs. A brief glow outlines what was read, and **chips** show exactly what was sent. Remove a chip and that kind of context stays out until you close the bubble.
- **Region capture.** **⌥⇧Space** lets you drag a rectangle. That region becomes the context for the question and its follow-ups.
- **Browser context** (Chromium extension, tested in Dia): for YouTube, the title, chapter, playhead and the last ~3 minutes of transcript. For web pages, the visible text plus exact LaTeX from MathJax/KaTeX.
- **Page finder.** Ask "explain pages 231–232" from a Google Classroom assignment or Drive PDF. Companion downloads the PDF through your browser session, maps *printed* page numbers to PDF pages (page labels, header/footer text, or on-device OCR), and sends those pages, with thumbnails so you can check them.
- **Provider-agnostic models.** Native Anthropic adapter plus a generic OpenAI-compatible one (OpenAI, Gemini, OpenRouter, Groq, local servers). Each context type has a default model; **Tab** switches the model for one question.
- **Study behaviours.** Hint mode (**⌘H**) gives Socratic hints. When a problem is read from pixels, the answer starts with a `Reading: …` line so misreads are obvious.
- **Privacy.** An editable blocklist of apps and sites (password managers, messaging, banking). A blocked app or site sends only a "context off" notice. Secure text fields are never read. API keys live in the Keychain. Conversations stay in memory only and resume if you summon again within 10 minutes.

Keys: **Esc** closes, **⌘N** starts a new chat, **↗ pop out** moves the thread into a larger window.

## Architecture

```
macOS app (Swift, menu bar)                      Chromium extension (MV3, TypeScript)
  hotkey → bubble panel → coordinator              service worker: WebSocket + active tab
  capture (ScreenCaptureKit + Accessibility)  ◄──  content scripts: YouTube, page text/LaTeX,
  privacy gate → context → router → LLM            Drive/Classroom PDFs
  page finder (PDFKit + Vision)                    (127.0.0.1 only, pairing-token auth)
```

The app is the brain. The extension keeps the active tab's context ready locally and pushes it to the app, so nothing on the hot path waits for a browser round-trip. Nothing leaves the Mac until you send a question.

| Path | What's there |
|---|---|
| `Sources/CompanionCore` | Shared types and protocols (the frozen contract between modules) |
| `Sources/CompanionLLM` | Anthropic and OpenAI-compatible adapters, router, prompt builder, Keychain store |
| `Sources/CompanionCapture` | Window/region capture, Accessibility reader, privacy gate, context gatherer |
| `Sources/CompanionBridge` | Local WebSocket server, pairing, per-tab context cache, PDF requests |
| `Sources/CompanionPageFinder` | Page-reference parsing, printed→PDF page mapping, rendering, document choice |
| `Sources/CompanionUI` | Bubble panel, answer renderer (WKWebView + KaTeX), orb, capture glow, hotkeys, settings |
| `Sources/CompanionSession` | Summon coordinator, conversation store, latency trace, permissions |
| `App/` | The app target (generated with XcodeGen from `project.yml`) |
| `extension/` | The browser extension |
| `ui-web/` | The answer renderer's web bundle (Markdown + KaTeX) |
| `contracts/` | App ↔ extension message schemas and fixtures |
| `docs/superpowers/` | Design spec, build plans and the end-to-end verification checklist |

## Requirements

- macOS 14+ on Apple Silicon
- Xcode with Swift 6, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Node 24+ for the extension and renderer
- An Anthropic API key and/or an OpenAI-compatible endpoint

## Build and run

1. **Signing (once).** Copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and set your team ID. The real file is git-ignored. A stable signing identity matters: without one, macOS drops the Screen Recording and Accessibility grants on every rebuild.
2. **Run the app:**
   ```bash
   scripts/run-app.sh
   ```
   This generates the Xcode project, builds into `.build/xcode` and opens the app. Grant **Screen Recording** and **Accessibility** when asked, then add your API key in Settings (it's stored in the Keychain).
3. **Install the extension:**
   ```bash
   cd extension && npm ci && npm run build
   ```
   In your Chromium browser, open the extensions page, enable Developer mode, then **Load unpacked** and pick `extension/dist`. Paste the pairing token from Companion's Settings into the extension's options page.

## Tests

```bash
scripts/test-all.sh
```

This runs the Swift build and tests (Swift Testing), type-checks `contracts/`, and runs the extension and renderer test suites. Some UI tests create real windows, so avoid typing elsewhere while they run.

Manual end-to-end checks that need real accounts, permissions and a browser are listed in `docs/superpowers/verification/2026-11-01-v1-e2e.md`.

## Secrets

No keys are stored in this repository. API keys go in the macOS Keychain, the pairing token is generated per install, and personal signing settings live in the git-ignored `Config/Signing.local.xcconfig`. The token in `contracts/fixtures/` is a made-up test value. Don't commit real textbook PDFs.
