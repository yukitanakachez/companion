# WS2 — Page Finder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read `2026-11-01-companion-00-overview.md` (rules, global constraints, cross-workstream APIs) and the spec (§5.5) first.

**Goal:** Turn "explain pages 231–232" into rendered images + text of the right pages of the Classroom/Drive textbook, with live progress steps, a per-session PDF cache, and a viewer-scrolling fallback when downloads are blocked.

**Architecture:** `CompanionPageFinder` is UI-free Swift over PDFKit, CoreGraphics and Vision. A parser detects page references; a resolver picks the Drive file from the tab context; the `PageFinder` actor downloads through `DocumentFetching`, caches the PDF per file id, maps printed numbers to PDF indices (page labels → header/footer text → Vision text recognition, all sampling-based so 500-page books stay fast) and renders the matches. When the download is blocked and that file is open in a Drive viewer, a scanner drives the viewer through `ViewerDriving` instead.

**Tech Stack:** Swift 6.4 (language mode 6), PDFKit, CoreGraphics (`CGPDFDocument`, `CGContext`), ImageIO, Vision; tests: Swift Testing, CoreText (generated PDFs), `CompanionTestSupport` fakes and fixtures.

**Spec:** `docs/superpowers/specs/2026-11-01-screen-companion-design.md` (§5.5 page finder, §7 errors, §8 testing)

## Global Constraints

- All of the overview's Rules and Global Constraints apply. Edit only `Sources/CompanionPageFinder/` and `Tests/CompanionPageFinderTests/`. Never redeclare a `CompanionCore` type (`DocumentChoice`, `DriveFileRef`, `TabContext`, `RenderedPage`, `ImageAttachment`, `BridgeError`, `ViewerInfo`, …).
- Public API = the overview's "CompanionPageFinder (WS2)" block, verbatim; everything else is `internal`. Tests use `@testable import CompanionPageFinder`, `import CompanionCore`, `import CompanionTestSupport`, `import Testing` (no XCTest).
- Test command: `swift test --filter CompanionPageFinderTests`. The test target declares no resources, so every PDF is generated in test code (Task 2). Every commit step first runs `git add Sources/CompanionPageFinder Tests/CompanionPageFinderTests`.
- No AppKit/SwiftUI in `Sources/CompanionPageFinder/`. `PDFDocument`/`PDFPage` are not `Sendable`; they cross an actor boundary only inside `LoadedPDF` (Task 10), which is touched only synchronously on the `PageFinder` actor.
- `pdfIndex` is 0-based everywhere; only `displayText` adds 1.
- Values this workstream relies on: page cap **10** per question; rendered page PNG long edge **1500 px**; page text cap **8,000** characters; header/footer bands = top and bottom **12%** of the page's crop box (or page image); printed numbers = standalone integers **1–9999**; offset samples ≤ **15** pages (text layer) / ≤ **9** pages (text recognition); an offset needs **≥ 3** agreeing samples, or ≥ 50% of the number-bearing samples when there are fewer (`min(3, (n + 1) / 2)`); locate window **±10** pages; text recognition at **2×** with `VNRecognizeTextRequest` `.accurate`, `usesLanguageCorrection = false`; viewer fallback ≤ **12** captures per `find`; cache file `<directory>/<fileId>.pdf`; a 500-page text PDF maps 2 targets in **< 1.0 s**.
- Copy is exact, including “ ” (U+201C/U+201D), … (U+2026), → (U+2192) and — (U+2014): step copy in Task 1, failure copy in Task 11.

## Review Focus

1. **Odd page-reference phrasings** (en/em dash, "to"/"through", lists, "p231", reversed or abbreviated ranges like "pp. 231-35", more than 10 pages) must parse correctly. Plain math, "chapter 5", "the 2nd page" and roman numerals must not trigger. *Task 1: `parsesPageReferences`, `ignoresNonReferences`, `abbreviatedRangeEnd`, `capsAtTenPages`.*
2. **Numbering where page 1 isn't PDF page 1**: roman front matter, labels that restart per chapter, and scanner-written "identity" `/PageLabels` (`[0 << /S /D >>]`) laid over an offset printed numbering. Arabic page N must land on the page that shows N, identity labels must never beat printed numbers, and a restart resolves to the first occurrence. *Task 3: `labelsAfterRomanFrontMatter`, `identityLabelsAreIgnored`, `restartingLabelsUseFirstOccurrence`; Task 7: `identityLabelsFallBackToPrintedNumbers`.*
3. **Scanned books with no text layer**: numbers come from Vision reading the bands, with method `.textRecognition`. Text PDFs never pay for OCR. *Task 6: `readsHeaderNumber`, `readsFooterNumber`; Task 7: `scannedBookUsesTextRecognition`, `textPDFNeverRunsOCR`.*
4. **Page beyond the book, or across unnumbered plates**: the result is `.notFound` or `missing`, never a neighbouring page, and the viewer fallback spends no captures on impossible targets. *Task 5: `locateRequiresTheNumberOnThePage`, `driftAcrossPlates`; Task 11: `pageBeyondBookIsNotFound`, `partialMatchReportsMissing`; Task 12: `targetBeyondBookCostsNoCaptures`.*
5. **Huge (400+ page) textbooks and follow-up questions**: sampling keeps mapping under 1 s, and a second question about the same book doesn't download it again. *Task 7: `fiveHundredPagesUnderOneSecond`; Task 11: `secondFindUsesCache`.*

## Plan-level calls (flag to the owner; not in the spec)

- **Several PDF attachments and no title match → the first PDF in attachment order**, not "the PDF with the most pages" (spec §5.5.1.ii). Page counts aren't known until every attachment has been downloaded. The document chip lets the user switch with one click. *(Task 9)*
- **Download blocked and the front tab is not a Drive viewer of that same file → `.failed("Downloads are disabled for “<title>”. Open the PDF and ask again so I can scroll through it.")`.** The frozen contract has no "open the viewer" request. The `.downloadBlocked` step is emitted only when the viewer fallback actually runs, because its copy promises scrolling. *(Tasks 11–12)*
- The viewer fallback requires `tab.drive?.file.fileId == chosen.fileId`, so it never scrolls a different document than the one being answered about. *(Task 12)*
- A cache hit emits no `.downloading`/`.downloaded` steps. Identity `/PageLabels` are ignored. The 12-capture viewer budget is per `find`, not per page. *(Tasks 3, 11, 12)*

---

### Task 1: Public types and page-reference parser

**Files:**
- Create: `Sources/CompanionPageFinder/PageReference.swift`, `Sources/CompanionPageFinder/PageFinderTypes.swift`
- Delete: `Sources/CompanionPageFinder/CompanionPageFinder.swift`, `Tests/CompanionPageFinderTests/PlaceholderTests.swift` (WS0 placeholders)
- Test: `Tests/CompanionPageFinderTests/PageReferenceParserTests.swift`, `Tests/CompanionPageFinderTests/PageFinderStepTests.swift`

