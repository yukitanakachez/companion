import CoreGraphics
import PDFKit

struct PageMatch: Sendable, Equatable {
    var printed: Int
    var pdfIndex: Int
    var method: MappingMethod
}

/// Maps printed page numbers to PDF indices: page labels → printed numbers → text recognition.
/// Each stage handles only the targets the stage before it left unmatched.
final class PageMapper {
    static let textSamples = 15, ocrSamples = 9, ocrScale: CGFloat = 2

    private let document: PDFDocument
    private let reader: any PrintedNumberReading

    private lazy var labels = PageLabelTable.make(for: document)
    private lazy var textSampleIndices = OffsetEstimator.sampleIndices(pageCount: document.pageCount,
                                                                      maxSamples: Self.textSamples)
    private lazy var textOffset = estimateOffset(samples: textSampleIndices, numbers: textNumbers)
    private lazy var ocrOffset = estimateOffset(
        samples: OffsetEstimator.sampleIndices(pageCount: document.pageCount, maxSamples: Self.ocrSamples),
        numbers: ocrNumbers)
    /// Text recognition runs only when most sampled pages have no text layer, so text PDFs never pay for it,
    /// while a text cover merged onto a scan doesn't switch it off.
    private lazy var isScanned = {
        let withText = textSampleIndices.filter { index in
            document.page(at: index).map(PrintedNumbers.hasTextLayer) ?? false
        }
        return withText.count * 2 < textSampleIndices.count
    }()

    private var textMemo: [Int: [Int]] = [:]
    private var ocrMemo: [Int: [Int]] = [:]
    private var results: [Int: PageMatch?] = [:]

    init(document: PDFDocument, reader: any PrintedNumberReading = VisionNumberReader()) {
        self.document = document
        self.reader = reader
    }

    /// Unmatched targets are absent. Memoizes the label table, per-page numbers, offsets and per-target results.
    func locate(_ targets: [Int]) -> [Int: PageMatch] {
        var matches: [Int: PageMatch] = [:]
        for target in targets {
            if let match = result(for: target) { matches[target] = match }
        }
        return matches
    }

    private func result(for target: Int) -> PageMatch? {
        if let memo = results[target] { return memo }
        let match = fromLabels(target) ?? fromText(target) ?? fromRecognition(target)
        results[target] = .some(match)
        return match
    }

    private func fromLabels(_ target: Int) -> PageMatch? {
        labels?.index(ofPrinted: target).map { PageMatch(printed: target, pdfIndex: $0, method: .pageLabels) }
    }

    private func fromText(_ target: Int) -> PageMatch? {
        let pageCount = document.pageCount
        if let textOffset, let index = OffsetEstimator.locate(target, offset: textOffset, pageCount: pageCount,
                                                              numbersAt: textNumbers) {
            return PageMatch(printed: target, pdfIndex: index, method: .printedNumbers)
        }
        for offset in sampledOffsets(nearest: target) {
            if let index = OffsetEstimator.locate(target, offset: offset, pageCount: pageCount, numbersAt: textNumbers),
               isPageNumber(target, at: index) {
                return PageMatch(printed: target, pdfIndex: index, method: .printedNumbers)
            }
        }
        return nil
    }

    /// Plate sections shift the numbering part-way through a book, so one offset can't reach every page. These are
    /// the offsets seen at each sample, nearest the target first. Empty unless most samples are numbered, so a stray
    /// number in an unnumbered book gets no say.
    private func sampledOffsets(nearest target: Int) -> [Int] {
        let numbered = textSampleIndices.filter { !textNumbers(at: $0).isEmpty }
        guard numbered.count * 2 >= textSampleIndices.count else { return [] }
        let pairs = numbered.flatMap { index in textNumbers(at: index).map { (number: $0, offset: $0 - index) } }
        var seen = Set<Int>()
        return pairs.sorted { abs($0.number - target) < abs($1.number - target) }
            .map(\.offset)
            .filter { seen.insert($0).inserted }
    }

    /// A hit from a sampled offset isn't backed by a vote, so a page with several numbers must also continue the
    /// sequence on a neighbour; otherwise a chapter number could pass for the page. An unnumbered hit was already
    /// proved by its neighbours.
    private func isPageNumber(_ target: Int, at index: Int) -> Bool {
        guard textNumbers(at: index).count > 1 else { return true }
        return (index + 1 < document.pageCount && textNumbers(at: index + 1).contains(target + 1))
            || (index > 0 && textNumbers(at: index - 1).contains(target - 1))
    }

    private func fromRecognition(_ target: Int) -> PageMatch? {
        guard textOffset == nil, isScanned, let ocrOffset else { return nil }
        return OffsetEstimator.locate(target, offset: ocrOffset, pageCount: document.pageCount, numbersAt: ocrNumbers)
            .map { PageMatch(printed: target, pdfIndex: $0, method: .textRecognition) }
    }

    private func estimateOffset(samples: [Int], numbers: (Int) -> [Int]) -> Int? {
        OffsetEstimator.estimate(samples.map { (pdfIndex: $0, numbers: numbers($0)) })
    }

    private func textNumbers(at index: Int) -> [Int] {
        if let memo = textMemo[index] { return memo }
        let numbers = document.page(at: index).map(PrintedNumbers.textLayerNumbers) ?? []
        textMemo[index] = numbers
        return numbers
    }

    private func ocrNumbers(at index: Int) -> [Int] {
        if let memo = ocrMemo[index] { return memo }
        let numbers = document.page(at: index)
            .flatMap { PageRaster.image(of: $0, scale: Self.ocrScale) }
            .map(reader.numbers(inPageImage:)) ?? []
        ocrMemo[index] = numbers
        return numbers
    }
}
