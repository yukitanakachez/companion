@testable import CompanionPageFinder
import CompanionCore
import CompanionTestSupport
import PDFKit
import Testing

// Inputs pinned by the whole-branch review: real textbooks have running heads, unnumbered chapter openers,
// plate sections and rotated pages, which the plan's bare-number fixtures don't exercise.

private struct NumbersReader: PrintedNumberReading {
    let numbers: @Sendable (Int) -> [Int]
    func numbers(inPageImage image: CGImage) -> [Int] { numbers(image.width - 1) }
}

private func viewer(pageCount: Int = 300, at index: Int = 87) -> FakeViewerDriver {
    FakeViewerDriver(info: ViewerInfo(pageCount: pageCount, currentIndex: index), page: { encodedPage($0) })
}

// I1
@Test(arguments: ["if p1 = 5 atm and p2 = 3 atm find V2", "P1 = 100 kPa", "p2 + 3p + 2", "P4 + 5 O2", "what is p 2",
                  "p5.js", "p100 = 5"])
func plainMathIsNotAPageReference(_ question: String) {
    #expect(PageReferenceParser.parse(question) == nil)
}

@Test func barePWithAPageSizedNumberStillParses() {
    #expect(PageReferenceParser.parse("p 231")?.pages == [231])
    #expect(PageReferenceParser.parse("p. 5")?.pages == [5])
}

// I2
@Test(arguments: ["[0 << /P (Cover) >> 1 << /S /D /St 2 >>]", "[0 << /S /r >> 4 << /S /D /St 5 >>]"])
func partlyIdentityLabelsDontBeatPrintedNumbers(nums: String) throws {
    let data = RawPDF.make(pageCount: 100, nums: nums, printed: TestPDF.book(frontMatter: 16))
    let doc = try #require(PDFDocument(data: data))
    #expect(PageMapper(document: doc).locate([50]) == [50: PageMatch(printed: 50, pdfIndex: 65, method: .printedNumbers)])
}

// I3
@Test func viewerDoesNotTakeAChapterNumberForThePage() async {
    let viewer = viewer()
    let reader = NumbersReader { [$0 < 50 ? 1 : 5, $0 - 15] }
    let found = await ViewerScanner(driver: viewer, reader: reader).scan(tabId: 34, targets: [5], progress: { _ in })
    #expect(found.map(\.pageIndex) == [20])
    #expect(await viewer.restoredIndex == 87)
}

@Test func viewerRunningHeadDoesNotBurnTheBudget() async {
    let viewer = viewer()
    let found = await ViewerScanner(driver: viewer, reader: NumbersReader { [3, $0 - 15] })
        .scan(tabId: 34, targets: [5], progress: { _ in })
    #expect(found.map(\.pageIndex) == [20])
    #expect(await viewer.capturedIndices.count <= 4)
}

// I4
@Test func chapterNumberOnANeighbourIsNotThePage() {
    // Page 1 is an opener with no number at index 16; index 17 prints "Chapter 1  2".
    let numbers: (Int) -> [Int] = { $0 == 16 ? [] : ($0 > 16 ? [1, $0 - 15] : []) }
    #expect(OffsetEstimator.locate(1, offset: -15, pageCount: 100, numbersAt: numbers) == nil)
}

