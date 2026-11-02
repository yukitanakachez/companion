import PDFKit
import Testing

@Test func textPDFHasTextLayer() throws {
    let doc = try #require(PDFDocument(data: TestPDF.text(pageCount: 3, printed: { "\($0 + 10)" })))
    #expect(doc.pageCount == 3)
    let text = try #require(doc.page(at: 1)?.string)
    #expect(text.contains("11") && text.contains("Quadratic Functions") && text.contains("Exercise"))
}

@Test func scannedPDFHasNoTextLayer() throws {
    let doc = try #require(PDFDocument(data: TestPDF.scanned(pageCount: 2, printed: { "\($0 + 1)" })))
    #expect(doc.pageCount == 2)
    let text = doc.page(at: 0)?.string ?? ""
    #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}

@Test func rawPDFCarriesPageLabels() throws {
    let doc = try #require(PDFDocument(data: RawPDF.make(pageCount: 20, nums: TestPDF.textbookNums, printed: { "\($0 + 1)" })))
    #expect(doc.pageCount == 20 && doc.page(at: 0)?.label == "i" && doc.page(at: 15)?.label == "xvi" && doc.page(at: 16)?.label == "1")
    #expect(doc.page(at: 4)?.string?.contains("5") == true)
    #expect(!String(decoding: RawPDF.make(pageCount: 2, nums: nil), as: UTF8.self).contains("/PageLabels"))
}

@Test func bookNumbering() {
    let p = TestPDF.book(frontMatter: 16, plates: [200, 201])
    #expect(p(0) == "i" && p(15) == "xvi" && p(16) == "1" && p(165) == "150" && p(200) == nil && p(202) == "185" && p(317) == "300")
}
