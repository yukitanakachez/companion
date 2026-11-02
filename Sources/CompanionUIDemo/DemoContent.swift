import AppKit
import CompanionCore

@MainActor enum DemoContent {
    static let standardAnswer = #"""
    Reading: $x^2 - 5x + 6 = 0 \Rightarrow (x-2)(x-3) = 0$

    At 12:20 he factored it into $(x-2)(x-3)$. A product is zero only if one factor is zero, so

    $$x - 3 = 0 \quad\Longrightarrow\quad x = 3$$

    **Check:** $3^2 - 5\cdot 3 + 6 = 0$ ✓ — and renting both videos costs $5 and $6 (prices, not math).
    """#

    static var longAnswer: String {
        let paragraphs = (1...40).map { "\($0). Paragraph \($0): a streamed answer with $x_{\($0)}^2$ keeps growing, then scrolls inside the bubble." }
        let row = (1...8).map { "a_{\($0)}" }.joined(separator: " & ")
        let matrix = "$$\\begin{pmatrix}" + Array(repeating: row, count: 8).joined(separator: " \\\\ ") + "\\end{pmatrix}$$"
        let code = "```\n" + String(repeating: "0123456789", count: 20) + "\n```"
        return (paragraphs + [matrix, code]).joined(separator: "\n\n")
    }

    static let youtube = YouTubeContext(videoId: "demo", title: "Solving Quadratics by Factoring", channel: nil,
                                        chapter: "Finding the roots", playheadSeconds: 761, durationSeconds: 1450,
                                        transcriptStatus: .available, transcript: [])
    static let textbook = DriveFileRef(fileId: "textbook", title: "Algebra 2 Textbook.pdf", mimeType: "application/pdf")
    static let worksheet = DriveFileRef(fileId: "worksheet", title: "Worksheet 5.2.pdf", mimeType: "application/pdf")

    static func windowImage() -> ImageAttachment {
        draw(width: 300, height: 190, background: NSColor(white: 0.06, alpha: 1)) {
            ("x² − 5x + 6 = 0" as NSString).draw(at: CGPoint(x: 62, y: 84), withAttributes: [
                .font: NSFont(name: "Georgia", size: 20) ?? NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.white,
            ])
        }
    }

    static func page(_ label: String, pdfIndex: Int) -> RenderedPage {
        let image = draw(width: 136, height: 176, background: NSColor(white: 0.95, alpha: 1)) {
            NSColor(white: 0.8, alpha: 1).setFill()
            for row in 0..<8 { NSBezierPath(rect: CGRect(x: 12, y: 150 - row * 16, width: 112, height: 6)).fill() }
        }
        return RenderedPage(printedLabel: label, pdfIndex: pdfIndex, image: image, text: "")
    }

    private static func draw(width: Int, height: Int, background: NSColor, content: () -> Void) -> ImageAttachment {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        background.setFill()
        CGRect(x: 0, y: 0, width: width, height: height).fill()
        content()
        NSGraphicsContext.restoreGraphicsState()
        return ImageAttachment(png: rep.representation(using: .png, properties: [:]) ?? Data(), pixelWidth: width, pixelHeight: height)
    }
}
