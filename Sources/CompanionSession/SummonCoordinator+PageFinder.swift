import CompanionCore
import CompanionPageFinder
import CompanionUI
import Foundation

extension SummonCoordinator {
    public func attach(pageFinder: PageFinder, browser: any BrowserContextProviding) {
        self.pageFinder = pageFinder
        self.browser = browser
    }

    /// Runs the finder with live steps, then streams. Returns false if the question isn't a page question.
    func runPageFlow(id: UUID, question: String, preferred: DriveFileRef?) async -> Bool {
        guard let pageFinder, let reference = PageReferenceParser.parse(question) else { return false }
        lastPageQuestion = question
        run?.thinkingStepID = nil
        var steps: [StepItem] = []
        if reference.requestedCount > reference.pages.count {
            steps.append(StepItem(text: "Only the first 10 pages will be sent (you asked for \(reference.requestedCount)).", state: .done))
        }
        viewModel.setSteps(steps)

        let tab = await usableTab()
        guard isCurrent(id) else { return true }

        let (progress, continuation) = AsyncStream.makeStream(of: PageFinderStep.self)
        let progressLoop = Task { @MainActor in
            for await step in progress where isCurrent(id) {
                appendStep(step.displayText, state: .active)
            }
        }
        let lastUsed = lastUsedDocument
        // A hung download ignores cancellation; close, a new question and quit must not wait for it.
        let outcome = await abandonOnCancel {
            await pageFinder.find(reference, question: question, tab: tab, lastUsed: lastUsed, preferred: preferred) {
                continuation.yield($0)
            }
        }
        continuation.finish()
        await progressLoop.value
        guard isCurrent(id), let outcome else { return true }

        switch outcome {
        case let .found(choice, pages, missing):
            attach(pages: pages, choice: choice)
            settleActiveStep(as: .done)
            if let page = missing.first { appendStep(notFoundText(page, choice.current), state: .failed) }
            let model = chosenModel()
            appendStep("Sending pages to \(model.displayName)…", state: .active)
            await streamAnswer(id: id, model: model)
        case .noDocument:
            settleActiveStep(as: .done)
            answerWithoutModel("I couldn't find a PDF on this page. Open the textbook or its Classroom assignment and ask again.")
        case let .notFound(document, pages):
            settleActiveStep(as: .done)
            if let page = pages.first { appendStep(notFoundText(page, document), state: .failed) }
            await streamAnswer(id: id, model: chosenModel())
        case let .failed(message):
            settleActiveStep(as: .failed)
            appendStep(message, state: .failed)
            await streamAnswer(id: id, model: chosenModel())
        }
        return true
    }

    /// nil from the cache means no tab (e.g. mid-navigation); the finder then falls back to `lastUsed`.
    private func usableTab() async -> TabContext? {
        guard let tab = await browser?.cachedActiveTabContext(), !tab.blocked else { return nil }
        if let front = context?.front, !KnownBrowsers.isBrowser(front.bundleID) { return nil }
        if let tabId = context?.tabId, tabId != tab.tabId { return nil }
        return tab
    }

    private func attach(pages: [RenderedPage], choice: DocumentChoice) {
        viewModel.setPageThumbnails(pages)
        viewModel.setDocumentChoice(choice)
        lastUsedDocument = choice.current
        var updated = context ?? CapturedContext(front: nil, privacy: .allowed, kind: .pdfPages, items: [], isComplete: true)
        updated.items.removeAll { if case .pdfPages = $0.piece { true } else { false } }
        updated.items.append(ContextItem(piece: .pdfPages(pages)))
        updated.kind = .pdfPages
        applyContext(updated)
    }

    private func notFoundText(_ page: Int, _ document: DriveFileRef) -> String {
        "Couldn't find p. \(page) in “\(document.title)”."
    }

    private func appendStep(_ text: String, state: StepState) {
        settleActiveStep(as: .done)
        viewModel.setSteps(viewModel.steps + [StepItem(text: text, state: state)])
    }

    private func settleActiveStep(as state: StepState) {
        viewModel.setSteps(viewModel.steps.map { step in
            var step = step
            if step.state == .active { step.state = state }
            return step
        })
    }
}