**Interfaces:**
- Consumes: `DocumentChoice`, `DriveFileRef`, `RenderedPage` (CompanionCore).
- Produces (verbatim from the overview): `PageReference` (plus `public init(pages: [Int], requestedCount: Int)`), `PageReferenceParser.parse(_:) -> PageReference?`, `PageReferenceParser.maxPages = 10` (public), `MappingMethod`, `PageFinderStep` with `displayText`, and `PageFinderOutcome`.

- [ ] **Step 1: Write the failing tests**
```swift
@Test(arguments: [
    ("explain pages 231-232", [231, 232]), ("pp. 231–232", [231, 232]), ("pp 231—232", [231, 232]),
    ("pages 231 to 232", [231, 232]), ("pages 231 through 233", [231, 232, 233]),
    ("page 231", [231]), ("p. 231", [231]), ("p231", [231]), ("pg 231", [231]), ("pg. 231", [231]),
    ("Page 12", [12]), ("do #4 on page 231", [231]), ("pages 231, 233 and 235", [231, 233, 235]),
    ("pages 231 and 233", [231, 233]), ("pages 232-231", [231, 232]),
    ("explain page 231 to me", [231]), ("page 231 and page 240", [231, 240]),
])
func parsesPageReferences(question: String, pages: [Int]) {
    #expect(PageReferenceParser.parse(question) == PageReference(pages: pages, requestedCount: pages.count))
}
@Test(arguments: ["solve x^2 + 231 = 0", "what's on this page?", "page", "chapter 5", "the 2nd page",
                  "pages xii-xiv", "page 0", "page 12345", "if p = 5 find q", "top 10 tips"])
func ignoresNonReferences(_ question: String) { #expect(PageReferenceParser.parse(question) == nil) }

@Test func capsAtTenPages() {
    #expect(PageReferenceParser.parse("pages 500-520") == PageReference(pages: Array(500...509), requestedCount: 21))
}
@Test func abbreviatedRangeEnd() {
    #expect(PageReferenceParser.parse("pp. 231-35")?.pages == [231, 232, 233, 234, 235])
    #expect(PageReferenceParser.parse("pages 98-102")?.pages == [98, 99, 100, 101, 102])
}
```

`PageFinderStepTests.swift`:
```swift
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
```
- [ ] **Step 2: Run** `swift test --filter CompanionPageFinderTests` → FAIL (types not defined).
- [ ] **Step 3: Implement the types and `PageReferenceParser.parse(_ question: String) -> PageReference?`.** The tests don't fully determine the grammar, so here it is (case-insensitive, Swift `Regex` or `NSRegularExpression`):
```text
keyword := (pages|page|pgs|pg|pp|p) "."?   -- must not be preceded by a letter or digit ("top 10", "step 3" don't match)
number  := 1–4 digits, not followed by a letter or digit; value 1…9999
range   := number \s* (-|–|—) \s* number  |  number \s+ (to|through|thru) \s+ number
list    := item ( \s* ("," | "&" | "and" | ", and") \s* item )*      -- item = range | number; a separator is
                                                                      -- consumed only when a number follows it
match   := keyword \s* list                                           -- union every match in the question
```

For a range a–b: if b < a and b has fewer digits than a, b borrows a's leading digits (231-35 → 235). If b is then still < a, swap the two. The result is the sorted, de-duplicated pages: `requestedCount` = their count, `pages` = the first `maxPages`. Return nil when nothing matches.

- [ ] **Step 4: Run** `swift test --filter CompanionPageFinderTests` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(pagefinder): public types and page-reference parser"`

### Task 2: Test PDF builders (test support)

**Files:**
- Create: `Tests/CompanionPageFinderTests/Support/TestPDF.swift`, `Tests/CompanionPageFinderTests/Support/RawPDF.swift`
- Test: `Tests/CompanionPageFinderTests/TestPDFTests.swift`

**Interfaces:**
- Produces (test target only):
```swift
enum TestPDF {
    enum Band: Sendable { case header, footer }
    static let pageSize = CGSize(width: 612, height: 792)            // US Letter, points
    static let runningHead = "Quadratic Functions"                   // no digits
    static let textbookNums = "[0 << /S /r >> 16 << /S /D /St 1 >>]"   // i…xvi, then 1, 2, 3…
    /// Text-layer PDF. `printed(i)` is the label printed on 0-based page i (nil → none).
    static func text(pageCount: Int, band: Band = .footer, printed: (Int) -> String?,
                     body: (Int) -> String = { "Exercise \($0 % 7 + 1): solve 3x + 42 = 0." },
                     bodyFontSize: CGFloat = 12, size: CGSize = pageSize) -> Data
    /// Same layout rasterized at 2× into a bitmap; the bitmap is the page's only content (no text layer).
    static func scanned(pageCount: Int, band: Band = .footer, printed: (Int) -> String?) -> Data
    /// Lowercase roman (i, ii, …) on the first `frontMatter` pages, nil on `plates`, then 1, 2, 3… on the rest.
    static func book(frontMatter: Int, plates: Set<Int> = []) -> @Sendable (Int) -> String?
}
enum RawPDF {
    /// Hand-written PDF; `nums` is the verbatim /Nums array, nil → no /PageLabels in the catalog.
    static func make(pageCount: Int, nums: String?, printed: (Int) -> String? = { _ in nil }) -> Data
}
```
- [ ] **Step 1: Write the failing tests**
```swift
@Test func textPDFHasTextLayer() throws { /* text(pageCount: 3, printed: { "\($0 + 10)" }) → pageCount 3; page(at: 1).string contains "11", "Quadratic Functions", "Exercise" */ }
@Test func scannedPDFHasNoTextLayer() throws { /* scanned(pageCount: 2, …) → pageCount 2; page(at: 0).string is nil or whitespace */ }
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
```
- [ ] **Step 2: Run** `swift test --filter CompanionPageFinderTests` → FAIL.
- [ ] **Step 3: Implement the builders.**
  - **Layout** (`text` and `scanned`), in PDF coordinates with the origin at the bottom left, page w × h: the running head is Helvetica 14 at (72, h − 40). The printed label is Helvetica 14, right-aligned to x = w − 72 on baseline h − 40 (`.header`) or centred on baseline 40 (`.footer`). The body goes through a `CTFramesetter` in the rect (72, 0.15h, w − 144, 0.7h) at `bodyFontSize`. Everything therefore stays inside or outside the 12% bands as intended.
  - **`text`** draws with CoreText into `CGContext(consumer:mediaBox:_:)` (`beginPDFPage`/`endPDFPage`/`closePDF`).
  - **`scanned`** draws the same layout into a white sRGB bitmap at scale 2 and then `draw(image, in: mediaBox)` on the PDF page.
  - **`RawPDF`** has to write a valid file by hand, because PDFKit can't write page labels. Write it as follows (ASCII):

