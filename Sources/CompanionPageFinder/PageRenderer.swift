import CompanionCore
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum PageRenderer {
    static let longEdge = 1500, textLimit = 8_000

    /// PNG whose long edge is exactly 1500 px; text = page.string ?? "" truncated to 8,000 characters.
    /// nil only if rasterizing fails.
    static func render(_ page: PDFPage, pdfIndex: Int, printed: Int) -> RenderedPage? {
        let size = PageRaster.displayedSize(of: page)
        let longest = max(size.width, size.height)
        guard longest > 0,
              let image = PageRaster.image(of: page, scale: CGFloat(longEdge) / longest),
              let png = encodePNG(image) else { return nil }
        return RenderedPage(printedLabel: "\(printed)", pdfIndex: pdfIndex,
                            image: ImageAttachment(png: png, pixelWidth: image.width, pixelHeight: image.height),
                            text: String((page.string ?? "").prefix(textLimit)))
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
