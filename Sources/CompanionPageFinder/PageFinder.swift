import CompanionCore
import Foundation

public actor PageFinder {
    private static let maxDocumentsPerSearch = 4

    private let fetcher: any DocumentFetching
    private let viewer: any ViewerDriving
    private let cache: PDFSessionCache

    private let viewerReader: any PrintedNumberReading

    public init(fetcher: any DocumentFetching, viewer: any ViewerDriving, cache: PDFSessionCache) {
        self.init(fetcher: fetcher, viewer: viewer, cache: cache, viewerReader: VisionNumberReader())
    }

    init(fetcher: any DocumentFetching, viewer: any ViewerDriving, cache: PDFSessionCache,
         viewerReader: any PrintedNumberReading) {
        self.fetcher = fetcher
        self.viewer = viewer
        self.cache = cache
        self.viewerReader = viewerReader
    }

    public func find(_ reference: PageReference, question: String, tab: TabContext?,
                     lastUsed: DriveFileRef?, preferred: DriveFileRef?,
                     progress: @escaping @Sendable (PageFinderStep) -> Void) async -> PageFinderOutcome {
        let candidates = DocumentResolver.searchCandidates(tab: tab, question: question, preferred: preferred)
        if !candidates.isEmpty { return await search(reference, in: candidates, progress: progress) }
        guard let choice = DocumentResolver.resolve(tab: tab, question: question, lastUsed: lastUsed, preferred: preferred)
        else { return .noDocument }
        let title = choice.current.title
        do {
            let loaded = try await load(choice.current, progress: progress)
            return pages(reference, from: loaded, choice: choice, progress: progress)
        } catch let error as BridgeError {
            // The viewer fallback never scrolls a different document than the one being answered about.
            if error.code == .downloadBlocked, let tab, tab.drive?.file.fileId == choice.current.fileId {
                return await scanViewer(reference, tabId: tab.tabId, choice: choice, progress: progress)
            }
            return Self.failure(error, title: title)
        } catch {
            return Self.failure(error, title: title)
        }
    }

    /// Tries `documents` in order until one holds every requested page. Failing to get one document doesn't end the
    /// search. Otherwise: the most pages matched (ties to the earlier), then the first document that lacked them,
    /// then the first failure.
    private func search(_ reference: PageReference, in documents: [DriveFileRef],
                        progress: @Sendable (PageFinderStep) -> Void) async -> PageFinderOutcome {
        var best: (outcome: PageFinderOutcome, matched: Int)?
        var firstNotFound: PageFinderOutcome?
        var firstFailure: PageFinderOutcome?
        for file in documents.prefix(Self.maxDocumentsPerSearch) {
            let choice = DocumentChoice(current: file, alternatives: documents.filter { $0.fileId != file.fileId })
            do {
                let loaded = try await load(file, progress: progress)
                let outcome = pages(reference, from: loaded, choice: choice, progress: progress)
                if case .found(_, _, let missing) = outcome {
                    if missing.isEmpty { return outcome }
                    let matched = reference.pages.count - missing.count
                    if matched > (best?.matched ?? 0) { best = (outcome, matched) }
                } else if firstNotFound == nil {
                    firstNotFound = outcome
                }
            } catch {
                if firstFailure == nil { firstFailure = Self.failure(error, title: file.title) }
            }
            if Task.isCancelled { break }
        }
        return best?.outcome ?? firstNotFound ?? firstFailure ?? .noDocument
    }

    private static func failure(_ error: any Error, title: String) -> PageFinderOutcome {
        let bridgeError = switch error {
        case let error as BridgeError: error
        case PageFinderError.notAPDF: BridgeError(code: .notPdf, message: "")
        default: BridgeError(code: .internal, message: "")
        }
        return .failed(message: failureMessage(bridgeError, title: title))
    }

    static func failureMessage(_ error: BridgeError, title: String) -> String {
        switch error.code {
        case .notConnected: "The browser extension isn't connected."
        case .notPdf: "“\(title)” isn't a PDF."
        case .notFound: "Couldn't open “\(title)” from Drive."
        case .timeout: "Drive took too long to respond."
        case .downloadBlocked: "Downloads are disabled for “\(title)”. Open the PDF and ask again so I can scroll through it."
        default: "Something went wrong getting “\(title)”."
        }
    }

    private func load(_ file: DriveFileRef, progress: @Sendable (PageFinderStep) -> Void) async throws -> LoadedPDF {
        if let cached = await cache.cached(fileId: file.fileId) { return cached }
        progress(.downloading(title: file.title))
        let fetched = try await fetcher.fetchDrivePDF(fileId: file.fileId)
        let loaded = try await cache.store(fetched.data, fileId: file.fileId)
        progress(.downloaded(pageCount: loaded.document.pageCount))
        return loaded
    }

    private func scanViewer(_ reference: PageReference, tabId: Int, choice: DocumentChoice,
                            progress: @Sendable (PageFinderStep) -> Void) async -> PageFinderOutcome {
        progress(.downloadBlocked)
        let scanner = ViewerScanner(driver: viewer, reader: viewerReader)
        let captures = await scanner.scan(tabId: tabId, targets: reference.pages, progress: progress)
        guard !captures.isEmpty else { return .notFound(document: choice.current, pages: reference.pages) }
        let pages = captures.map {
            RenderedPage(printedLabel: "\($0.printed)", pdfIndex: $0.pageIndex, image: $0.image, text: "")
        }
        let foundPages = Set(captures.map(\.printed))
        return .found(choice: choice, pages: pages, missing: reference.pages.filter { !foundPages.contains($0) })
    }

    private func pages(_ reference: PageReference, from loaded: LoadedPDF, choice: DocumentChoice,
                       progress: @Sendable (PageFinderStep) -> Void) -> PageFinderOutcome {
        let matches = loaded.mapper.locate(reference.pages)
        var rendered: [RenderedPage] = []
        var renderedIndices = Set<Int>()
        var missing: [Int] = []
        for target in reference.pages {
            guard let match = matches[target] else {
                missing.append(target)
                continue
            }
            progress(.matched(printed: match.printed, pdfIndex: match.pdfIndex, method: match.method))
            guard renderedIndices.insert(match.pdfIndex).inserted else { continue }
            if let page = loaded.document.page(at: match.pdfIndex),
               let image = PageRenderer.render(page, pdfIndex: match.pdfIndex, printed: match.printed) {
                rendered.append(image)
            } else {
                missing.append(target)
            }
        }
        guard !rendered.isEmpty else { return .notFound(document: choice.current, pages: reference.pages) }
        return .found(choice: choice, pages: rendered, missing: missing)
    }
}