```text
"%PDF-1.4\n"; each object as "k 0 obj\n<body>\nendobj\n", recording the byte offset where "k 0 obj" starts
1: << /Type /Catalog /Pages 2 0 R /PageLabels << /Nums <nums> >> >>      (omit /PageLabels when nums == nil)
2: << /Type /Pages /Kids [4 0 R 6 0 R …] /Count N >>
3: << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>
page i → 4+2i: << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents <5+2i> 0 R >>
         5+2i: << /Length L >>\nstream\n<content>\nendstream            (L = byte count of <content>)
content: "BT /F1 12 Tf 72 400 Td (Body text <i>) Tj ET" + (printed(i) != nil ? "\nBT /F1 14 Tf 300 40 Td (<label>) Tj ET" : "")
xref:    "xref\n0 <3+2N+1>\n0000000000 65535 f \n" + one String(format: "%010d 00000 n \n", offset) per object (20 bytes each)
tail:    "trailer\n<< /Size <3+2N+1> /Root 1 0 R >>\nstartxref\n<byte offset of \"xref\">\n%%EOF\n"
```
- [ ] **Step 4: Run** `swift test --filter CompanionPageFinderTests` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "test(pagefinder): generated text, scanned and page-label PDFs"`

### Task 3: Page-label reader

**Files:**
- Create: `Sources/CompanionPageFinder/PageLabels.swift`
- Test: `Tests/CompanionPageFinderTests/PageLabelTests.swift`

**Interfaces:**
- Consumes: `TestPDF`, `RawPDF` (Task 2).
- Produces:
```swift
struct PageLabelTable: Sendable {
    /// nil unless the catalog (`document.documentRef?.catalog`, CGPDFDictionaryGetObject "PageLabels") has /PageLabels
    /// AND at least one page's `PDFPage.label` differs from "\(index + 1)" (identity labels carry no information).
    static func make(for document: PDFDocument) -> PageLabelTable?
    func index(ofPrinted page: Int) -> Int?     // first page whose label is exactly "\(page)"
}
```
- [ ] **Step 1: Write the failing tests**
```swift
@Test func labelsAfterRomanFrontMatter() throws {
    let doc = try #require(PDFDocument(data: RawPDF.make(pageCount: 300, nums: TestPDF.textbookNums)))
    let table = try #require(PageLabelTable.make(for: doc))
    #expect(table.index(ofPrinted: 231) == 246 && table.index(ofPrinted: 232) == 247)
    #expect(table.index(ofPrinted: 1) == 16 && table.index(ofPrinted: 285) == nil)
}
@Test func noPageLabelsMeansNoTable() throws { /* make == nil for RawPDF.make(pageCount: 5, nums: nil) and for TestPDF.text(pageCount: 5, …) */ }
@Test func identityLabelsAreIgnored() throws { /* RawPDF.make(pageCount: 30, nums: "[0 << /S /D >>]") → make == nil */ }
@Test func restartingLabelsUseFirstOccurrence() throws { /* RawPDF.make(pageCount: 20, nums: "[0 << /S /D >> 10 << /S /D >>]") → index(ofPrinted: 5) == 4, index(ofPrinted: 11) == nil */ }
```
- [ ] **Step 2: Run** `swift test --filter CompanionPageFinderTests` → FAIL.
- [ ] **Step 3: Implement `PageLabelTable`.** Build a `[String: Int]` of first occurrences once, at `make`.
- [ ] **Step 4: Run** `swift test --filter CompanionPageFinderTests` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(pagefinder): trusted page-label lookup"`

### Task 4: Printed numbers from the text layer

**Files:**
- Create: `Sources/CompanionPageFinder/PrintedNumbers.swift`
- Test: `Tests/CompanionPageFinderTests/PrintedNumberTests.swift`

**Interfaces:**
- Consumes: `TestPDF` (Task 2).
- Produces:
```swift
enum PrintedNumbers {
    static let bandFraction: CGFloat = 0.12
    /// Standalone integers in 1...9999, in order of appearance: no leading zero, and not adjacent to a letter,
    /// a digit, or one of . , / -   ("2-14", "3.5", "1/2", "p231", "12th" yield nothing).
    static func integers(in text: String) -> [Int]
    static func bands(of rect: CGRect) -> [CGRect]          // [header, footer]; origin bottom-left (PDF space)
    static func textLayerNumbers(on page: PDFPage) -> [Int] // integers(in:) of page.selection(for: band)?.string, header then footer, over bounds(for: .cropBox)
    static func hasTextLayer(_ page: PDFPage) -> Bool       // page.string has a non-whitespace character
}
```
- [ ] **Step 1: Write the failing tests**
```swift
@Test(arguments: [("Chapter 5 · 231", [5, 231]), ("— 231 —", [231]), ("Page 12", [12]), ("9999", [9999]),
                  ("2-14", []), ("xii", []), ("3.5", []), ("1/2", []), ("0 and 10000", []), ("007", [])])
func standaloneIntegers(text: String, expected: [Int]) { #expect(PrintedNumbers.integers(in: text) == expected) }

@Test func bandsAreTwelvePercent() {
    let b = PrintedNumbers.bands(of: CGRect(x: 0, y: 0, width: 612, height: 800))
    #expect(abs(b[0].minY - 704) < 0.001 && abs(b[0].height - 96) < 0.001 && b[1].minY == 0 && abs(b[1].height - 96) < 0.001)
}
@Test func footerNumberIgnoresBody() throws {
    let page = try #require(PDFDocument(data: TestPDF.text(pageCount: 1, band: .footer, printed: { _ in "231" }))?.page(at: 0))
    #expect(PrintedNumbers.textLayerNumbers(on: page) == [231])          // body "solve 3x + 42 = 0" is outside the bands
}
@Test func headerNumber() throws { /* same with band: .header → [231] */ }
@Test func romanFooterYieldsNothing() throws { /* printed: { _ in "xii" } → [] */ }
@Test func scannedPageHasNoTextLayer() throws { /* TestPDF.scanned page: hasTextLayer == false, textLayerNumbers == [] */ }
```
- [ ] **Step 2: Run** `swift test --filter CompanionPageFinderTests` → FAIL.
- [ ] **Step 3: Implement `PrintedNumbers`** as declared.
- [ ] **Step 4: Run** `swift test --filter CompanionPageFinderTests` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(pagefinder): header/footer number extraction from text layer"`

### Task 5: Offset estimation and locate

**Files:**
- Create: `Sources/CompanionPageFinder/OffsetEstimator.swift`
- Test: `Tests/CompanionPageFinderTests/OffsetEstimatorTests.swift`

