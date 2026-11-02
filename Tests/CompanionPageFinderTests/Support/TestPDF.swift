import CoreGraphics
import CoreText
import Foundation

enum TestPDF {
    enum Band: Sendable { case header, footer }

    static let pageSize = CGSize(width: 612, height: 792)            // US Letter, points
    static let runningHead = "Quadratic Functions"                   // no digits
    static let textbookNums = "[0 << /S /r >> 16 << /S /D /St 1 >>]" // i…xvi, then 1, 2, 3…

    /// Text-layer PDF. `printed(i)` is the label printed on 0-based page i (nil → none).
    static func text(pageCount: Int, band: Band = .footer, printed: (Int) -> String?,
                     body: (Int) -> String = { "Exercise \($0 % 7 + 1): solve 3x + 42 = 0." },
                     bodyFontSize: CGFloat = 12, size: CGSize = pageSize) -> Data {
        pdf(size: size, pageCount: pageCount) { context, index in
            drawLayout(in: context, size: size, band: band, label: printed(index),
                       body: body(index), bodyFontSize: bodyFontSize)
        }
    }

    /// Same layout rasterized at 2× into a bitmap; the bitmap is the page's only content (no text layer).
    static func scanned(pageCount: Int, band: Band = .footer, printed: (Int) -> String?) -> Data {
        let size = pageSize
        return pdf(size: size, pageCount: pageCount) { context, index in
            let bitmap = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2),
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            bitmap.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            bitmap.fill(CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2))
            bitmap.scaleBy(x: 2, y: 2)
            drawLayout(in: bitmap, size: size, band: band, label: printed(index),
                       body: "Exercise \(index % 7 + 1): solve 3x + 42 = 0.", bodyFontSize: 12)
            context.draw(bitmap.makeImage()!, in: CGRect(origin: .zero, size: size))
        }
    }

    /// Lowercase roman (i, ii, …) on the first `frontMatter` pages, nil on `plates`, then 1, 2, 3… on the rest.
    static func book(frontMatter: Int, plates: Set<Int> = []) -> @Sendable (Int) -> String? {
        { index in
            if index < frontMatter { return roman(index + 1) }
            if plates.contains(index) { return nil }
            return "\(index - frontMatter + 1 - plates.count { $0 < index && $0 >= frontMatter })"
        }
    }

    private static func roman(_ value: Int) -> String {
        let table = [(100, "c"), (90, "xc"), (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var (rest, out) = (value, "")
        for (amount, glyph) in table {
            while rest >= amount { out += glyph; rest -= amount }
        }
        return out
    }

    private static func pdf(size: CGSize, pageCount: Int, draw: (CGContext, Int) -> Void) -> Data {
        let output = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        let context = CGContext(consumer: CGDataConsumer(data: output)!, mediaBox: &mediaBox, nil)!
        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            draw(context, index)
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    private static func drawLayout(in context: CGContext, size: CGSize, band: Band, label: String?,
                                   body: String, bodyFontSize: CGFloat) {
        let (w, h) = (size.width, size.height)
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        drawLine(runningHead, at: CGPoint(x: 72, y: h - 40), in: context)
        if let label {
            let width = lineWidth(label)
            let origin = band == .header ? CGPoint(x: w - 72 - width, y: h - 40) : CGPoint(x: (w - width) / 2, y: 40)
            drawLine(label, at: origin, in: context)
        }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed(body, fontSize: bodyFontSize))
        let path = CGPath(rect: CGRect(x: 72, y: 0.15 * h, width: w - 144, height: 0.7 * h), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), context)
    }

    private static func attributed(_ text: String, fontSize: CGFloat) -> CFAttributedString {
        NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, fontSize, nil),
            kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true,
        ])
    }

    private static func lineWidth(_ text: String) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed(text, fontSize: 14)), nil, nil, nil))
    }

    private static func drawLine(_ text: String, at origin: CGPoint, in context: CGContext) {
        context.textPosition = origin
        CTLineDraw(CTLineCreateWithAttributedString(attributed(text, fontSize: 14)), context)
    }
}
