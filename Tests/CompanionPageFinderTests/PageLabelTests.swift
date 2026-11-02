@testable import CompanionPageFinder
import PDFKit
import Testing

@Test func labelsAfterRomanFrontMatter() throws {
    let doc = try #require(PDFDocument(data: RawPDF.make(pageCount: 300, nums: TestPDF.textbookNums)))
    let table = try #require(PageLabelTable.make(for: doc))
    #expect(table.index(ofPrinted: 231) == 246 && table.index(ofPrinted: 232) == 247)
    #expect(table.index(ofPrinted: 1) == 16 && table.index(ofPrinted: 285) == nil)
}

@Test func noPageLabelsMeansNoTable() throws {
    let raw = try #require(PDFDocument(data: RawPDF.make(pageCount: 5, nums: nil)))
    #expect(PageLabelTable.make(for: raw) == nil)
    let text = try #require(PDFDocument(data: TestPDF.text(pageCount: 5, printed: { _ in nil })))
    #expect(PageLabelTable.make(for: text) == nil)
}

@Test func identityLabelsAreIgnored() throws {
    let doc = try #require(PDFDocument(data: RawPDF.make(pageCount: 30, nums: "[0 << /S /D >>]")))
    #expect(PageLabelTable.make(for: doc) == nil)
}

@Test func restartingLabelsUseFirstOccurrence() throws {
    let doc = try #require(PDFDocument(data: RawPDF.make(pageCount: 20, nums: "[0 << /S /D >> 10 << /S /D >>]")))
    let table = try #require(PageLabelTable.make(for: doc))
    #expect(table.index(ofPrinted: 5) == 4 && table.index(ofPrinted: 11) == nil)
}
