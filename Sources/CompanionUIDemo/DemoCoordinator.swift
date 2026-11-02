import AppKit
import CompanionCore
import CompanionUI

/// Plays the approved mockup's frames with fake data.
@MainActor final class DemoCoordinator: BubbleActions {
    private let viewModel: BubbleViewModel
    private let bubble: BubbleController
    var settingsWindow: SettingsWindowController?
    private var chipsTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    private var streamingID: UUID?
    private var isSonnet = false

    init(viewModel: BubbleViewModel, bubble: BubbleController) {
        self.viewModel = viewModel
        self.bubble = bubble
    }

    // MARK: Summon

    func summon() {
        if bubble.isVisible {
            bubble.focusInput()
            return
        }
        let screen = NSScreen.screens.first?.visibleFrame ?? .zero
        CaptureGlow.flash(screen.insetBy(dx: 160, dy: 120))
        present(cursor: NSEvent.mouseLocation, avoiding: nil, first: .windowImage(DemoContent.windowImage()))
    }

    func summonRegion() {
        if bubble.isVisible {
            bubble.focusInput()
            return
        }
        let cursor = NSEvent.mouseLocation
        let rect = CGRect(x: cursor.x - 200, y: cursor.y - 130, width: 400, height: 260)
        CaptureGlow.flash(rect)
        present(cursor: cursor, avoiding: rect, first: .regionImage(DemoContent.windowImage()))
    }

    private func present(cursor: CGPoint, avoiding: CGRect?, first: ContextPiece) {
        setModel(sonnet: isSonnet)
        bubble.show(cursor: cursor, avoiding: avoiding)
        let items = [ContextItem(piece: first), ContextItem(piece: .youtubeVideo(DemoContent.youtube)),
                     ContextItem(piece: .transcriptWindow(segments: [], from: 581, to: 761))]
        chipsTask?.cancel()
        chipsTask = Task { [viewModel] in
            for count in 1...items.count {
                viewModel.setContext(CapturedContext(front: nil, privacy: .allowed, kind: .youtube,
                                                     items: Array(items.prefix(count)), isComplete: count == items.count))
                try? await Task.sleep(for: .milliseconds(60))
                if Task.isCancelled { return }
            }
        }
    }

    private func setModel(sonnet: Bool) {
        isSonnet = sonnet
        viewModel.setModelName(sonnet ? "Sonnet 5.5" : "Haiku 4.5")
    }

    // MARK: BubbleActions

    func bubbleDidSubmit(_ text: String) {
        cancelAnswer()
        viewModel.appendUserMessage(text)
        viewModel.setBusy(true)
        viewModel.showError(nil)
        let question = text.lowercased()
        if question.contains("pages 231–232") || question.contains("pages 231-232") {
            runPageFinder()
        } else if question.contains("error") {
            viewModel.setBusy(false)
            viewModel.showError(BubbleErrorBanner(message: "Anthropic API error 529 — overloaded.", offerModelSwitch: true))
        } else if question.contains("key") {
            viewModel.setBusy(false)
            viewModel.showError(BubbleErrorBanner(message: "No Anthropic API key yet.", offerSettings: true))
        } else if question.contains("long") {
            stream(DemoContent.longAnswer)
        } else {
            stream(DemoContent.standardAnswer)
        }
    }

    func bubbleDidRemoveContextItem(_ id: UUID) {}

    func bubbleDidRequestModelCycle() { setModel(sonnet: !isSonnet) }

    func bubbleDidToggleHint() { viewModel.setHintMode(!viewModel.hintMode) }

    func bubbleDidRequestNewChat() {
        cancelAnswer()
        viewModel.resetThread([])
        viewModel.setSteps([])
        viewModel.setPageThumbnails([])
        viewModel.setDocumentChoice(nil)
        viewModel.showError(nil)
    }

    func bubbleDidClose() {
        cancelAnswer()
        bubble.hide()
    }

    func bubbleDidRequestSettings() { settingsWindow?.show(tab: .models) }

    func bubbleDidRequestModelSwitchAfterError() {
        setModel(sonnet: !isSonnet)
        viewModel.showError(nil)
        viewModel.setBusy(true)
        stream(DemoContent.standardAnswer)
    }

    func bubbleDidSelectDocument(_ file: DriveFileRef) {
        guard let choice = viewModel.documentChoice else { return }
        viewModel.setDocumentChoice(DocumentChoice(current: file, alternatives: [choice.current]))
    }

    // MARK: Fake work

    private func runPageFinder() {
        answerTask = Task { [weak self] in
            guard let self else { return }
            viewModel.setSteps([StepItem(text: "Downloading “Algebra 2 Textbook.pdf”…", state: .active)])
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            let got = StepItem(text: "Got the PDF from Drive (412 pages)", state: .done)
            viewModel.setSteps([got, StepItem(text: "Book p.231 → PDF p.247 (page labels)", state: .active)])
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            let sending = StepItem(text: "Sending pages to Sonnet 5.5…", state: .active)
            viewModel.setSteps([got, StepItem(text: "Book p.231 → PDF p.247 (page labels)", state: .done), sending])
            setModel(sonnet: true)
            viewModel.setDocumentChoice(DocumentChoice(current: DemoContent.textbook, alternatives: [DemoContent.worksheet]))
            viewModel.setPageThumbnails([DemoContent.page("231", pdfIndex: 246), DemoContent.page("232", pdfIndex: 247)])
            stream(DemoContent.standardAnswer)
        }
    }

    private func stream(_ answer: String) {
        answerTask?.cancel()
        let id = viewModel.beginAssistantMessage()
        streamingID = id
        answerTask = Task { [weak self] in
            var first = true
            for word in answer.split(separator: " ", omittingEmptySubsequences: false) {
                if Task.isCancelled { return }
                self?.viewModel.appendDelta(first ? String(word) : " " + word, to: id)
                first = false
                try? await Task.sleep(for: .milliseconds(40))
            }
            if Task.isCancelled { return }
            self?.finishStreaming()
        }
    }

    private func finishStreaming() {
        if let id = streamingID { viewModel.finishAssistantMessage(id) }
        streamingID = nil
        viewModel.setBusy(false)
        viewModel.setSteps(viewModel.steps.map { StepItem(id: $0.id, text: $0.text, state: .done) })
    }

    private func cancelAnswer() {
        answerTask?.cancel()
        answerTask = nil
        if let id = streamingID { viewModel.finishAssistantMessage(id) }
        streamingID = nil
        viewModel.setBusy(false)
    }
}
