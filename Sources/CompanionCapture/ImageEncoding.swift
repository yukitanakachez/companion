import CompanionCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageEncoding {
    static func png(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.encodingFailed }
        return output as Data
    }

    /// Returns the same image when it already fits; never upscales.
    static func downscaled(_ image: CGImage, longEdge: Int = CaptureConstants.longEdgePixels) throws -> CGImage {
        let size = ScreenGeometry.fittedPixelSize(width: image.width, height: image.height, longEdge: longEdge)
        if size.width == image.width, size.height == image.height { return image }
        guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.encodingFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let scaled = context.makeImage() else { throw CaptureError.encodingFailed }
        return scaled
    }

    static func attachment(_ image: CGImage) throws -> ImageAttachment {
        ImageAttachment(png: try png(image), pixelWidth: image.width, pixelHeight: image.height)
    }
}
