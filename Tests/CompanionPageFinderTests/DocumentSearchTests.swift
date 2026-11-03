@testable import CompanionPageFinder
import CompanionCore
import CompanionTestSupport
import Foundation
import Testing

// Several PDF attachments and no title match: try them in order until one holds the requested pages.

/// Fails or succeeds per file, which FakeDocumentFetcher can't express with a chosen error code.
private actor PerFileFetcher: DocumentFetching {
    private let files: [String: Result<Data, BridgeError>]
    private let onFetch: @Sendable () -> Void
    private(set) var requested: [String] = []

    init(_ files: [String: Result<Data, BridgeError>], onFetch: @escaping @Sendable () -> Void = {}) {
        self.files = files
        self.onFetch = onFetch
    }

    func fetchDrivePDF(fileId: String) async throws -> (data: Data, title: String) {
        requested.append(fileId)
        onFetch()
        guard let file = files[fileId] else { throw BridgeError(code: .notFound, message: "no \(fileId)") }
        return (try file.get(), fileId)
    }
}

private func pdf(_ name: String) -> DriveFileRef {
    DriveFileRef(fileId: "id-\(name)", title: "\(name).pdf", mimeType: "application/pdf")
}

private let quiz = pdf("Chap 3B test")
private let book = pdf("Rogawski Early Transcendentals")
private let other = pdf("Stewart Precalculus")
private let fourth = pdf("Handout")
private let fifth = pdf("Syllabus")

private let quizPDF = RawPDF.make(pageCount: 3, nums: nil, printed: { "\($0 + 1)" })
private let bookPDF = RawPDF.make(pageCount: 300, nums: TestPDF.textbookNums)

/// A PDF whose page labels run from `first` for `count` pages.
private func labelled(from first: Int, count: Int) -> Data {
    RawPDF.make(pageCount: count, nums: "[0 << /S /D /St \(first) >>]")
}

private func classroom(_ attachments: [DriveFileRef]) throws -> TabContext {
    var tab = try FixtureTabs.classroom()
    tab.classroom?.attachments = attachments
    return tab
}

private func makeFinder(_ fetcher: PerFileFetcher) -> (PageFinder, FakeViewerDriver) {
    let viewer = FakeViewerDriver(info: ViewerInfo(pageCount: 1, currentIndex: 0), page: { _ in Fixtures.samplePNG() })
    return (PageFinder(fetcher: fetcher, viewer: viewer, cache: PDFSessionCache(directory: temporaryDirectory())), viewer)
}

private func ask(_ finder: PageFinder, _ question: String, attachments: [DriveFileRef], preferred: DriveFileRef? = nil,
                 recorder: StepRecorder = StepRecorder()) async throws -> PageFinderOutcome {
    await finder.find(try #require(PageReferenceParser.parse(question)), question: question,
                      tab: try classroom(attachments), lastUsed: nil, preferred: preferred, progress: recorder.callback)
}

private let question = "go to page 232 and do problem #5"

@Test func noTitleMatchPicksTheDocumentWithThePage() async throws {
    let fetcher = PerFileFetcher([quiz.fileId: .success(quizPDF), book.fileId: .success(bookPDF), other.fileId: .success(bookPDF)])
    let (finder, _) = makeFinder(fetcher), rec = StepRecorder()
    let attachments = [quiz, book, other, fourth, fifth]
    let outcome = try await ask(finder, question, attachments: attachments, recorder: rec)
    guard case .found(let choice, let pages, let missing) = outcome else { Issue.record("\(outcome)"); return }
    #expect(choice == DocumentChoice(current: book, alternatives: [quiz, other, fourth, fifth]))
    #expect(pages.map(\.printedLabel) == ["232"] && pages.map(\.pdfIndex) == [247] && missing.isEmpty)
    #expect(rec.steps == [.downloading(title: quiz.title), .downloaded(pageCount: 3),
                          .downloading(title: book.title), .downloaded(pageCount: 300),
                          .matched(printed: 232, pdfIndex: 247, method: .pageLabels)])
    #expect(await fetcher.requested == [quiz.fileId, book.fileId])  // stops once one has everything
}

