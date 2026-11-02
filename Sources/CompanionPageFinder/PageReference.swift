import Foundation

public struct PageReference: Equatable, Sendable {
    /// Sorted, unique, at most `PageReferenceParser.maxPages`.
    public var pages: [Int]
    /// The count before the cap (`> pages.count` means it was capped).
    public var requestedCount: Int

    public init(pages: [Int], requestedCount: Int) {
        self.pages = pages
        self.requestedCount = requestedCount
    }
}

public enum PageReferenceParser {
    public static let maxPages = 10

    private static let number = #"\d{1,4}(?![\p{L}\p{N}])"#
    private static let rangeTail = #"\s*[-–—]\s*"#
    private static let wordTail = #"\s+(?:to|through|thru)\s+"#

    /// keyword, then a list of ranges/numbers. A separator is consumed only when a number follows it.
    private static let reference: NSRegularExpression = {
        let item = "\(number)(?:\(rangeTail)\(number)|\(wordTail)\(number))?"
        let separator = #"\s*(?:,\s*and|,|&|and)\s*"#
        // A bare "p" with no dot is usually a variable (p1 = 5, p2 + 3p), so it needs a page-sized number
        // that isn't the start of an equation.
        let barePage = #"p\s*(?=\d{3,4}(?![\p{L}\p{N}])(?!\s*[=+*/^<>]))"#
        let keyword = #"(?<![\p{L}\p{N}])(?:(?:(?:pages|page|pgs|pg|pp)\.?|p\.)\s*|"# + barePage + ")"
        return try! NSRegularExpression(pattern: "\(keyword)\(item)(?:\(separator)\(item))*",
                                        options: [.caseInsensitive])
    }()

    /// One list item; capture 1 is the start, capture 2 or 3 the end of a range.
    private static let item: NSRegularExpression = {
        let pattern = "(\(number))(?:\(rangeTail)(\(number))|\(wordTail)(\(number)))?"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    public static func parse(_ question: String) -> PageReference? {
        var pages = Set<Int>()
        let whole = NSRange(question.startIndex..., in: question)
        for match in reference.matches(in: question, range: whole) {
            for found in item.matches(in: question, range: match.range) {
                guard let start = text(of: found, group: 1, in: question) else { continue }
                let end = text(of: found, group: 2, in: question) ?? text(of: found, group: 3, in: question)
                pages.formUnion(expand(start: start, end: end))
            }
        }
        guard !pages.isEmpty else { return nil }
        let sorted = pages.sorted()
        return PageReference(pages: Array(sorted.prefix(maxPages)), requestedCount: sorted.count)
    }

    private static func text(of match: NSTextCheckingResult, group: Int, in question: String) -> String? {
        Range(match.range(at: group), in: question).map { String(question[$0]) }
    }

    private static func expand(start: String, end: String?) -> [Int] {
        guard let a = Int(start), valid.contains(a) else { return [] }
        guard let end, var b = Int(end) else { return [a] }
        // An abbreviated end borrows the start's leading digits: 231-35 → 231-235.
        if b < a, end.count < start.count {
            b = Int(start.prefix(start.count - end.count) + end) ?? b
        }
        guard valid.contains(b) else { return [] }
        return Array(min(a, b)...max(a, b))
    }

    private static let valid = 1...9999
}
