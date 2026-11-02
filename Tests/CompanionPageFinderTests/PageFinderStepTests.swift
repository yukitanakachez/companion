@testable import CompanionPageFinder
import Testing

@Test func displayTextCopy() {
    #expect(PageFinderStep.downloading(title: "Algebra 2 Textbook.pdf").displayText == "Downloading “Algebra 2 Textbook.pdf”…")
    #expect(PageFinderStep.downloaded(pageCount: 412).displayText == "Got the PDF from Drive (412 pages)")
    #expect(PageFinderStep.downloaded(pageCount: 1).displayText == "Got the PDF from Drive (1 page)")
    #expect(PageFinderStep.downloadBlocked.displayText == "Couldn't download — teacher disabled downloads. Scrolling the viewer instead…")
    #expect(PageFinderStep.matched(printed: 231, pdfIndex: 246, method: .pageLabels).displayText == "Book p.231 → PDF p.247 (page labels)")
    #expect(PageFinderStep.matched(printed: 231, pdfIndex: 246, method: .printedNumbers).displayText == "Book p.231 → PDF p.247 (printed page numbers)")
    #expect(PageFinderStep.matched(printed: 5, pdfIndex: 0, method: .textRecognition).displayText == "Book p.5 → PDF p.1 (text recognition)")
    #expect(PageFinderStep.matched(printed: 5, pdfIndex: 9, method: .viewer).displayText == "Book p.5 → PDF p.10 (viewer)")
    #expect(PageFinderStep.scrollingViewer(target: 231).displayText == "Scrolling the viewer to find p.231…")
}
