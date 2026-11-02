import AppKit
import CompanionCore
import CompanionTestSupport
import SwiftUI
import Testing
@testable import CompanionUI

extension WindowTests { @MainActor @Suite struct BubbleInputTests {
    let vm = BubbleViewModel(), rec = RecordingBubbleActions()
    let input: BubbleInputTextView
    let window: NSWindow
    init() {
        TestApp.ensure()
        vm.actions = rec
        input = BubbleInputTextView(viewModel: vm)
        window = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 380, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        input.frame = CGRect(x: 0, y: 0, width: 380, height: 100)
        window.contentView?.addSubview(input)
        window.makeFirstResponder(input)
    }
    func type(_ text: String) { input.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }

    @Test func returnSubmitsAndClears() {
        type("hi"); input.keyDown(with: keyEvent(36, "\r"))
        #expect(rec.calls == [.submit("hi")]); #expect(input.string == "" && vm.inputText == "")
    }
    @Test func shiftReturnInsertsNewline() {
        type("a"); input.keyDown(with: keyEvent(36, "\r", [.shift]))
        #expect(input.string == "a\n" && vm.inputText == "a\n" && rec.calls.isEmpty)
    }
    @Test func tabCyclesModelWithoutInsertingATab() {
        input.keyDown(with: keyEvent(48, "\t")); #expect(rec.calls == [.cycleModel] && !input.string.contains("\t"))
    }
    @Test func escClosesInsteadOfCompleting() {
        type("x"); input.keyDown(with: keyEvent(53, "\u{1b}")); #expect(rec.calls == [.close])
    }
    @Test func imeCompositionKeysGoToInputMethod() {
        // Each key starts a fresh composition: with no real input method in a test, AppKit's default
        // handling of the first key commits the marked text.
        for (code, ch) in [(36, "\r"), (48, "\t"), (53, "\u{1b}")] as [(UInt16, String)] {
            input.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(input.hasMarkedText())
            input.keyDown(with: keyEvent(code, ch))
        }
        #expect(rec.calls.isEmpty)
    }
    @Test func bubbleViewLaysOutTheMockupState() {
        let png = Fixtures.samplePNG()
        vm.setContext(CapturedContext(front: nil, privacy: .allowed, kind: .youtube, items: [
            ContextItem(piece: .windowImage(png)), ContextItem(piece: .youtubeVideo(youtubeSample)),
            ContextItem(piece: .transcriptWindow(segments: [], from: 581, to: 761))], isComplete: true))
        vm.setSteps([StepItem(text: "a", state: .done), StepItem(text: "b", state: .done), StepItem(text: "c", state: .active)])
        vm.setPageThumbnails([RenderedPage(printedLabel: "231", pdfIndex: 246, image: png, text: ""),
                              RenderedPage(printedLabel: "232", pdfIndex: 247, image: png, text: "")])
        let doc = DriveFileRef(fileId: "d", title: "Algebra 2 Textbook.pdf", mimeType: nil)
        vm.setDocumentChoice(DocumentChoice(current: doc, alternatives: [DriveFileRef(fileId: "w", title: "Worksheet", mimeType: nil)]))
        vm.showError(BubbleErrorBanner(message: "oops", offerModelSwitch: true, offerSettings: true))
        vm.resetThread([ThreadMessage(role: .user, markdown: "q"), ThreadMessage(role: .assistant, markdown: "a")])
        vm.setModelName("Haiku 4.5")
        var h: CGFloat = 0
        let hosting = NSHostingView(rootView: BubbleView(viewModel: vm, answer: AnswerWebController(), input: input, style: .bubble,
                                                         onPopOut: {}, onContentHeight: { h = $0 }))
        hosting.frame = CGRect(x: 0, y: 0, width: 380, height: 500)
        window.contentView?.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded(); #expect(hosting.fittingSize.width == 380); #expect(h >= 72)
    }
}}