**Interfaces:**
- Consumes: `PrintedNumbers.textLayerNumbers(on:)` (Task 4), `TestPDF` (Task 2).
- Produces (pure; reused by text-layer, text-recognition and viewer paths):
```swift
enum OffsetEstimator {
    static let window = 10
    /// Evenly spaced, includes first and last; every index when pageCount ≤ maxSamples.
    static func sampleIndices(pageCount: Int, maxSamples: Int) -> [Int]
    /// offset = printed − pdfIndex. nil unless the winner has ≥ min(3, (n + 1) / 2) votes (n = samples with ≥ 1 number).
    static func estimate(_ samples: [(pdfIndex: Int, numbers: [Int])]) -> Int?
    /// Tries target − offset, then +1, −1, +2, −2 … ±10, skipping indices outside 0..<pageCount;
    /// returns the first index whose numbers contain target.
    static func locate(_ target: Int, offset: Int, pageCount: Int, numbersAt: (Int) -> [Int]) -> Int?
}
```
- [ ] **Step 1: Write the failing tests**
```swift
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
@Test func noPrintedNumbersMeansNoOffset() throws { /* TestPDF.text(pageCount: 30, printed: { _ in nil }) → estimate == nil */ }
```
- [ ] **Step 2: Run** `swift test --filter CompanionPageFinderTests` → FAIL.
- [ ] **Step 3: Implement `OffsetEstimator`.** Each sample votes once for each distinct `number − pdfIndex`. The most votes wins. Break ties in favour of the offset whose first vote came from the lowest `pdfIndex` (the first section of a book whose numbering restarts).
- [ ] **Step 4: Run** `swift test --filter CompanionPageFinderTests` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(pagefinder): offset estimation and neighbour search"`

### Task 6: Text recognition for scanned pages

**Files:**
- Create: `Sources/CompanionPageFinder/TextRecognition.swift`
- Test: `Tests/CompanionPageFinderTests/TextRecognitionTests.swift`

**Interfaces:**
- Consumes: `PrintedNumbers.integers(in:)`, `PrintedNumbers.bandFraction` (Task 4).
- Produces:
```swift
protocol PrintedNumberReading: Sendable {
    /// Standalone integers read in the top and bottom 12% of a full-page image (header first).
    func numbers(inPageImage image: CGImage) -> [Int]
}
struct VisionNumberReader: PrintedNumberReading { init() }
enum PageRaster {
    /// White-filled sRGB bitmap of the page's crop box at `scale` px per point (honours page.rotation).
    static func image(of page: PDFPage, scale: CGFloat) -> CGImage?
}
```
- [ ] **Step 1: Write the failing tests**
```swift
@Test func readsHeaderNumber() throws {
    let page = try #require(PDFDocument(data: TestPDF.scanned(pageCount: 1, band: .header, printed: { _ in "231" }))?.page(at: 0))
    let image = try #require(PageRaster.image(of: page, scale: 2))
    #expect(image.width == 1224 && image.height == 1584)
    #expect(VisionNumberReader().numbers(inPageImage: image).contains(231))
}
@Test func readsFooterNumber() throws { /* band: .footer, printed "47" → numbers contains 47 and does not contain 42 (the body's "42" is outside the bands) */ }
```
- [ ] **Step 2: Run** `swift test --filter CompanionPageFinderTests` → FAIL.
- [ ] **Step 3: Implement.** Crop the image into its two bands (CGImage rows run top-down, so the header is the top 12%). Run one `VNRecognizeTextRequest` per band, with `recognitionLevel = .accurate` and `usesLanguageCorrection = false`, then pass each observation's top candidate through `PrintedNumbers.integers(in:)`. Recognize each band separately, not the whole page: on a full-page image, Vision's default `minimumTextHeight` (1/32 of image height) drops 14-pt page numbers. `PageRaster` draws with `PDFPage.draw(with: .cropBox, to:)`.
- [ ] **Step 4: Run** `swift test --filter CompanionPageFinderTests` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(pagefinder): Vision page-number reader for scanned pages"`

### Task 7: Page mapper (labels → printed numbers → text recognition)

**Files:**
- Create: `Sources/CompanionPageFinder/PageMapper.swift`, `Tests/CompanionPageFinderTests/Support/TestDoubles.swift`
- Test: `Tests/CompanionPageFinderTests/PageMapperTests.swift`

**Interfaces:**
- Consumes: `PageLabelTable` (Task 3), `PrintedNumbers` (Task 4), `OffsetEstimator` (Task 5), `PrintedNumberReading`, `VisionNumberReader`, `PageRaster` (Task 6).
- Produces:
```swift
struct PageMatch: Sendable, Equatable { var printed: Int; var pdfIndex: Int; var method: MappingMethod }
final class PageMapper {
    static let textSamples = 15, ocrSamples = 9, ocrScale: CGFloat = 2
    init(document: PDFDocument, reader: any PrintedNumberReading = VisionNumberReader())
    /// Unmatched targets are absent. Memoizes the label table, per-page numbers, offsets and per-target results.
    func locate(_ targets: [Int]) -> [Int: PageMatch]
}
// TestDoubles.swift: final class CountingReader: PrintedNumberReading, @unchecked Sendable — NSLock-protected `calls`; returns [].
```
- [ ] **Step 1: Write the failing tests**
```swift
@Test func labelsWin() throws {
    let mapper = PageMapper(document: try #require(PDFDocument(data: RawPDF.make(pageCount: 300, nums: TestPDF.textbookNums))))
    #expect(mapper.locate([231, 232]) == [231: PageMatch(printed: 231, pdfIndex: 246, method: .pageLabels),
                                          232: PageMatch(printed: 232, pdfIndex: 247, method: .pageLabels)])
}
@Test func identityLabelsFallBackToPrintedNumbers() throws { /* RawPDF.make(pageCount: 300, nums: "[0 << /S /D >>]", printed: TestPDF.book(frontMatter: 16)) → locate([231]) == [231: (231, 246, .printedNumbers)] */ }
@Test func printedNumbersWithDrift() throws { /* TestPDF.text(pageCount: 400, printed: book(frontMatter: 16, plates: [200, 201])) → locate([150, 300]) == [150: (150, 165, .printedNumbers), 300: (300, 317, .printedNumbers)] */ }
@Test func scannedBookUsesTextRecognition() throws {
    let doc = try #require(PDFDocument(data: TestPDF.scanned(pageCount: 40, band: .footer, printed: TestPDF.book(frontMatter: 4))))
    #expect(PageMapper(document: doc).locate([20]) == [20: PageMatch(printed: 20, pdfIndex: 23, method: .textRecognition)])
}
@Test func textPDFNeverRunsOCR() throws { /* CountingReader; TestPDF.text(pageCount: 60, printed: book(frontMatter: 16)) → locate([999]).isEmpty (beyond the book); reader.calls == 0 */ }
@Test func fiveHundredPagesUnderOneSecond() throws {
    let reader = CountingReader()
    let mapper = PageMapper(document: try #require(PDFDocument(data: TestPDF.text(pageCount: 500, printed: TestPDF.book(frontMatter: 16)))), reader: reader)
    var result: [Int: PageMatch] = [:]
    let elapsed = ContinuousClock().measure { result = mapper.locate([231, 232]) }
    #expect(elapsed < .seconds(1))
    #expect(result[231]?.pdfIndex == 246 && result[232]?.pdfIndex == 247 && reader.calls == 0)
}
@Test(.enabled(if: ProcessInfo.processInfo.environment["COMPANION_REAL_PDF_DIR"] != nil)) func realTextbooks() throws { /* Spec §8 (real PDFs stay out of the repo): <dir>/expectations.json = [{"file", "printed", "pdfIndex"}]; each locate([printed]) hits pdfIndex */ }
```
- [ ] **Step 2: Run** `swift test --filter CompanionPageFinderTests` → FAIL.
- [ ] **Step 3: Implement `PageMapper`.** Each stage handles only the targets the stage before it left unmatched. (1) **Page labels:** if `PageLabelTable.make` is non-nil → `.pageLabels`. (2) **Printed numbers:** sample ≤ 15 pages with `textLayerNumbers`, `estimate`, then `locate` with `textLayerNumbers` → `.printedNumbers`. (3) **Text recognition:** only if none of the stage-2 samples `hasTextLayer`; sample ≤ 9 pages via `PageRaster.image(scale: 2)` + `reader`, `estimate`, `locate` → `.textRecognition`. A stage whose `estimate` is nil matches nothing. Memoize each page's numbers per source, and keep misses in the per-target memo too.
- [ ] **Step 4: Run** `swift test --filter CompanionPageFinderTests` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(pagefinder): printed-page to PDF-page mapper"`