@Test func aSingleStrayNumberSetsNoOffset() throws {
    let samples = (0..<15).map { (pdfIndex: $0 * 10, numbers: $0 == 1 ? [7] : [Int]()) }
    #expect(OffsetEstimator.estimate(samples) == nil)
    #expect(OffsetEstimator.estimate([(pdfIndex: 0, numbers: [1])]) == 1)     // a one-page document is all it has
    let data = TestPDF.text(pageCount: 30, printed: { $0 == 2 ? "7" : nil })
    let mapper = PageMapper(document: try #require(PDFDocument(data: data)), reader: CountingReader())
    #expect(mapper.locate([7]).isEmpty)
}

// I5
@Test func oneTextPageDoesNotDisableRecognition() throws {
    let doc = try #require(PDFDocument(data: TestPDF.scanned(pageCount: 40, printed: TestPDF.book(frontMatter: 4))))
    let cover = try #require(PDFDocument(data: TestPDF.text(pageCount: 1, printed: { _ in nil }))?.page(at: 0))
    doc.insert(cover, at: 0)
    #expect(PageMapper(document: doc).locate([20]) == [20: PageMatch(printed: 20, pdfIndex: 24, method: .textRecognition)])
}

@Test func textPDFWithoutNumbersStillNeverRunsOCR() throws {
    let reader = CountingReader()
    let data = TestPDF.text(pageCount: 30, printed: { _ in nil })
    #expect(PageMapper(document: try #require(PDFDocument(data: data)), reader: reader).locate([5]).isEmpty)
    #expect(reader.calls == 0)
}

// I6
@Test(arguments: [
    Set(100..<108).union(200..<208).union(300..<308).union(400..<408),
    Set(100..<116).union(300..<316),
    Set(stride(from: 40, to: 500, by: 25)),
])
func platesDoNotLoseDistantPages(plates: Set<Int>) throws {
    let printed = TestPDF.book(frontMatter: 16, plates: plates)
    let doc = try #require(PDFDocument(data: TestPDF.text(pageCount: 500, printed: printed)))
    let mapper = PageMapper(document: doc, reader: CountingReader())
    for target in [10, 100, 200, 400] {
        let truth = (0..<500).first { printed($0) == "\(target)" }
        #expect(mapper.locate([target])[target]?.pdfIndex == truth, "page \(target)")
    }
}

// I7
@Test func viewerStopsOnUnnumberedBackMatter() async {
    let viewer = viewer(pageCount: 340)
    let book = TestPDF.book(frontMatter: 16)
    let reader = IndexEncodedReader { $0 < 300 ? book($0) : nil }
    let found = await ViewerScanner(driver: viewer, reader: reader).scan(tabId: 34, targets: [290], progress: { _ in })
    #expect(found.isEmpty)
    #expect(await viewer.capturedIndices.count <= 6)
}

@Test func viewerStopsWhenNeighboursBracketAnAbsentPage() async {
    // The numbering skips 231 outright, so no page shows it.
    let viewer = viewer()
    let reader = NumbersReader { [$0 < 246 ? $0 - 15 : $0 - 14] }
    let rec = StepRecorder()
    let found = await ViewerScanner(driver: viewer, reader: reader).scan(tabId: 34, targets: [231], progress: rec.callback)
    #expect(found.isEmpty)
    #expect(await viewer.capturedIndices.count <= 3)
}

@Test func viewerUnnumberedOpenerDoesNotStarveLaterTargets() async {
    let viewer = viewer()
    let book = TestPDF.book(frontMatter: 16)
    let reader = IndexEncodedReader { $0 == 246 ? nil : book($0) }
    let targets = Array(231...240)
    let found = await ViewerScanner(driver: viewer, reader: reader).scan(tabId: 34, targets: targets, progress: { _ in })
    #expect(found.map(\.printed) == targets)
    #expect(found.first?.pageIndex == 246)
}

// I8
@Test(arguments: [(90, (570, 400)), (270, (30, 400))])
func rotatedTextPagesAreMapped(rotate: Int, label: (Int, Int)) throws {
    let data = RawPDF.make(pageCount: 40, nums: nil, printed: TestPDF.book(frontMatter: 4), rotate: rotate, labelAt: label)
    let doc = try #require(PDFDocument(data: data))
    #expect(PageMapper(document: doc, reader: CountingReader()).locate([20])[20]?.pdfIndex == 23)
}

@Test func bandsFollowTheDisplayedEdges() {
    let box = CGRect(x: 0, y: 0, width: 600, height: 800)
    #expect(PrintedNumbers.bands(of: box, rotation: 90)[0] == CGRect(x: 0, y: 0, width: 72, height: 800))
    #expect(PrintedNumbers.bands(of: box, rotation: 90)[1] == CGRect(x: 528, y: 0, width: 72, height: 800))
    #expect(PrintedNumbers.bands(of: box, rotation: 270)[0] == CGRect(x: 528, y: 0, width: 72, height: 800))
}

// I9
@Test func unnumberedOpenerIsFoundBetweenItsNeighbours() throws {
    let book = TestPDF.book(frontMatter: 16)
    let data = TestPDF.text(pageCount: 300, printed: { $0 == 246 ? nil : book($0) })
    let mapper = PageMapper(document: try #require(PDFDocument(data: data)), reader: CountingReader())
    #expect(mapper.locate([231, 232]) == [231: PageMatch(printed: 231, pdfIndex: 246, method: .printedNumbers),
                                          232: PageMatch(printed: 232, pdfIndex: 247, method: .printedNumbers)])
}

@Test func twoUnnumberedPagesProveNothing() {
    let numbers: (Int) -> [Int] = { [245: [230], 248: [232]][$0] ?? [] }
    #expect(OffsetEstimator.locate(231, offset: -15, pageCount: 300, numbersAt: numbers) == nil)
}
