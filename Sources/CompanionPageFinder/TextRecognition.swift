import CoreGraphics
import PDFKit
import Vision

protocol PrintedNumberReading: Sendable {
    /// Standalone integers read in the top and bottom 12% of a full-page image (header first).
    func numbers(inPageImage image: CGImage) -> [Int]
}

struct VisionNumberReader: PrintedNumberReading {
    init() {}

    func numbers(inPageImage image: CGImage) -> [Int] {
        // Recognize each band separately, not the whole page: on a full-page image Vision's default
        // minimumTextHeight (1/32 of the image height) drops 14-pt page numbers.
        let bandHeight = Int((CGFloat(image.height) * PrintedNumbers.bandFraction).rounded())
        let header = CGRect(x: 0, y: 0, width: image.width, height: bandHeight)        // CGImage rows run top-down
        let footer = CGRect(x: 0, y: image.height - bandHeight, width: image.width, height: bandHeight)
        return [header, footer].flatMap { rect -> [Int] in
            image.cropping(to: rect).map(recognize) ?? []
        }
    }

    private func recognize(_ band: CGImage) -> [Int] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: band, options: [:]).perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).flatMap { observation in
            PrintedNumbers.integers(in: observation.topCandidates(1).first?.string ?? "")
        }
    }
}

enum PageRaster {
    /// White-filled sRGB bitmap of the page's crop box at `scale` px per point (honours page.rotation).
    static func image(of page: PDFPage, scale: CGFloat) -> CGImage? {
        let size = displayedSize(of: page)
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    /// The crop box as displayed, i.e. with width and height swapped on a page rotated by 90 or 270 degrees.
    static func displayedSize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox).size
        return page.rotation % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
    }
}