@Test(arguments: [
    Result<Data, BridgeError>.failure(BridgeError(code: .downloadBlocked, message: "x")),
    .failure(BridgeError(code: .timeout, message: "x")),
    .success(Data("<html>".utf8)),
])
func aFailedDownloadDoesNotEndTheSearch(first: Result<Data, BridgeError>) async throws {
    let fetcher = PerFileFetcher([quiz.fileId: first, book.fileId: .success(bookPDF)])
    let (finder, viewer) = makeFinder(fetcher), rec = StepRecorder()
    let outcome = try await ask(finder, question, attachments: [quiz, book], recorder: rec)
    guard case .found(let choice, let pages, _) = outcome else { Issue.record("\(outcome)"); return }
    #expect(choice == DocumentChoice(current: book, alternatives: [quiz]))
    #expect(pages.map(\.pdfIndex) == [247])
    #expect(!rec.steps.contains(.downloadBlocked))  // the viewer fallback rules are unchanged
    #expect(await viewer.capturedIndices.isEmpty)
}

@Test func titleMatchDoesNotFallThrough() async throws {
    let fetcher = PerFileFetcher([quiz.fileId: .success(quizPDF), book.fileId: .success(bookPDF)])
    let (finder, _) = makeFinder(fetcher)
    #expect(try await ask(finder, "the test, page 232", attachments: [book, quiz])
            == .notFound(document: quiz, pages: [232]))
    #expect(await fetcher.requested == [quiz.fileId])
}

@Test func titleMatchFindsItsOwnPage() async throws {
    let fetcher = PerFileFetcher([quiz.fileId: .success(labelled(from: 2, count: 2)), book.fileId: .success(bookPDF)])
    let (finder, _) = makeFinder(fetcher)
    let outcome = try await ask(finder, "the test, page 2", attachments: [book, quiz])
    guard case .found(let choice, let pages, _) = outcome else { Issue.record("\(outcome)"); return }
    #expect(choice.current == quiz && pages.map(\.printedLabel) == ["2"])
    #expect(await fetcher.requested == [quiz.fileId])
}

@Test func titleMatchThatFailsToDownloadDoesNotFallThrough() async throws {
    let fetcher = PerFileFetcher([quiz.fileId: .failure(BridgeError(code: .notFound, message: "x")), book.fileId: .success(bookPDF)])
    let (finder, _) = makeFinder(fetcher)
    #expect(try await ask(finder, "the test, page 232", attachments: [book, quiz])
            == .failed(message: "Couldn't open “\(quiz.title)” from Drive."))
    #expect(await fetcher.requested == [quiz.fileId])
}

@Test func preferredDoesNotFallThrough() async throws {
    let fetcher = PerFileFetcher([quiz.fileId: .success(quizPDF), book.fileId: .success(bookPDF)])
    let (finder, _) = makeFinder(fetcher)
    #expect(try await ask(finder, question, attachments: [book, quiz], preferred: quiz)
            == .notFound(document: quiz, pages: [232]))
    #expect(await fetcher.requested == [quiz.fileId])
}

@Test func lastUsedDoesNotFallThrough() async throws {
    let fetcher = PerFileFetcher([quiz.fileId: .success(quizPDF), book.fileId: .success(bookPDF)])
    let (finder, _) = makeFinder(fetcher)
    let outcome = await finder.find(try #require(PageReferenceParser.parse(question)), question: question,
                                    tab: nil, lastUsed: quiz, preferred: nil, progress: { _ in })
    #expect(outcome == .notFound(document: quiz, pages: [232]))
    #expect(await fetcher.requested == [quiz.fileId])
}

@Test func nothingFoundReportsTheFirstDocumentThatDownloaded() async throws {
    let fetcher = PerFileFetcher([quiz.fileId: .failure(BridgeError(code: .timeout, message: "x")),
                                  book.fileId: .success(quizPDF), other.fileId: .success(quizPDF)])
    let (finder, _) = makeFinder(fetcher)
    #expect(try await ask(finder, question, attachments: [quiz, book, other])
            == .notFound(document: book, pages: [232]))
    #expect(await fetcher.requested == [quiz.fileId, book.fileId, other.fileId])
}

