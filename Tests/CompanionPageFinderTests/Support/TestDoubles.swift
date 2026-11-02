@testable import CompanionPageFinder
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
