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