### Task 8: Page renderer

**Files:**
- Create: `Sources/CompanionPageFinder/PageRenderer.swift`
- Test: `Tests/CompanionPageFinderTests/PageRendererTests.swift`

**Interfaces:**
- Consumes: `PageRaster` (Task 6); `RenderedPage`, `ImageAttachment` (CompanionCore).
- Produces:
```swift
enum PageRenderer {
    static let longEdge = 1500, textLimit = 8_000
    /// PNG (ImageIO) whose long edge is exactly 1500 px; text = page.string ?? "" truncated to 8,000 characters;
    /// RenderedPage(printedLabel: "\(printed)", pdfIndex: pdfIndex, image:, text:). nil only if rasterizing fails.
    static func render(_ page: PDFPage, pdfIndex: Int, printed: Int) -> RenderedPage?
}
```
- [ ] **Step 1: Write the failing tests**
```swift
@Test func portraitPage() throws {
    let page = try #require(PDFDocument(data: TestPDF.text(pageCount: 1, printed: { _ in "231" }))?.page(at: 0))
    let r = try #require(PageRenderer.render(page, pdfIndex: 246, printed: 231))
    #expect(r.printedLabel == "231" && r.pdfIndex == 246)
    #expect(r.image.pixelWidth == 1159 && r.image.pixelHeight == 1500)
    #expect(r.image.png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) && r.text.contains("Exercise"))
}
@Test func landscapePage() throws { /* size: CGSize(width: 792, height: 612) → 1500 × 1159 */ }
@Test func textIsCapped() throws { /* body: { _ in String(repeating: "abcdefghi ", count: 1_100) }, bodyFontSize: 3 → r.text.count == 8_000 */ }
```
- [ ] **Step 2: Run** `swift test --filter CompanionPageFinderTests` → FAIL.
- [ ] **Step 3: Implement `render`.** Scale = 1500 / the long edge of the (rotated) crop box in points. Pixel sizes are `Int((points × scale).rounded())`.
- [ ] **Step 4: Run** `swift test --filter CompanionPageFinderTests` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(pagefinder): render matched pages to PNG + text"`

### Task 9: Document resolver

**Files:**
- Create: `Sources/CompanionPageFinder/DocumentResolver.swift`, `Tests/CompanionPageFinderTests/Support/FixtureTabs.swift`
- Test: `Tests/CompanionPageFinderTests/DocumentResolverTests.swift`

**Interfaces:**
- Consumes: `TabContext`, `DriveFileRef`, `DocumentChoice`, `ExtensionToApp` (CompanionCore); `Fixtures.bridgeFixture(_:)` (CompanionTestSupport).
- Produces:
```swift
enum DocumentResolver {
    static let stopwords: Set<String> = ["page", "pages", "explain", "example", "problem", "problems",
                                         "what", "does", "this", "that", "with", "from", "about", "the"]
    static func isPDF(_ file: DriveFileRef) -> Bool   // mimeType == "application/pdf" || title.lowercased().hasSuffix(".pdf")
    static func resolve(tab: TabContext?, question: String, lastUsed: DriveFileRef?, preferred: DriveFileRef?) -> DocumentChoice?
}
// FixtureTabs.swift (tests): decodes contracts fixtures through JSONDecoder().decode(ExtensionToApp.self, …)
enum FixtureTabs {
    static func tab(_ fixture: String) throws -> TabContext          // throws unless the message is .tabContext
    static func classroom() throws -> TabContext                    // "ext-tabContext-classroom.json"
    static func drive() throws -> TabContext                        // "ext-tabContext-drive.json"
    static func youtube() throws -> TabContext                      // "ext-tabContext-youtube.json"
    static let textbook = DriveFileRef(fileId: "1AbCdEfGhIjKlMnOpQrStUvWxYz012345", title: "Algebra 2 Textbook.pdf", mimeType: "application/pdf")
    static let worksheet = DriveFileRef(fileId: "1ZyXwVuTsRqPoNmLkJiHgFeDcBa987654", title: "Worksheet 5.2.pdf", mimeType: "application/pdf")
}
```
- [ ] **Step 1: Write the failing tests**
```swift
@Test func classroomPicksTitleMatch() throws {
    let tab = try FixtureTabs.classroom()
    #expect(DocumentResolver.resolve(tab: tab, question: "explain pages 231-232 of the textbook", lastUsed: nil, preferred: nil)
            == DocumentChoice(current: FixtureTabs.textbook, alternatives: [FixtureTabs.worksheet]))
    #expect(DocumentResolver.resolve(tab: tab, question: "worksheet page 2", lastUsed: nil, preferred: nil)
            == DocumentChoice(current: FixtureTabs.worksheet, alternatives: [FixtureTabs.textbook]))
}
@Test func classroomWithoutMatchTakesFirstPDF() throws { /* "explain page 5" → current textbook, alternatives [worksheet] */ }
@Test func driveViewerUsesItsFile() throws { /* drive fixture, lastUsed: worksheet → current textbook, alternatives [] */ }
@Test func preferredWins() throws { /* classroom, "…of the textbook", preferred: worksheet → current worksheet, alternatives [textbook] */ }
@Test func onlyPDFAttachmentsCount() throws { /* classroom fixture with attachments = [DriveFileRef(fileId: "d1", title: "Notes", mimeType: "application/vnd.google-apps.document"), DriveFileRef(fileId: "d2", title: "Reading.PDF", mimeType: nil)] → current d2, alternatives [] */ }
@Test func fallsBackToLastUsed() throws { /* tab nil, youtube fixture, and classroom-with-only-the-Google-Doc each, with lastUsed: worksheet → (worksheet, []) */ }
@Test func nothingAnywhere() { #expect(DocumentResolver.resolve(tab: nil, question: "page 5", lastUsed: nil, preferred: nil) == nil) }
```
- [ ] **Step 2: Run** `swift test --filter CompanionPageFinderTests` → FAIL.
- [ ] **Step 3: Implement `resolve`.**
  - **Candidates:** `tab.drive` → `[drive.file]`; otherwise the PDFs in `tab.classroom.attachments`, in order; otherwise `[]`.
  - **Order:** (1) `preferred` → (preferred, candidates minus its fileId); (2) Drive viewer → (file, []); (3) one classroom PDF → (it, []), several → the best title match, else the first PDF, with the others as alternatives in attachment order; (4) `lastUsed` → (lastUsed, []); (5) nil.
  - **Title match:** words are maximal runs of letters, lowercased, length ≥ 4 and not in `stopwords`, with one trailing "s" stripped. Title words follow the same rule after dropping the ".pdf" extension. Score = the number of question words that appear among the title words. The highest score > 0 wins; ties go to the earlier attachment. **Plan-level deviation:** the spec's "otherwise the PDF with the most pages" becomes "the first PDF", because page counts aren't known before download (see Plan-level calls).
