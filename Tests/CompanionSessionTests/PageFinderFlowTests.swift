import CompanionCore
import CompanionPageFinder
@testable import CompanionSession
import CompanionTestSupport
import CompanionUI
import Foundation
import Testing

private let classroomTab: TabContext = {
    let data = try! Fixtures.bridgeFixture("ext-tabContext-classroom.json")
    guard case .tabContext(let tab) = try! JSONDecoder().decode(ExtensionToApp.self, from: data) else { fatalError("fixture") }
    return tab
}()
private let textbook = DriveFileRef(fileId: "1AbCdEfGhIjKlMnOpQrStUvWxYz012345", title: "Algebra 2 Textbook.pdf", mimeType: "application/pdf")
private let worksheet = classroomTab.classroom!.attachments[1]
private let pages = [
    RenderedPage(printedLabel: "231", pdfIndex: 246, image: Fixtures.samplePNG(), text: "a"),
    RenderedPage(printedLabel: "232", pdfIndex: 247, image: Fixtures.samplePNG(), text: "b"),
]
private let found = PageFinderOutcome.found(choice: DocumentChoice(current: textbook, alternatives: [worksheet]), pages: pages, missing: [])

@MainActor private func failedSteps(_ h: Harness) -> [String] {
    h.vm.steps.filter { $0.state == .failed }.map(\.text)
}

@MainActor @Suite struct PageFinderFlowTests {
    @Test func foundPagesAreShownAttachedAndRoutedStrong() async {
        let steps: [PageFinderStep] = [.downloading(title: "Algebra 2 Textbook.pdf"), .downloaded(pageCount: 412),
                                       .matched(printed: 231, pdfIndex: 246, method: .pageLabels)]
        let finder = FakePageFinder(outcome: found, steps: steps)
        let h = Harness(pageFinder: finder, browser: FakeBrowserContextProvider(cached: classroomTab))
        h.coordinator.summon()
        await h.submit("explain pages 231–232")
        #expect(h.vm.steps.map(\.text) == steps.map(\.displayText) + ["Sending pages to Sonnet 5.5…"])
        #expect(h.vm.steps.allSatisfy { $0.state == .done })
        #expect(await finder.calls.first?.tab?.tabId == 33)
        #expect(h.vm.pageThumbnails == pages && h.vm.documentChoice?.current == textbook)
        #expect(h.vm.context?.items.map(\.chipLabel).contains("pp. 231–232") == true)
        #expect(h.provider.requests.last?.model == ModelCatalog.sonnet55 && h.coordinator.lastUsedDocument == textbook)
    }

    /// The owner opens the bubble, then moves to the assignment tab, then presses Enter.
    @Test func theFinderGetsTheTabMovedToAfterOpening() async {
        var before = ctx(complete: true, bundleID: "company.thebrowser.dia")
        before.tabId = 7
        var after = before
        after.tabId = classroomTab.tabId
        let finder = FakePageFinder(outcome: found)
        let browser = FakeBrowserContextProvider(cached: nil)
        let gatherer = FakeGatherer(emissions: [before])
        let h = Harness(gatherer: gatherer, pageFinder: finder, browser: browser)
        h.coordinator.summon()
        await h.coordinator.settle()
        await browser.setCached(classroomTab)
        await gatherer.setEmissions([after])
        await h.submit("explain pages 231-232")
        #expect(await finder.calls.last?.tab?.tabId == classroomTab.tabId)
    }

    @Test func pagesSurviveAFollowUpsCaptureButNotABlockedOne() async {
        let gatherer = FakeGatherer(emissions: [ctx(complete: true)])
        let h = Harness(gatherer: gatherer, pageFinder: FakePageFinder(outcome: found))
        h.coordinator.summon()
        await h.submit("explain pages 231-232")
        await h.submit("and the second one?")
        #expect(h.vm.context?.items.contains { if case .pdfPages = $0.piece { true } else { false } } == true)
        await gatherer.setEmissions([ctx(items: [ContextItem(piece: .notice(.contextOffForApp))], complete: true, privacy: .blocked(reason: "app"))])
        await h.submit("what now?")
        #expect(h.vm.context?.items.count == 1)
        #expect(h.vm.pageThumbnails.isEmpty && h.vm.documentChoice == nil)
    }

