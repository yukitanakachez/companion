@testable import CompanionLLM
import CompanionCore
import CompanionTestSupport
import Testing

private let img1 = Fixtures.samplePNG(width: 4, height: 3)
private let img2 = Fixtures.samplePNG(width: 2, height: 2)

private func ctx(_ pieces: [ContextPiece], front: FrontAppInfo? = nil, privacy: PrivacyDecision = .allowed) -> CapturedContext {
    CapturedContext(front: front, privacy: privacy, kind: .genericWindow, items: pieces.map { ContextItem(piece: $0) }, isComplete: true)
}
private func dia(_ title: String) -> FrontAppInfo {
    FrontAppInfo(bundleID: "company.thebrowser.dia", appName: "Dia", pid: 42, windowTitle: title, windowFrame: nil)
}
private func build(_ question: String = "q", _ context: CapturedContext? = nil, history: [LLMMessage] = [], hint: Bool = false) -> (system: String, messages: [LLMMessage]) {
    PromptBuilder().build(question: question, context: context, history: history, hintMode: hint)
}

struct PromptBuilderTests {
    @Test func baseSystemPromptIsExact() {
        #expect(build().system == PromptBuilder.baseInstructions)
    }

    @Test func hintBlockOnlyInHintMode() {
        #expect(build(hint: true).system == PromptBuilder.baseInstructions + "\n\n" + PromptBuilder.hintModeInstructions)
        #expect(!build(hint: false).system.contains("Hint mode is on"))
    }

    @Test func readingRuleRules() {
        let s = { (c: CapturedContext?) in build("q", c).system }
        #expect(s(ctx([.windowImage(img1)])).hasSuffix(PromptBuilder.readingLineInstruction))
        #expect(s(ctx([.regionImage(img1)])).hasSuffix(PromptBuilder.readingLineInstruction))
        #expect(!s(ctx([.windowImage(img1), .math([MathSnippet(format: .latex, source: "x^2")])])).contains("Reading:"))
        #expect(!s(ctx([.pdfPages([RenderedPage(printedLabel: "231", pdfIndex: 246, image: img1, text: "t")])])).contains("Reading:"))
        #expect(!s(nil).contains("Reading:"))
        #expect(build("q", ctx([.windowImage(img1)]), hint: true).system == [PromptBuilder.baseInstructions, PromptBuilder.hintModeInstructions, PromptBuilder.readingLineInstruction].joined(separator: "\n\n"))
    }

