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
    /// Text recognition runs only when no sampled page has a text layer, so text PDFs never pay for it.
    private lazy var isScanned = !textSampleIndices.contains { index in
        document.page(at: index).map(PrintedNumbers.hasTextLayer) ?? false
    }

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
        guard let textOffset else { return nil }
        return OffsetEstimator.locate(target, offset: textOffset, pageCount: document.pageCount, numbersAt: textNumbers)
            .map { PageMatch(printed: target, pdfIndex: $0, method: .printedNumbers) }
    }

    private func fromRecognition(_ target: Int) -> PageMatch? {
        guard isScanned, let ocrOffset else { return nil }
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