- [ ] **Step 4: Run** `swift test --filter CompanionPageFinderTests` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(pagefinder): resolve the Drive document from tab context"`

### Task 10: Session PDF cache

**Files:**
- Create: `Sources/CompanionPageFinder/PDFSessionCache.swift`
- Test: `Tests/CompanionPageFinderTests/PDFSessionCacheTests.swift`; add `func temporaryDirectory() -> URL` (unique `FileManager.default.temporaryDirectory/PageFinderTests-<UUID>`, not created) to `Support/TestDoubles.swift`

**Interfaces:**
- Consumes: `PageMapper` (Task 7).
- Produces:
```swift
public actor PDFSessionCache {
    public init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Companion-PDFCache"))
    public func clearAll()                                      // deletes the directory and forgets every memo
    func fileURL(for fileId: String) -> URL                     // <directory>/<fileId>.pdf; chars outside [A-Za-z0-9_-] → "_"
    func cached(fileId: String) -> LoadedPDF?                   // memo, else load the file on disk, else nil
    func store(_ data: Data, fileId: String) throws -> LoadedPDF  // creates directory, writes, loads; non-PDF → removes file, throws .notAPDF
}
/// Holds non-Sendable PDFKit state; only touched synchronously on the PageFinder actor.
final class LoadedPDF: @unchecked Sendable { let document: PDFDocument; let mapper: PageMapper }
enum PageFinderError: Error, Equatable { case notAPDF }
```
- [ ] **Step 1: Write the failing tests**
```swift
@Test func storesFileAtFileIdPath() async throws {
    let dir = temporaryDirectory(); let cache = PDFSessionCache(directory: dir)
    let loaded = try await cache.store(TestPDF.text(pageCount: 3, printed: { _ in nil }), fileId: "abc")
    #expect(loaded.document.pageCount == 3)
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("abc.pdf").path))
}
@Test func memoizesPerFileId() async throws { /* store then cached(fileId: "abc") twice → both === the stored instance */ }
@Test func reloadsFromDiskInANewCache() async throws { /* store with cache A; PDFSessionCache(directory: same).cached(fileId: "abc") != nil */ }
@Test func rejectsNonPDF() async throws { /* #expect(throws: PageFinderError.notAPDF) { try await cache.store(Data("<html>".utf8), fileId: "x") }; no x.pdf on disk */ }
@Test func clearAllDeletesDirectory() async throws { /* store; clearAll(); directory doesn't exist; cached(fileId: "abc") == nil */ }
@Test func fileIdCannotEscapeDirectory() async { /* fileURL(for: "../x").deletingLastPathComponent() == dir; lastPathComponent == "___x.pdf" */ }
```
- [ ] **Step 2: Run** `swift test --filter CompanionPageFinderTests` → FAIL.
- [ ] **Step 3: Implement `PDFSessionCache` and `LoadedPDF`.** The `LoadedPDF` mapper is `PageMapper(document:)` with the default Vision reader.
- [ ] **Step 4: Run** `swift test --filter CompanionPageFinderTests` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(pagefinder): per-session PDF cache keyed by Drive file id"`

### Task 11: PageFinder façade (download path)

**Files:**
- Create: `Sources/CompanionPageFinder/PageFinder.swift`
- Test: `Tests/CompanionPageFinderTests/PageFinderTests.swift`; add `final class StepRecorder: @unchecked Sendable` (NSLock; `var steps: [PageFinderStep]`, `var callback: @Sendable (PageFinderStep) -> Void`) to `Support/TestDoubles.swift`

**Interfaces:**
- Consumes: Task 1 types, `DocumentResolver` (Task 9), `PDFSessionCache`/`LoadedPDF` (Task 10), `PageMapper.locate` (Task 7), `PageRenderer.render` (Task 8); `DocumentFetching`, `ViewerDriving`, `BridgeError` (CompanionCore); `FakeDocumentFetcher`, `FakeViewerDriver`, `Fixtures.samplePNG` (CompanionTestSupport).
- Produces: the overview's `PageFinder` (`init(fetcher:viewer:cache:)`, `find(_:question:tab:lastUsed:preferred:progress:)`), plus `static func failureMessage(_ error: BridgeError, title: String) -> String` (internal). WS7 reads `.found.choice.current` / `.notFound.document` to remember `lastUsed`, and compares `requestedCount > pages.count` to show the cap note.