    @Test func capNoteWhenMoreThanTenPagesAsked() async {
        let h = Harness(pageFinder: FakePageFinder(outcome: found))
        h.coordinator.summon()
        await h.submit("explain pages 500–520")
        #expect(h.vm.steps.first?.text == "Only the first 10 pages will be sent (you asked for 21).")
        #expect(h.vm.steps.first?.state == .done)
    }

    @Test func noDocumentAnswersWithoutModelCall() async {
        let h = Harness(pageFinder: FakePageFinder(outcome: .noDocument))
        h.coordinator.summon()
        await h.submit("explain page 231")
        #expect(h.vm.thread.last?.markdown == "I couldn't find a PDF on this page. Open the textbook or its Classroom assignment and ask again.")
        #expect(h.vm.thread.last?.isStreaming == false)
        #expect(h.provider.requests.isEmpty && h.vm.isBusy == false && h.coordinator.conversation.turns.isEmpty)
    }

    @Test func notFoundSaysSoThenAnswersFromVisibleContext() async {
        let h = Harness(pageFinder: FakePageFinder(outcome: .notFound(document: textbook, pages: [231, 232])))
        h.coordinator.summon()
        await h.submit("explain pages 231-232")
        #expect(failedSteps(h) == ["Couldn't find p. 231 in “Algebra 2 Textbook.pdf”."])
        #expect(h.provider.requests.map(\.model) == [ModelCatalog.haiku45])
    }

    @Test func missingPageIsReportedAlongsideFoundOnes() async {
        let outcome = PageFinderOutcome.found(choice: DocumentChoice(current: textbook, alternatives: []), pages: pages, missing: [233])
        let h = Harness(pageFinder: FakePageFinder(outcome: outcome))
        h.coordinator.summon()
        await h.submit("explain pages 231-233")
        #expect(failedSteps(h) == ["Couldn't find p. 233 in “Algebra 2 Textbook.pdf”."])
    }

    @Test func failedShowsMessageThenAnswers() async {
        let h = Harness(pageFinder: FakePageFinder(outcome: .failed(message: "The extension didn't answer."), steps: [.downloading(title: "Book")]))
        h.coordinator.summon()
        await h.submit("explain page 231")
        #expect(failedSteps(h).contains("The extension didn't answer."))
        #expect(h.provider.requests.count == 1)
    }

    @Test func lastUsedDocumentIsPassedNextTime() async {
        let finder = FakePageFinder(outcome: found)
        let h = Harness(pageFinder: finder)
        h.coordinator.summon()
        await h.submit("explain page 231")
        await h.submit("explain page 232")
        #expect(await finder.calls[1].lastUsed == textbook)
    }

    @Test func choosingAnotherDocumentReRuns() async {
        let finder = FakePageFinder(outcome: found)
        let h = Harness(pageFinder: finder)
        h.coordinator.summon()
        await h.submit("explain pages 231-232")
        h.coordinator.bubbleDidSelectDocument(worksheet)
        await h.coordinator.settle()
        #expect(await finder.calls.last?.preferred == worksheet)
        #expect(h.vm.thread.filter { $0.role == .user }.count == 1)
        #expect(h.vm.context?.items.filter { if case .pdfPages = $0.piece { true } else { false } }.count == 1)
        #expect(h.provider.requests.count == 2)
    }

    @Test func modelSwitchRetryDoesNotRerunTheFinder() async {
        let finder = FakePageFinder(outcome: found)
        let h = Harness(providers: FakeProviders([ModelCatalog.sonnet55.modelID: FakeLLMProvider(failure: LLMError.http(status: 529, message: ""))]),
                        pageFinder: finder)
        h.coordinator.summon()
        await h.submit("explain pages 231-232")
        #expect(h.vm.steps.last?.state == .failed)
        h.coordinator.bubbleDidRequestModelSwitchAfterError()
        await h.coordinator.settle()
        #expect(await finder.calls.count == 1)
        #expect(h.vm.thread.map(\.markdown) == ["explain pages 231-232", "Hello"])
    }

