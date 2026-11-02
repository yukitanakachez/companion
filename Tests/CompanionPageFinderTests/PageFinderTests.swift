@testable import CompanionPageFinder
import CompanionCore
import CompanionTestSupport
import Foundation
import Testing

private func idleViewer() -> FakeViewerDriver {
    FakeViewerDriver(info: ViewerInfo(pageCount: 1, currentIndex: 0), page: { _ in Fixtures.samplePNG() })
}

private let textbookPDF = RawPDF.make(pageCount: 300, nums: TestPDF.textbookNums)

private func textbookFetcher() -> FakeDocumentFetcher {
    FakeDocumentFetcher(files: [FixtureTabs.textbook.fileId: (textbookPDF, "Algebra 2 Textbook.pdf")])
}

private func makeFinder(_ fetcher: FakeDocumentFetcher, viewer: FakeViewerDriver = idleViewer()) -> PageFinder {
    PageFinder(fetcher: fetcher, viewer: viewer, cache: PDFSessionCache(directory: temporaryDirectory()))
}

private func find(_ finder: PageFinder, _ question: String, tab: TabContext?, lastUsed: DriveFileRef? = nil,
                  recorder: StepRecorder = StepRecorder()) async throws -> PageFinderOutcome {
    await finder.find(try #require(PageReferenceParser.parse(question)), question: question, tab: tab,
                      lastUsed: lastUsed, preferred: nil, progress: recorder.callback)
}

@Test func findsPagesFromClassroomAttachment() async throws {
    let finder = makeFinder(textbookFetcher())
    let q = "explain pages 231-232 of the textbook", rec = StepRecorder()
    let outcome = try await find(finder, q, tab: try FixtureTabs.classroom(), recorder: rec)
    #expect(rec.steps == [.downloading(title: "Algebra 2 Textbook.pdf"), .downloaded(pageCount: 300),
                          .matched(printed: 231, pdfIndex: 246, method: .pageLabels), .matched(printed: 232, pdfIndex: 247, method: .pageLabels)])
    guard case .found(let choice, let pages, let missing) = outcome else { Issue.record("\(outcome)"); return }
    #expect(choice == DocumentChoice(current: FixtureTabs.textbook, alternatives: [FixtureTabs.worksheet]))
    #expect(pages.map(\.printedLabel) == ["231", "232"] && pages.map(\.pdfIndex) == [246, 247] && missing.isEmpty)
    #expect(pages.allSatisfy { max($0.image.pixelWidth, $0.image.pixelHeight) == 1500 })
}

@Test func secondFindUsesCache() async throws {
    let fetcher = textbookFetcher()
    let finder = makeFinder(fetcher), rec = StepRecorder()
    let tab = try FixtureTabs.classroom()
    _ = try await find(finder, "page 231 of the textbook", tab: tab)
    _ = try await find(finder, "page 232 of the textbook", tab: tab, recorder: rec)
    #expect(await fetcher.requestedFileIDs == [FixtureTabs.textbook.fileId])
    #expect(rec.steps == [.matched(printed: 232, pdfIndex: 247, method: .pageLabels)])
}

@Test func noDocument() async throws {
    let fetcher = textbookFetcher()
    #expect(try await find(makeFinder(fetcher), "page 5", tab: nil) == .noDocument)
    #expect(await fetcher.requestedFileIDs.isEmpty)
}

@Test func reusesLastUsedDocument() async throws {
    let outcome = try await find(makeFinder(textbookFetcher()), "page 231", tab: nil, lastUsed: FixtureTabs.textbook)
    guard case .found(let choice, let pages, _) = outcome else { Issue.record("\(outcome)"); return }
    #expect(choice == DocumentChoice(current: FixtureTabs.textbook, alternatives: []))
    #expect(pages.map(\.pdfIndex) == [246])
}

@Test func pageBeyondBookIsNotFound() async throws {
    #expect(try await find(makeFinder(textbookFetcher()), "page 999 of the textbook", tab: try FixtureTabs.classroom())
            == .notFound(document: FixtureTabs.textbook, pages: [999]))
}

@Test func partialMatchReportsMissing() async throws {  // the book ends at 284
    let outcome = try await find(makeFinder(textbookFetcher()), "pages 284-286 of the textbook", tab: try FixtureTabs.classroom())
    guard case .found(_, let pages, let missing) = outcome else { Issue.record("\(outcome)"); return }
    #expect(pages.map(\.printedLabel) == ["284"] && missing == [285, 286])
}

@Test func nonPDFBytesFail() async throws {
    let fetcher = FakeDocumentFetcher(files: [FixtureTabs.textbook.fileId: (Data("<html>".utf8), "x")])
    #expect(try await find(makeFinder(fetcher), "page 5 of the textbook", tab: try FixtureTabs.classroom())
            == .failed(message: "“Algebra 2 Textbook.pdf” isn't a PDF."))
}

@Test(arguments: [
    (BridgeErrorCode.notConnected, "The browser extension isn't connected."),
    (.notPdf, "“Algebra 2 Textbook.pdf” isn't a PDF."),
    (.notFound, "Couldn't open “Algebra 2 Textbook.pdf” from Drive."),
    (.timeout, "Drive took too long to respond."),
    (.downloadBlocked, "Downloads are disabled for “Algebra 2 Textbook.pdf”. Open the PDF and ask again so I can scroll through it."),
    (.noViewer, "Something went wrong getting “Algebra 2 Textbook.pdf”."),
    (.internal, "Something went wrong getting “Algebra 2 Textbook.pdf”."),
])
func bridgeErrorsBecomeMessages(code: BridgeErrorCode, message: String) async throws {
    let viewer = idleViewer(), rec = StepRecorder()
    let finder = makeFinder(FakeDocumentFetcher(failure: BridgeError(code: code, message: "x")), viewer: viewer)
    let outcome = try await find(finder, "page 5 of the textbook", tab: try FixtureTabs.classroom(), recorder: rec)
    #expect(outcome == .failed(message: message))
    #expect(!rec.steps.contains(.downloadBlocked))
    #expect(await viewer.capturedIndices.isEmpty)
}
