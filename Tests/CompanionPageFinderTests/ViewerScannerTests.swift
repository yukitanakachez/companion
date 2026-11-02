@testable import CompanionPageFinder
import CompanionCore
import CompanionTestSupport
import Testing

private let book = TestPDF.book(frontMatter: 16)     // prints 72 on index 87

private func viewer(pageCount: Int = 300, at index: Int = 87) -> FakeViewerDriver {
    FakeViewerDriver(info: ViewerInfo(pageCount: pageCount, currentIndex: index), page: { encodedPage($0) })
}

@Test func findsTargetsUsingObservedOffset() async {
    let viewer = viewer()
    let rec = StepRecorder()
    let found = await ViewerScanner(driver: viewer, reader: IndexEncodedReader(printed: book)).scan(tabId: 34, targets: [231, 232], progress: rec.callback)
    #expect(found.map(\.printed) == [231, 232] && found.map(\.pageIndex) == [246, 247])
    #expect(await viewer.capturedIndices == [87, 246, 247])
    #expect(await viewer.restoredIndex == 87)
    #expect(rec.steps == [.scrollingViewer(target: 231), .matched(printed: 231, pdfIndex: 246, method: .viewer),
                          .scrollingViewer(target: 232), .matched(printed: 232, pdfIndex: 247, method: .viewer)])
}

@Test func adjustsAcrossUnnumberedPlates() async {
    let viewer = viewer(pageCount: 400)
    let reader = IndexEncodedReader(printed: TestPDF.book(frontMatter: 16, plates: [200, 201]))
    let found = await ViewerScanner(driver: viewer, reader: reader).scan(tabId: 34, targets: [300], progress: { _ in })
    #expect(found.map(\.pageIndex) == [317])
    #expect(await viewer.capturedIndices == [87, 315, 317])
}

@Test func startsFromUnnumberedPage() async {
    let viewer = viewer(at: 3)      // "iv"
    let found = await ViewerScanner(driver: viewer, reader: IndexEncodedReader(printed: book)).scan(tabId: 34, targets: [231], progress: { _ in })
    #expect(found.map(\.pageIndex) == [246])
    #expect(await viewer.capturedIndices == [3, 230, 246])
}

@Test func givesUpAfterTwelveCaptures() async {
    let viewer = viewer()
    let found = await ViewerScanner(driver: viewer, reader: IndexEncodedReader(printed: { _ in nil })).scan(tabId: 34, targets: [231, 232], progress: { _ in })
    #expect(found.isEmpty)
    #expect(await viewer.capturedIndices.count == 12)
    #expect(await viewer.restoredIndex == 87)
}

@Test func targetBeyondBookCostsNoCaptures() async {
    let viewer = viewer()
    let found = await ViewerScanner(driver: viewer, reader: IndexEncodedReader(printed: book)).scan(tabId: 34, targets: [999], progress: { _ in })
    #expect(found.isEmpty)
    #expect(await viewer.capturedIndices == [87])
}

@Test func restoresAfterCaptureFailure() async {
    let viewer = FailingViewerDriver(info: ViewerInfo(pageCount: 300, currentIndex: 87))
    let found = await ViewerScanner(driver: viewer, reader: IndexEncodedReader(printed: book)).scan(tabId: 34, targets: [231], progress: { _ in })
    #expect(found.isEmpty)
    #expect(await viewer.restoredIndex == 87)
}
