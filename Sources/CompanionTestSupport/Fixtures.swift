import CompanionCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum Fixtures {
    /// `contracts/` at the repository root, resolved from this source file's location.
    public static var contractsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CompanionTestSupport
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("contracts")
    }

    private static var fixturesDirectory: URL {
        contractsDirectory.appendingPathComponent("fixtures")
    }

    public static func bridgeFixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixturesDirectory.appendingPathComponent(name))
    }

    /// Sorted `*.json` file names in `contracts/fixtures`.
    public static func allBridgeFixtureNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixturesDirectory.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
    }

    /// A real PNG of the given size, encoded with ImageIO.
    public static func samplePNG(width: Int = 4, height: Int = 3) -> ImageAttachment {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return ImageAttachment(png: output as Data, pixelWidth: width, pixelHeight: height)
    }
}