    @Test func backgroundBrowserTabIsIgnoredWhenFrontAppIsNotABrowser() async {
        let finder = FakePageFinder(outcome: found)
        let h = Harness(gatherer: FakeGatherer(emissions: [ctx(complete: true)]), pageFinder: finder,
                        browser: FakeBrowserContextProvider(cached: classroomTab))
        h.coordinator.summon()
        await h.coordinator.settle()
        await h.submit("explain page 231")
        #expect(await finder.calls.last?.tab == nil)
    }

    @Test func aDifferentOrBlockedTabIsIgnored() async {
        var other = ctx(complete: true, bundleID: "company.thebrowser.dia")
        other.tabId = 99
        let finder = FakePageFinder(outcome: found)
        let h = Harness(gatherer: FakeGatherer(emissions: [other]), pageFinder: finder,
                        browser: FakeBrowserContextProvider(cached: classroomTab))
        h.coordinator.summon()
        await h.coordinator.settle()
        await h.submit("explain page 231")
        #expect(await finder.calls.last?.tab == nil)

        var blocked = classroomTab
        blocked.blocked = true
        let finder2 = FakePageFinder(outcome: found)
        let h2 = Harness(pageFinder: finder2, browser: FakeBrowserContextProvider(cached: blocked))
        h2.coordinator.summon()
        await h2.submit("explain page 231")
        #expect(await finder2.calls.last?.tab == nil)
    }

    /// WS4 clears a tab's snapshot on navigation, so nil simply means "no tab".
    @Test func navigatingTabFallsBackToLastUsed() async {
        let finder = FakePageFinder(outcome: found)
        let browser = FakeBrowserContextProvider(cached: classroomTab)
        let h = Harness(pageFinder: finder, browser: browser)
        h.coordinator.summon()
        await h.submit("explain page 231")
        await browser.setCached(nil)
        await h.submit("explain page 232")
        let last = await finder.calls.last
        #expect(last?.tab == nil && last?.lastUsed == textbook)
    }

    @Test func plainMathDoesNotTriggerFinder() async {
        let finder = FakePageFinder(outcome: found)
        let h = Harness(pageFinder: finder)
        h.coordinator.summon()
        await h.submit("solve x^2 - 5x + 6 = 0")
        #expect(await finder.calls.isEmpty)
        #expect(h.provider.requests.count == 1)
    }

    /// WS4: a cancelled `fetchDrivePDF` can stay pending for 120 s. It must not hold up close or the next question.
    @Test func hungDownloadDoesNotBlockCloseOrANewQuestion() async {
        let finder = FakePageFinder(outcome: found, steps: [.downloading(title: "Book")], hangFirstCall: true)
        let h = Harness(pageFinder: finder)
        h.coordinator.summon()
        h.coordinator.bubbleDidSubmit("explain page 231")
        await waitUntil { h.vm.steps.first?.text == PageFinderStep.downloading(title: "Book").displayText }
        let start = ContinuousClock.now
        h.coordinator.bubbleDidClose()
        await h.coordinator.settle()
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(h.vm.isBusy == false)
        h.coordinator.summon()
        await h.submit("what is 2 + 2?")
        #expect(h.vm.thread.last?.markdown == "Hello")
        await finder.release()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.vm.pageThumbnails.isEmpty)   // the abandoned find's result is dropped
    }

    @Test func removingThePagesChipClearsThumbnailsAndStopsSendingThem() async {
        let h = Harness(pageFinder: FakePageFinder(outcome: found))
        h.coordinator.summon()
        await h.submit("explain pages 231-232")
        let chip = h.vm.context?.items.first { if case .pdfPages = $0.piece { true } else { false } }
        h.coordinator.bubbleDidRemoveContextItem(chip!.id)
        #expect(h.vm.pageThumbnails.isEmpty)
        await h.submit("and in general?")
        #expect(h.provider.requests.last?.messages.last?.content.contains { if case .image = $0 { true } else { false } } == false)
    }
}
