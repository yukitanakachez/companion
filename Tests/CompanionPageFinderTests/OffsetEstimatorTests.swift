@testable import CompanionPageFinder
import PDFKit
import Testing

@Test func sampleIndicesSpreadEvenly() {
    let s = OffsetEstimator.sampleIndices(pageCount: 500, maxSamples: 15)
    #expect(s.count == 15 && s.first == 0 && s.last == 499 && s == s.sorted())
    #expect(OffsetEstimator.sampleIndices(pageCount: 5, maxSamples: 15) == [0, 1, 2, 3, 4])
}

@Test func estimateIgnoresChapterNumbers() {
    #expect(OffsetEstimator.estimate([20, 40, 60, 80].map { (pdfIndex: $0, numbers: [3, $0 - 15]) }) == -15)
}

@Test func estimateNeedsAgreement() {
    #expect(OffsetEstimator.estimate((0..<15).map { (pdfIndex: $0 * 10, numbers: [$0 * 20 + 1]) }) == nil)  // 2-up scan
    #expect(OffsetEstimator.estimate([]) == nil)
    #expect(OffsetEstimator.estimate([(pdfIndex: 0, numbers: [1]), (pdfIndex: 1, numbers: [2])]) == 1)
}

@Test func locateRequiresTheNumberOnThePage() {
    var visited: [Int] = []
    let found = OffsetEstimator.locate(231, offset: -15, pageCount: 300) { visited.append($0); return $0 == 248 ? [231] : [] }
    #expect(found == 248 && visited == [246, 247, 245, 248])
    #expect(OffsetEstimator.locate(999, offset: -15, pageCount: 300) { _ in Issue.record("out of range"); return [] } == nil)
    #expect(OffsetEstimator.locate(5, offset: -15, pageCount: 300) { _ in [] } == nil)
}

@Test func driftAcrossPlates() throws {   // PDF runs 15 ahead, then 17 ahead after two unnumbered plates at 200–201
    let doc = try #require(PDFDocument(data: TestPDF.text(pageCount: 400, printed: TestPDF.book(frontMatter: 16, plates: [200, 201]))))
    let numbers = { (i: Int) in PrintedNumbers.textLayerNumbers(on: doc.page(at: i)!) }
    let samples = OffsetEstimator.sampleIndices(pageCount: 400, maxSamples: 15).map { (pdfIndex: $0, numbers: numbers($0)) }
    let offset = try #require(OffsetEstimator.estimate(samples))
    #expect([-15, -17].contains(offset))
    #expect(OffsetEstimator.locate(150, offset: offset, pageCount: 400, numbersAt: numbers) == 165)
    #expect(OffsetEstimator.locate(300, offset: offset, pageCount: 400, numbersAt: numbers) == 317)
}

@Test func noPrintedNumbersMeansNoOffset() throws {
    let doc = try #require(PDFDocument(data: TestPDF.text(pageCount: 30, printed: { _ in nil })))
    let samples = OffsetEstimator.sampleIndices(pageCount: 30, maxSamples: 15)
        .map { (pdfIndex: $0, numbers: PrintedNumbers.textLayerNumbers(on: doc.page(at: $0)!)) }
    #expect(OffsetEstimator.estimate(samples) == nil)
}
