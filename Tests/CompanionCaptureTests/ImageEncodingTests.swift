import Testing
import CoreGraphics
@testable import CompanionCapture

func makeImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

@Test func downscalesAndEncodesPNG() throws {
    let a = try ImageEncoding.attachment(ImageEncoding.downscaled(makeImage(width: 3000, height: 2000)))
    #expect(Array(a.png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47] && a.pixelWidth == 1500 && a.pixelHeight == 1000)
    #expect(try ImageEncoding.downscaled(makeImage(width: 800, height: 600)).width == 800)
}
