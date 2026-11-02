@testable import CompanionPageFinder
import PDFKit
import Testing

@Test(arguments: [("Chapter 5 · 231", [5, 231]), ("— 231 —", [231]), ("Page 12", [12]), ("9999", [9999]),
                  ("2-14", []), ("xii", []), ("3.5", []), ("1/2", []), ("0 and 10000", []), ("007", [])])
func standaloneIntegers(text: String, expected: [Int]) {
    #expect(PrintedNumbers.integers(in: text) == expected)
}

@Test func bandsAreTwelvePercent() {
    let b = PrintedNumbers.bands(of: CGRect(x: 0, y: 0, width: 612, height: 800))
    #expect(abs(b[0].minY - 704) < 0.001 && abs(b[0].height - 96) < 0.001 && b[1].minY == 0 && abs(b[1].height - 96) < 0.001)
}

@Test func footerNumberIgnoresBody() throws {
    let page = try #require(PDFDocument(data: TestPDF.text(pageCount: 1, band: .footer, printed: { _ in "231" }))?.page(at: 0))
    #expect(PrintedNumbers.textLayerNumbers(on: page) == [231])          // body "solve 3x + 42 = 0" is outside the bands
}

@Test func headerNumber() throws {
    let page = try #require(PDFDocument(data: TestPDF.text(pageCount: 1, band: .header, printed: { _ in "231" }))?.page(at: 0))
    #expect(PrintedNumbers.textLayerNumbers(on: page) == [231])
}

@Test func romanFooterYieldsNothing() throws {
    let page = try #require(PDFDocument(data: TestPDF.text(pageCount: 1, printed: { _ in "xii" }))?.page(at: 0))
    #expect(PrintedNumbers.textLayerNumbers(on: page) == [])
}

@Test func scannedPageHasNoTextLayer() throws {
    let page = try #require(PDFDocument(data: TestPDF.scanned(pageCount: 1, printed: { _ in "231" }))?.page(at: 0))
    #expect(PrintedNumbers.hasTextLayer(page) == false)
    #expect(PrintedNumbers.textLayerNumbers(on: page) == [])
}