    @Test func youtubeContextIsExact() {
        let yt = YouTubeContext(videoId: "abc123XYZ00", title: "Solving Quadratics by Factoring", channel: "Math Channel", chapter: "Finding the roots",
                                playheadSeconds: 761, durationSeconds: 1450, transcriptStatus: .available,
                                transcript: [TranscriptSegment(start: 1, duration: 2, text: "FULL-TRANSCRIPT-ONLY")])
        let c = ctx([.windowImage(img1), .youtubeVideo(yt),
                     .transcriptWindow(segments: [TranscriptSegment(start: 575, duration: 6.2, text: "so now we factor the left side"),
                                                  TranscriptSegment(start: 740.5, duration: 5, text: "x minus two times x minus three equals zero")], from: 581, to: 761),
                     .selectedText("x^2-5x+6=0")], front: dia("Solving Quadratics by Factoring - YouTube"))
        let m = build("What are the roots?", c).messages
        #expect(m == [LLMMessage(role: .user, content: [.image(img1), .text("""
        <context>
        App: Dia
        Window: Solving Quadratics by Factoring - YouTube

        Image 1: screenshot of the front window

        YouTube video: Solving Quadratics by Factoring
        Channel: Math Channel
        Chapter: Finding the roots
        Position: at 12:41 of 24:10

        Transcript from 9:41 to 12:41:
        [9:35] so now we factor the left side
        [12:20] x minus two times x minus three equals zero

        Selected text:
        x^2-5x+6=0
        </context>

        What are the roots?
        """)])])
    }

    @Test func youtubeWithoutOptionalFields() {
        let yt = YouTubeContext(videoId: "v", title: "T", channel: nil, chapter: nil, playheadSeconds: 61, durationSeconds: nil,
                                transcriptStatus: .unavailable, transcript: [])
        #expect(build("q", ctx([.youtubeVideo(yt)])).messages == [LLMMessage(role: .user, content: [
            .text("<context>\nYouTube video: T\nPosition: at 1:01\n</context>\n\nq")])])
    }

    @Test func webPageContextIsExact() {
        let c = ctx([.webPage(WebPageContext(url: "https://example-homework.test/unit4/q3", title: "Unit 4 Quiz Review",
                                             visibleText: "Question 3. Solve for x.", math: [MathSnippet(format: .latex, source: "IGNORED")])),
                     .math([MathSnippet(format: .latex, source: "x^2-5x+6=0"), MathSnippet(format: .mathml, source: "<math><mi>x</mi></math>")]),
                     .focusedText("x = 2, 3"), .notice(.siteNotChecked)], front: dia("Unit 4 Quiz Review"))
        #expect(build("check my work", c).messages[0].content == [.text("<context>\nApp: Dia\nWindow: Unit 4 Quiz Review\n\nWeb page: Unit 4 Quiz Review\nURL: https://example-homework.test/unit4/q3\nVisible text:\nQuestion 3. Solve for x.\n\nMath on the page (exact source):\n- LaTeX: x^2-5x+6=0\n- MathML: <math><mi>x</mi></math>\n\nScreen text:\nx = 2, 3\n\nNote: site not checked\n</context>\n\ncheck my work")])
    }

    @Test func pdfPagesImagesFirstInOrder() {
        let c = ctx([.pdfPages([RenderedPage(printedLabel: "231", pdfIndex: 246, image: img1, text: "Exercises 5.2"),
                                RenderedPage(printedLabel: "232", pdfIndex: 247, image: img2, text: "")])])
        #expect(build("explain pages 231-232", c).messages[0].content == [.image(img1), .image(img2), .text("<context>\nBook page 231 (PDF page 247), image 1:\nExercises 5.2\n\nBook page 232 (PDF page 248), image 2:\n</context>\n\nexplain pages 231-232")])
    }

    @Test func regionImageLabel() {
        guard case .text(let text)? = build("q", ctx([.regionImage(img1)])).messages[0].content.last else {
            Issue.record("no text block")
            return
        }
        #expect(text.contains("Image 1: screenshot of a selected screen region"))
    }

    @Test func removedItemsAreAbsent() {
        let selection = ContextItem(piece: .selectedText("SECRET"))
        let full = CapturedContext(front: nil, privacy: .allowed, kind: .genericWindow,
                                   items: [ContextItem(piece: .windowImage(img1)), selection], isComplete: true)
        #expect(build("q", full.removingItem(selection.id)).messages[0].content == [.image(img1), .text("<context>\nImage 1: screenshot of the front window\n</context>\n\nq")])
    }

    @Test func blockedContextOmitsAppAndWindowTitle() {
        let c = ctx([.notice(.contextOffForSite)], front: dia("My Bank — balance $1,234"), privacy: .blocked(reason: "This site is on your blocklist"))
        #expect(build("q", c).messages[0].content == [.text("<context>\nNote: context off for this site\n</context>\n\nq")])
    }

    @Test func noContextSendsQuestionOnly() {
        #expect(build().messages == [LLMMessage(role: .user, content: [.text("q")])])
    }

    @Test func historyImagesReplacedAndOnlyNewTurnCarriesImages() {
        let history = [LLMMessage(role: .user, content: [.image(img1), .image(img2), .text("q1")]), LLMMessage(role: .assistant, content: [.text("a1")])]
        let m = build("q2", ctx([.windowImage(img2)]), history: history).messages
        #expect(m[0].content == [.text("[image from an earlier turn omitted]"), .text("q1")])
        #expect(m[1] == LLMMessage(role: .assistant, content: [.text("a1")]))
        #expect(m[2].content.first == .image(img2))
        let imageTurns = m.indices.filter { i in m[i].content.contains { if case .image = $0 { true } else { false } } }
        #expect(imageTurns == [2])
    }

    @Test func normalizesHistoryAfterFailedTurn() {
        let history = [LLMMessage(role: .user, content: [.text("q1")]), LLMMessage(role: .assistant, content: [.text("")]), LLMMessage(role: .user, content: [.text("q2")])]
        #expect(build("q3", history: history).messages == [LLMMessage(role: .user, content: [.text("q1"), .text("q2"), .text("q3")])])
    }
}
