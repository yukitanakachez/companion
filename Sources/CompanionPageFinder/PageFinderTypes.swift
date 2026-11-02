import CompanionCore
import Foundation

public enum MappingMethod: String, Sendable, Equatable {
    case pageLabels, printedNumbers, textRecognition, viewer

    var label: String {
        switch self {
        case .pageLabels: "page labels"
        case .printedNumbers: "printed page numbers"
        case .textRecognition: "text recognition"
        case .viewer: "viewer"
        }
    }
}

public enum PageFinderStep: Sendable, Equatable {
    case downloading(title: String)
    case downloaded(pageCount: Int)
    case downloadBlocked
    /// `pdfIndex` is 0-based.
    case matched(printed: Int, pdfIndex: Int, method: MappingMethod)
    case scrollingViewer(target: Int)

    public var displayText: String {
        switch self {
        case .downloading(let title):
            "Downloading “\(title)”…"
        case .downloaded(let pageCount):
            "Got the PDF from Drive (\(pageCount) \(pageCount == 1 ? "page" : "pages"))"
        case .downloadBlocked:
            "Couldn't download — teacher disabled downloads. Scrolling the viewer instead…"
        case .matched(let printed, let pdfIndex, let method):
            "Book p.\(printed) → PDF p.\(pdfIndex + 1) (\(method.label))"
        case .scrollingViewer(let target):
            "Scrolling the viewer to find p.\(target)…"
        }
    }
}

public enum PageFinderOutcome: Sendable, Equatable {
    case found(choice: DocumentChoice, pages: [RenderedPage], missing: [Int])
    case noDocument
    case notFound(document: DriveFileRef, pages: [Int])
    case failed(message: String)
}