@Test func allFailingReportsTheFirstDocumentsFailure() async throws {
    let fetcher = PerFileFetcher([quiz.fileId: .failure(BridgeError(code: .downloadBlocked, message: "x")),
                                  book.fileId: .failure(BridgeError(code: .timeout, message: "x"))])
    let (finder, _) = makeFinder(fetcher)
    #expect(try await ask(finder, question, attachments: [quiz, book])
            == .failed(message: "Downloads are disabled for “\(quiz.title)”. Open the PDF and ask again so I can scroll through it."))
}

@Test func theSearchStopsAtFourDocuments() async throws {
    let attachments = [quiz, book, other, fourth, fifth]
    var files = Dictionary(uniqueKeysWithValues: attachments.map { ($0.fileId, Result<Data, BridgeError>.success(quizPDF)) })
    files[fifth.fileId] = .success(bookPDF)
    let fetcher = PerFileFetcher(files)
    let (finder, _) = makeFinder(fetcher)
    #expect(try await ask(finder, question, attachments: attachments) == .notFound(document: quiz, pages: [232]))
    #expect(await fetcher.requested == [quiz.fileId, book.fileId, other.fileId, fourth.fileId])
}

@Test func aSecondQuestionDownloadsNothingNew() async throws {
    let fetcher = PerFileFetcher([quiz.fileId: .success(quizPDF), book.fileId: .success(bookPDF)])
    let (finder, _) = makeFinder(fetcher), rec = StepRecorder()
    _ = try await ask(finder, question, attachments: [quiz, book])
    let outcome = try await ask(finder, "go to page 231", attachments: [quiz, book], recorder: rec)
    guard case .found(let choice, _, _) = outcome else { Issue.record("\(outcome)"); return }
    #expect(choice.current == book)
    #expect(await fetcher.requested == [quiz.fileId, book.fileId])
    #expect(rec.steps == [.matched(printed: 231, pdfIndex: 246, method: .pageLabels)])
}

@Test func noDocumentHasEverythingSoTheMostMatchesWins() async throws {
    let fetcher = PerFileFetcher([quiz.fileId: .success(labelled(from: 231, count: 1)),
                                  book.fileId: .success(labelled(from: 232, count: 2)),
                                  other.fileId: .success(labelled(from: 233, count: 2))])
    let (finder, _) = makeFinder(fetcher)
    let outcome = try await ask(finder, "pages 231-234", attachments: [quiz, book, other])
    guard case .found(let choice, let pages, let missing) = outcome else { Issue.record("\(outcome)"); return }
    #expect(choice == DocumentChoice(current: book, alternatives: [quiz, other]))  // the tie with `other` goes to the earlier
    #expect(pages.map(\.printedLabel) == ["232", "233"] && missing == [231, 234])
}

@Test func aPartialMatchKeepsLookingForACompleteOne() async throws {
    let fetcher = PerFileFetcher([quiz.fileId: .success(labelled(from: 231, count: 1)), book.fileId: .success(bookPDF),
                                  other.fileId: .success(bookPDF)])
    let (finder, _) = makeFinder(fetcher)
    let outcome = try await ask(finder, "pages 231-232", attachments: [quiz, book, other])
    guard case .found(let choice, let pages, let missing) = outcome else { Issue.record("\(outcome)"); return }
    #expect(choice.current == book && pages.count == 2 && missing.isEmpty)
    #expect(await fetcher.requested == [quiz.fileId, book.fileId])
}

@Test func cancellingStopsTheSearch() async throws {
    let fetcher = PerFileFetcher([quiz.fileId: .success(quizPDF), book.fileId: .success(bookPDF)],
                                 onFetch: { withUnsafeCurrentTask { $0?.cancel() } })
    let (finder, _) = makeFinder(fetcher)
    let attachments = [quiz, book]
    let reference = try #require(PageReferenceParser.parse(question))
    let tab = try classroom(attachments)
    let task = Task { await finder.find(reference, question: question, tab: tab, lastUsed: nil, preferred: nil, progress: { _ in }) }
    _ = await task.value
    #expect(await fetcher.requested == [quiz.fileId])
}
