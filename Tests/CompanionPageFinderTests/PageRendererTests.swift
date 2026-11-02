@testable import CompanionPageFinder
import Foundation
import PDFKit
import Testing

@Test func portraitPage() throws {
    let page = try #require(PDFDocument(data: TestPDF.text(pageCount: 1, printed: { _ in "231" }))?.page(at: 0))
    let r = try #require(PageRenderer.render(page, pdfIndex: 246, printed: 231))
    #expect(r.printedLabel == "231" && r.pdfIndex == 246)
    #expect(r.image.pixelWidth == 1159 && r.image.pixelHeight == 1500)
    #expect(r.image.png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) && r.text.contains("Exercise"))
}

@Test func landscapePage() throws {
    let data = TestPDF.text(pageCount: 1, printed: { _ in "231" }, size: CGSize(width: 792, height: 612))
    let page = try #require(PDFDocument(data: data)?.page(at: 0))
    let r = try #require(PageRenderer.render(page, pdfIndex: 0, printed: 231))
    #expect(r.image.pixelWidth == 1500 && r.image.pixelHeight == 1159)
}

@Test func textIsCapped() throws {
    let data = TestPDF.text(pageCount: 1, printed: { _ in nil },
                            body: { _ in String(repeating: "abcdefghi ", count: 1_100) }, bodyFontSize: 3)
    let page = try #require(PDFDocument(data: data)?.page(at: 0))
    let r = try #require(PageRenderer.render(page, pdfIndex: 0, printed: 1))
    #expect(r.text.count == 8_000)
}