- [ ] **Step 1: Write the failing tests** (file-private helpers: `idleViewer()` returns a new `FakeViewerDriver(info: ViewerInfo(pageCount: 1, currentIndex: 0), page: { _ in Fixtures.samplePNG() })`; `textbookPDF` = `RawPDF.make(pageCount: 300, nums: TestPDF.textbookNums)`)
```swift
@Test func findsPagesFromClassroomAttachment() async throws {
    let fetcher = FakeDocumentFetcher(files: [FixtureTabs.textbook.fileId: (textbookPDF, "Algebra 2 Textbook.pdf")])
    let finder = PageFinder(fetcher: fetcher, viewer: idleViewer(), cache: PDFSessionCache(directory: temporaryDirectory()))
    let q = "explain pages 231-232 of the textbook", rec = StepRecorder()
    let outcome = await finder.find(try #require(PageReferenceParser.parse(q)), question: q, tab: try FixtureTabs.classroom(),
                                    lastUsed: nil, preferred: nil, progress: rec.callback)
    #expect(rec.steps == [.downloading(title: "Algebra 2 Textbook.pdf"), .downloaded(pageCount: 300),
                          .matched(printed: 231, pdfIndex: 246, method: .pageLabels), .matched(printed: 232, pdfIndex: 247, method: .pageLabels)])
    guard case .found(let choice, let pages, let missing) = outcome else { Issue.record("\(outcome)"); return }
    #expect(choice == DocumentChoice(current: FixtureTabs.textbook, alternatives: [FixtureTabs.worksheet]))
    #expect(pages.map(\.printedLabel) == ["231", "232"] && pages.map(\.pdfIndex) == [246, 247] && missing.isEmpty)
    #expect(pages.allSatisfy { max($0.image.pixelWidth, $0.image.pixelHeight) == 1500 })
}
@Test func secondFindUsesCache() async throws { /* same finder, find twice → await fetcher.requestedFileIDs == [textbook.fileId]; the second run's steps contain no .downloading/.downloaded */ }
@Test func noDocument() async throws { /* tab nil, lastUsed nil → .noDocument; requestedFileIDs empty */ }
@Test func reusesLastUsedDocument() async throws { /* tab nil, lastUsed textbook → .found(choice: (textbook, []), …) */ }
@Test func pageBeyondBookIsNotFound() async throws { /* "page 999" → .notFound(document: FixtureTabs.textbook, pages: [999]) */ }
@Test func partialMatchReportsMissing() async throws { /* "pages 284-286" (book ends at 284) → .found with pages.map(\.printedLabel) == ["284"], missing == [285, 286] */ }
@Test func nonPDFBytesFail() async throws { /* fetcher returns Data("<html>".utf8) → .failed(message: "“Algebra 2 Textbook.pdf” isn't a PDF.") */ }
@Test(arguments: [
    (BridgeErrorCode.notConnected, "The browser extension isn't connected."),
    (.notPdf, "“Algebra 2 Textbook.pdf” isn't a PDF."),
    (.notFound, "Couldn't open “Algebra 2 Textbook.pdf” from Drive."),
    (.timeout, "Drive took too long to respond."),
    (.downloadBlocked, "Downloads are disabled for “Algebra 2 Textbook.pdf”. Open the PDF and ask again so I can scroll through it."),
    (.noViewer, "Something went wrong getting “Algebra 2 Textbook.pdf”."),
    (.internal, "Something went wrong getting “Algebra 2 Textbook.pdf”."),
])
func bridgeErrorsBecomeMessages(code: BridgeErrorCode, message: String) async throws {
    /* let viewer = idleViewer(); FakeDocumentFetcher(failure: BridgeError(code: code, message: "x")), classroom tab, "…of the textbook"
       → outcome == .failed(message: message); !rec.steps.contains(.downloadBlocked); await viewer.capturedIndices.isEmpty */
}
```
- [ ] **Step 2: Run** `swift test --filter CompanionPageFinderTests` → FAIL.
- [ ] **Step 3: Implement `PageFinder`.** (1) Resolve the document; nil → `.noDocument`. (2) `cache.cached(fileId:)`; on a miss emit `.downloading(title: choice.current.title)`, call `fetcher.fetchDrivePDF`, `cache.store`, then emit `.downloaded(pageCount:)` (use the resolver's title everywhere; ignore the fetched title). (3) `loaded.mapper.locate(reference.pages)`; emit `.matched` per hit in ascending printed order; no hits → `.notFound(document:pages: reference.pages)`. (4) Render each distinct `pdfIndex` once, in printed order → `.found(choice:pages:missing:)`. (5) A thrown `BridgeError` → `.failed(failureMessage(…))`; `PageFinderError.notAPDF` → the `notPdf` copy; any other error → the "Something went wrong" copy. `failureMessage` returns exactly the strings in the test table, and every code not listed falls to "Something went wrong". Store `viewer` now; Task 12 uses it.
- [ ] **Step 4: Run** `swift test --filter CompanionPageFinderTests` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(pagefinder): PageFinder façade for the download path"`

### Task 12: Viewer scanner and download-blocked fallback (built last; may slip to v1.1)

**Files:**
- Create: `Sources/CompanionPageFinder/ViewerScanner.swift`
- Modify: `Sources/CompanionPageFinder/PageFinder.swift` (wire the fallback; add the reader-injecting init)
- Test: `Tests/CompanionPageFinderTests/ViewerScannerTests.swift`, and add to `PageFinderTests.swift`; add `IndexEncodedReader`, `encodedPage(_:)`, `FailingViewerDriver` to `Support/TestDoubles.swift`

**Interfaces:**
- Consumes: `ViewerDriving`, `ViewerInfo`, `ImageAttachment` (CompanionCore); `PrintedNumberReading`, `VisionNumberReader` (Task 6); `PageFinderStep` (Task 1); `FakeViewerDriver` (CompanionTestSupport).
- Produces:
```swift
struct ViewerCapture: Sendable, Equatable { var printed: Int; var pageIndex: Int; var image: ImageAttachment }
struct ViewerScanner: Sendable {
    static let maxCaptures = 12
    init(driver: any ViewerDriving, reader: any PrintedNumberReading = VisionNumberReader())
    /// Restores the viewer to its starting index before returning (also after a thrown capture); [] if viewerInfo fails.
    func scan(tabId: Int, targets: [Int], progress: @Sendable (PageFinderStep) -> Void) async -> [ViewerCapture]
}
extension PageFinder { init(fetcher: any DocumentFetching, viewer: any ViewerDriving, cache: PDFSessionCache,
                            viewerReader: any PrintedNumberReading) }   // the public init passes VisionNumberReader()
// TestDoubles.swift:
func encodedPage(_ index: Int) -> ImageAttachment            // Fixtures.samplePNG(width: index + 1, height: 1)
struct IndexEncodedReader: PrintedNumberReading {            // index = image.width − 1; returns Int(printed(index)) as [n] or []
    let printed: @Sendable (Int) -> String?
}
actor FailingViewerDriver: ViewerDriving {                   // viewerInfo → info; capturePage throws BridgeError(code: .timeout, …)
    init(info: ViewerInfo); var restoredIndex: Int? { get }
}
```
- [ ] **Step 1: Write the failing tests** (`book = TestPDF.book(frontMatter: 16)` prints 72 on index 87; unless a comment says otherwise, the viewer is `FakeViewerDriver(info: ViewerInfo(pageCount: 300, currentIndex: 87), page: { encodedPage($0) })` and targets are `[231, 232]`)
```swift
@Test func findsTargetsUsingObservedOffset() async {
    let viewer = FakeViewerDriver(info: ViewerInfo(pageCount: 300, currentIndex: 87), page: { encodedPage($0) })
    let rec = StepRecorder()
    let found = await ViewerScanner(driver: viewer, reader: IndexEncodedReader(printed: book)).scan(tabId: 34, targets: [231, 232], progress: rec.callback)
    #expect(found.map(\.printed) == [231, 232] && found.map(\.pageIndex) == [246, 247])
    #expect(await viewer.capturedIndices == [87, 246, 247])   // `await` can't sit right of `&&`: one expect per actor read
    #expect(await viewer.restoredIndex == 87)
    #expect(rec.steps == [.scrollingViewer(target: 231), .matched(printed: 231, pdfIndex: 246, method: .viewer),
                          .scrollingViewer(target: 232), .matched(printed: 232, pdfIndex: 247, method: .viewer)])
}
@Test func adjustsAcrossUnnumberedPlates() async { /* 400 pages, book(frontMatter: 16, plates: [200, 201]), target 300 → pageIndex 317; capturedIndices == [87, 315, 317] */ }
@Test func startsFromUnnumberedPage() async { /* currentIndex 3 ("iv"), target 231 → 246; capturedIndices == [3, 230, 246] */ }
@Test func givesUpAfterTwelveCaptures() async { /* reader printed: { _ in nil } → found.isEmpty; capturedIndices.count == 12; restoredIndex == 87 */ }
@Test func targetBeyondBookCostsNoCaptures() async { /* targets [999], pageCount 300 → found.isEmpty; capturedIndices == [87] */ }
@Test func restoresAfterCaptureFailure() async { /* FailingViewerDriver(info: ViewerInfo(pageCount: 300, currentIndex: 87)) → found.isEmpty; restoredIndex == 87 */ }
```

Add to `PageFinderTests.swift`:
```swift
@Test func blockedDownloadScrollsTheOpenViewer() async throws {
    let viewer = FakeViewerDriver(info: ViewerInfo(pageCount: 300, currentIndex: 87), page: { encodedPage($0) })
    let finder = PageFinder(fetcher: FakeDocumentFetcher(failure: BridgeError(code: .downloadBlocked, message: "x")), viewer: viewer,
                            cache: PDFSessionCache(directory: temporaryDirectory()), viewerReader: IndexEncodedReader(printed: TestPDF.book(frontMatter: 16)))
    let rec = StepRecorder()
    let outcome = await finder.find(PageReference(pages: [231, 232], requestedCount: 2), question: "explain pages 231-232",
                                    tab: try FixtureTabs.drive(), lastUsed: nil, preferred: nil, progress: rec.callback)
    #expect(rec.steps == [.downloading(title: "Algebra 2 Textbook.pdf"), .downloadBlocked,
                          .scrollingViewer(target: 231), .matched(printed: 231, pdfIndex: 246, method: .viewer),
                          .scrollingViewer(target: 232), .matched(printed: 232, pdfIndex: 247, method: .viewer)])
    guard case .found(let choice, let pages, let missing) = outcome else { Issue.record("\(outcome)"); return }
    #expect(choice == DocumentChoice(current: FixtureTabs.textbook, alternatives: []))
    #expect(pages.map(\.pdfIndex) == [246, 247] && pages.allSatisfy { $0.text.isEmpty } && missing.isEmpty)
    #expect(await viewer.restoredIndex == 87)
}
@Test func viewerFindsNothing() async throws { /* reader printed: { _ in nil } → .notFound(document: textbook, pages: [231, 232]); restoredIndex 87 */ }
@Test func blockedDownloadForOtherDocumentDoesNotScroll() async throws { /* drive tab (textbook) + preferred: worksheet → .failed(message: "Downloads are disabled for “Worksheet 5.2.pdf”. Open the PDF and ask again so I can scroll through it."); capturedIndices.isEmpty; no .downloadBlocked step */ }
```
- [ ] **Step 2: Run** `swift test --filter CompanionPageFinderTests` → FAIL.
- [ ] **Step 3: Implement `ViewerScanner.scan`.** Captured images are PNG; decode them to `CGImage` with ImageIO before calling `reader`. The search loop isn't pinned by the tests, so follow it as written:
```text
info = viewerInfo(tabId) (throws → return []); original = info.currentIndex; seen: [index: (image, numbers)]; budget = 12
probe(i): if i ∉ seen and budget > 0 { capture, read, budget -= 1, seen[i] = … }; return seen[i]
offset = nil; probe(original); if its numbers are non-empty, offset = (number closest to the first target) − original
for target in targets (ascending):
    progress(.scrollingViewer(target:))
    guess = target − (offset ?? 1)                         // no offset yet → assume printed = index + 1
    loop:
        if guess ∉ 0..<pageCount → target missing; break
        i = guess, or if already seen without target, the nearest unseen index guess+1, guess−1, guess+2, … within range (none → missing; break)
        r = probe(i) (nil when the budget is spent → target missing; break; a thrown capture ends the whole scan, keeping what was found)
        if r.numbers.contains(target) → record ViewerCapture(target, i, r.image); progress(.matched(printed: target, pdfIndex: i, method: .viewer)); offset = target − i; break
        if let n = r.numbers.min(by: |n − target|) → offset = n − i; guess = target − offset
        else → guess = i                                    // unnumbered page: next pass steps to a neighbour
always: try? await restore(tabId, original)                 // on every exit after viewerInfo, including thrown captures
```
  Then wire `PageFinder` for `BridgeError.downloadBlocked`. **If `tab?.drive?.file.fileId == choice.current.fileId`:** emit `.downloadBlocked`, `scan(tabId: tab.tabId, …)`, and map the results to `RenderedPage(printedLabel: "\(printed)", pdfIndex: pageIndex, image: image, text: "")` (the image passes through unchanged); no results → `.notFound(document:pages:)`, otherwise `.found(choice, pages, missing)`. **Anything else:** keep Task 11's `.failed` message.
- [ ] **Step 4: Run** `swift test --filter CompanionPageFinderTests` → PASS (including every Task 11 test unchanged).
- [ ] **Step 5: Commit** — `git commit -m "feat(pagefinder): viewer-scrolling fallback when downloads are blocked"`

### Final check
- [ ] `swift test --filter CompanionPageFinderTests` → all pass. Then `scripts/test-all.sh` → green before merging (overview rule 6).
