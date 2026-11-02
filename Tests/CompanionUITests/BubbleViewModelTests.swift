import CompanionCore
import CompanionTestSupport
import Foundation
import Testing
@testable import CompanionUI

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
    @Test func settersStoreValues() {
        let m = ThreadMessage(role: .user, markdown: "m"), s = StepItem(text: "s", state: .active)
        let p = RenderedPage(printedLabel: "231", pdfIndex: 246, image: Fixtures.samplePNG(), text: "")
        let c = DocumentChoice(current: DriveFileRef(fileId: "a", title: "A", mimeType: nil), alternatives: [])
        let b = BubbleErrorBanner(message: "bad", offerModelSwitch: true)
        vm.setContext(nil); #expect(vm.context == nil)
        vm.setModelName("Sonnet 5.5"); #expect(vm.modelName == "Sonnet 5.5")
        vm.setHintMode(true); #expect(vm.hintMode)
        vm.resetThread([m]); #expect(vm.thread == [m])
        vm.setSteps([s]); #expect(vm.steps == [s])
        vm.setPageThumbnails([p]); #expect(vm.pageThumbnails == [p])
        vm.setDocumentChoice(c); #expect(vm.documentChoice == c)
        vm.showError(b); #expect(vm.error == b)
        vm.showError(nil); #expect(vm.error == nil)
        vm.setBusy(true); #expect(vm.isBusy)
        #expect(vm.modelName == "Sonnet 5.5" && vm.hintMode && vm.thread == [m] && vm.steps == [s] && vm.documentChoice == c && vm.inputText == "")
    }
    @Test func placeholderFollowsThread() {
        #expect(vm.inputPlaceholder == "Ask about this…"); vm.appendUserMessage("q"); #expect(vm.inputPlaceholder == "Follow up…")
    }
}
