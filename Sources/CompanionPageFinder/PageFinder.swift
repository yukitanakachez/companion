import CompanionCore
import Foundation

public actor PageFinder {
    private let fetcher: any DocumentFetching
    private let viewer: any ViewerDriving
    private let cache: PDFSessionCache

    public init(fetcher: any DocumentFetching, viewer: any ViewerDriving, cache: PDFSessionCache) {
        self.fetcher = fetcher
        self.viewer = viewer
        self.cache = cache
    }

    public func find(_ reference: PageReference, question: String, tab: TabContext?,
                     lastUsed: DriveFileRef?, preferred: DriveFileRef?,
                     progress: @escaping @Sendable (PageFinderStep) -> Void) async -> PageFinderOutcome {
        guard let choice = DocumentResolver.resolve(tab: tab, question: question, lastUsed: lastUsed, preferred: preferred)
        else { return .noDocument }
        let title = choice.current.title
        do {
            let loaded = try await load(choice.current, progress: progress)
            return pages(reference, from: loaded, choice: choice, progress: progress)
        } catch let error as BridgeError {
            return .failed(message: Self.failureMessage(error, title: title))
        } catch PageFinderError.notAPDF {
            return .failed(message: Self.failureMessage(BridgeError(code: .notPdf, message: ""), title: title))
        } catch {
            return .failed(message: Self.failureMessage(BridgeError(code: .internal, message: ""), title: title))
        }
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
