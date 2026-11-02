import CoreGraphics
import Foundation
import PDFKit

enum PrintedNumbers {
    static let bandFraction: CGFloat = 0.12

    private static let standalone = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}.,/\-])[1-9]\d{0,3}(?![\p{L}\p{N}.,/\-])"#)

    /// Standalone integers in 1...9999, in order of appearance: no leading zero, and not adjacent to a letter,
    /// a digit, or one of . , / -   ("2-14", "3.5", "1/2", "p231", "12th" yield nothing).
    static func integers(in text: String) -> [Int] {
        standalone.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).flatMap { Int(text[$0]) }
        }
    }

    /// [header, footer]; origin bottom-left (PDF space).
    static func bands(of rect: CGRect) -> [CGRect] {
        let height = rect.height * bandFraction
        return [CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height),
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)]
    }

    /// [displayed header, displayed footer] in unrotated page space, which is where PDFKit selections work.
    static func bands(of rect: CGRect, rotation: Int) -> [CGRect] {
        let width = rect.width * bandFraction
        let left = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        let right = CGRect(x: rect.maxX - width, y: rect.minY, width: width, height: rect.height)
        switch ((rotation % 360) + 360) % 360 {
        case 90: return [left, right]
        case 180: return Array(bands(of: rect).reversed())
        case 270: return [right, left]
        default: return bands(of: rect)
        }
    }

    /// Integers in the page's displayed header, then footer, read from the text layer.
    static func textLayerNumbers(on page: PDFPage) -> [Int] {
        bands(of: page.bounds(for: .cropBox), rotation: page.rotation).flatMap { band in
            integers(in: page.selection(for: band)?.string ?? "")
        }
    }

    static func hasTextLayer(_ page: PDFPage) -> Bool {
        page.string?.contains { !$0.isWhitespace } ?? false
    }
}
