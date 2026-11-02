@testable import CompanionPageFinder
import Testing

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
func ignoresNonReferences(_ question: String) {
    #expect(PageReferenceParser.parse(question) == nil)
}

@Test func capsAtTenPages() {
    #expect(PageReferenceParser.parse("pages 500-520") == PageReference(pages: Array(500...509), requestedCount: 21))
}

@Test func abbreviatedRangeEnd() {
    #expect(PageReferenceParser.parse("pp. 231-35")?.pages == [231, 232, 233, 234, 235])
    #expect(PageReferenceParser.parse("pages 98-102")?.pages == [98, 99, 100, 101, 102])
}
