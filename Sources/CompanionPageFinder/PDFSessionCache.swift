import Foundation
import PDFKit

enum PageFinderError: Error, Equatable {
    case notAPDF
}

/// Holds non-Sendable PDFKit state; only touched synchronously on the PageFinder actor.
final class LoadedPDF: @unchecked Sendable {
    let document: PDFDocument
    let mapper: PageMapper

    init(document: PDFDocument) {
        self.document = document
        mapper = PageMapper(document: document)
    }
}

/// Downloaded PDFs and their page maps, by Drive file id, for the session. Cleared on quit.
public actor PDFSessionCache {
    private let directory: URL
    private var memo: [String: LoadedPDF] = [:]

    public init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Companion-PDFCache")) {
        self.directory = directory
    }

    /// Deletes the directory and forgets every memo.
    public func clearAll() {
        memo.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    /// `<directory>/<fileId>.pdf`, with characters outside [A-Za-z0-9_-] replaced by "_".
    func fileURL(for fileId: String) -> URL {
        let safe = String(fileId.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
        return directory.appendingPathComponent("\(safe).pdf")
    }

    /// The memo, else the file on disk, else nil.
    func cached(fileId: String) -> LoadedPDF? {
        if let loaded = memo[fileId] { return loaded }
        guard let document = PDFDocument(url: fileURL(for: fileId)) else { return nil }
        let loaded = LoadedPDF(document: document)
        memo[fileId] = loaded
        return loaded
    }

    /// Creates the directory, writes, loads; non-PDF data removes the file and throws `.notAPDF`.
    func store(_ data: Data, fileId: String) throws -> LoadedPDF {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: fileId)
        try data.write(to: url)
        guard let document = PDFDocument(url: url) else {
            try? FileManager.default.removeItem(at: url)
            throw PageFinderError.notAPDF
        }
        let loaded = LoadedPDF(document: document)
        memo[fileId] = loaded
        return loaded
    }
}
