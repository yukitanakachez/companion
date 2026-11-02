@testable import CompanionPageFinder
import CompanionCore
import CompanionTestSupport
import CoreGraphics
import Foundation

final class CountingReader: PrintedNumberReading, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var calls: Int { lock.withLock { count } }

    func numbers(inPageImage image: CGImage) -> [Int] {
        lock.withLock { count += 1 }
        return []
    }
}

/// A unique directory path under the system temporary directory; not created.
func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("PageFinderTests-\(UUID().uuidString)")
}

final class StepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [PageFinderStep] = []

    var steps: [PageFinderStep] { lock.withLock { recorded } }
    var callback: @Sendable (PageFinderStep) -> Void {
        { step in self.lock.withLock { self.recorded.append(step) } }
    }
}

func encodedPage(_ index: Int) -> ImageAttachment {
    Fixtures.samplePNG(width: index + 1, height: 1)
}

/// Decodes the page index from the image width (see `encodedPage`) and reports what that page prints.
struct IndexEncodedReader: PrintedNumberReading {
    let printed: @Sendable (Int) -> String?

    func numbers(inPageImage image: CGImage) -> [Int] {
        printed(image.width - 1).flatMap { Int($0) }.map { [$0] } ?? []
    }
}

actor FailingViewerDriver: ViewerDriving {
    private let info: ViewerInfo
    private(set) var restoredIndex: Int?

    init(info: ViewerInfo) { self.info = info }

    func viewerInfo(tabId: Int) async throws -> ViewerInfo { info }

    func capturePage(tabId: Int, pageIndex: Int) async throws -> ImageAttachment {
        throw BridgeError(code: .timeout, message: "capture failed")
    }

    func restore(tabId: Int, pageIndex: Int) async throws { restoredIndex = pageIndex }
}
