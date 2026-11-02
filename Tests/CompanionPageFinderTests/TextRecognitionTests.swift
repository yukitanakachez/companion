@testable import CompanionPageFinder
import PDFKit
import Testing

@Test func readsHeaderNumber() throws {
    let page = try #require(PDFDocument(data: TestPDF.scanned(pageCount: 1, band: .header, printed: { _ in "231" }))?.page(at: 0))
    let image = try #require(PageRaster.image(of: page, scale: 2))
    #expect(image.width == 1224 && image.height == 1584)
    #expect(VisionNumberReader().numbers(inPageImage: image).contains(231))
}

@Test func readsFooterNumber() throws {
    let page = try #require(PDFDocument(data: TestPDF.scanned(pageCount: 1, band: .footer, printed: { _ in "47" }))?.page(at: 0))
    let image = try #require(PageRaster.image(of: page, scale: 2))
    let numbers = VisionNumberReader().numbers(inPageImage: image)
    #expect(numbers.contains(47))
    #expect(!numbers.contains(42))     // the body's "42" is outside the bands
}
