@testable import CompanionPageFinder
import Foundation
import PDFKit
import Testing

@Test func labelsWin() throws {
    let mapper = PageMapper(document: try #require(PDFDocument(data: RawPDF.make(pageCount: 300, nums: TestPDF.textbookNums))))
    #expect(mapper.locate([231, 232]) == [231: PageMatch(printed: 231, pdfIndex: 246, method: .pageLabels),
                                          232: PageMatch(printed: 232, pdfIndex: 247, method: .pageLabels)])
}

@Test func identityLabelsFallBackToPrintedNumbers() throws {
    let data = RawPDF.make(pageCount: 300, nums: "[0 << /S /D >>]", printed: TestPDF.book(frontMatter: 16))
    let mapper = PageMapper(document: try #require(PDFDocument(data: data)))
    #expect(mapper.locate([231]) == [231: PageMatch(printed: 231, pdfIndex: 246, method: .printedNumbers)])
}

@Test func printedNumbersWithDrift() throws {
    let data = TestPDF.text(pageCount: 400, printed: TestPDF.book(frontMatter: 16, plates: [200, 201]))
    let mapper = PageMapper(document: try #require(PDFDocument(data: data)))
    #expect(mapper.locate([150, 300]) == [150: PageMatch(printed: 150, pdfIndex: 165, method: .printedNumbers),
                                          300: PageMatch(printed: 300, pdfIndex: 317, method: .printedNumbers)])
}

@Test func scannedBookUsesTextRecognition() throws {
    let doc = try #require(PDFDocument(data: TestPDF.scanned(pageCount: 40, band: .footer, printed: TestPDF.book(frontMatter: 4))))
    #expect(PageMapper(document: doc).locate([20]) == [20: PageMatch(printed: 20, pdfIndex: 23, method: .textRecognition)])
}

@Test func textPDFNeverRunsOCR() throws {
    let reader = CountingReader()
    let data = TestPDF.text(pageCount: 60, printed: TestPDF.book(frontMatter: 16))
    let mapper = PageMapper(document: try #require(PDFDocument(data: data)), reader: reader)
    #expect(mapper.locate([999]).isEmpty)      // beyond the book
    #expect(reader.calls == 0)
}

@Test func fiveHundredPagesUnderOneSecond() throws {
    let reader = CountingReader()
    let mapper = PageMapper(document: try #require(PDFDocument(data: TestPDF.text(pageCount: 500, printed: TestPDF.book(frontMatter: 16)))), reader: reader)
    var result: [Int: PageMatch] = [:]
    let elapsed = ContinuousClock().measure { result = mapper.locate([231, 232]) }
    #expect(elapsed < .seconds(1))
    #expect(result[231]?.pdfIndex == 246 && result[232]?.pdfIndex == 247 && reader.calls == 0)
}

/// Spec §8: real PDFs stay out of the repo. `<dir>/expectations.json` = [{"file", "printed", "pdfIndex"}].
@Test(.enabled(if: ProcessInfo.processInfo.environment["COMPANION_REAL_PDF_DIR"] != nil))
func realTextbooks() throws {
    struct Expectation: Decodable { let file: String; let printed: Int; let pdfIndex: Int }
    let dir = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["COMPANION_REAL_PDF_DIR"]))
    let expectations = try JSONDecoder().decode([Expectation].self,
                                                from: Data(contentsOf: dir.appendingPathComponent("expectations.json")))
    for expectation in expectations {
        let doc = try #require(PDFDocument(url: dir.appendingPathComponent(expectation.file)))
        #expect(PageMapper(document: doc).locate([expectation.printed])[expectation.printed]?.pdfIndex == expectation.pdfIndex,
                "\(expectation.file) p.\(expectation.printed)")
    }
}
