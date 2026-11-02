import CompanionCore
import CoreGraphics
import Foundation
import ImageIO

struct ViewerCapture: Sendable, Equatable {
    var printed: Int
    var pageIndex: Int
    var image: ImageAttachment
}

/// Finds printed pages by driving the Drive viewer, for when the download is blocked.
struct ViewerScanner: Sendable {
    static let maxCaptures = 12

    private let driver: any ViewerDriving
    private let reader: any PrintedNumberReading

    init(driver: any ViewerDriving, reader: any PrintedNumberReading = VisionNumberReader()) {
        self.driver = driver
        self.reader = reader
    }

    /// Restores the viewer to its starting index before returning (also after a thrown capture); [] if viewerInfo fails.
    /// The 12-capture budget is per scan, not per target.
    func scan(tabId: Int, targets: [Int], progress: @Sendable (PageFinderStep) -> Void) async -> [ViewerCapture] {
        guard let info = try? await driver.viewerInfo(tabId: tabId) else { return [] }
        var found: [ViewerCapture] = []
        var probes = Probes(driver: driver, reader: reader, tabId: tabId)
        do {
            try await search(targets, info: info, probes: &probes, found: &found, progress: progress)
        } catch {
            // A failed capture ends the scan, keeping what was found.
        }
        try? await driver.restore(tabId: tabId, pageIndex: info.currentIndex)
        return found
    }

    private func search(_ targets: [Int], info: ViewerInfo, probes: inout Probes, found: inout [ViewerCapture],
                        progress: @Sendable (PageFinderStep) -> Void) async throws {
        guard let first = targets.first else { return }
        var offset: Int?
        if let numbers = try await probes.probe(info.currentIndex)?.numbers, let closest = numbers.closest(to: first) {
            offset = closest - info.currentIndex
        }
        for target in targets {
            progress(.scrollingViewer(target: target))
            var guess = target - (offset ?? 1)      // no offset yet → assume printed = index + 1
            while (0..<info.pageCount).contains(guess),
                  let index = probes.nextIndex(for: target, guess: guess, pageCount: info.pageCount),
                  let page = try await probes.probe(index) {
                if page.numbers.contains(target) {
                    found.append(ViewerCapture(printed: target, pageIndex: index, image: page.image))
                    progress(.matched(printed: target, pdfIndex: index, method: .viewer))
                    offset = target - index
                    break
                }
                if let closest = page.numbers.closest(to: target) {
                    offset = closest - index
                    guess = target - closest + index
                } else {
                    guess = index                   // unnumbered page: the next pass steps to a neighbour
                }
            }
        }
    }
}

/// The captures made so far, and the budget left for more.
private struct Probes {
    struct Page {
        var image: ImageAttachment
        var numbers: [Int]
    }

    let driver: any ViewerDriving
    let reader: any PrintedNumberReading
    let tabId: Int
    private var seen: [Int: Page] = [:]
    private var budget = ViewerScanner.maxCaptures

    init(driver: any ViewerDriving, reader: any PrintedNumberReading, tabId: Int) {
        self.driver = driver
        self.reader = reader
        self.tabId = tabId
    }

    /// The page at `index`, capturing it if needed; nil when it is unseen and the budget is spent.
    mutating func probe(_ index: Int) async throws -> Page? {
        if let page = seen[index] { return page }
        guard budget > 0 else { return nil }
        budget -= 1
        let image = try await driver.capturePage(tabId: tabId, pageIndex: index)
        let numbers = decode(image).map(reader.numbers(inPageImage:)) ?? []
        let page = Page(image: image, numbers: numbers)
        seen[index] = page
        return page
    }

    /// `guess`, or if it was already seen without `target`, the nearest unseen index guess+1, guess−1, guess+2, …
    func nextIndex(for target: Int, guess: Int, pageCount: Int) -> Int? {
        guard let page = seen[guess], !page.numbers.contains(target) else { return guess }
        for distance in 1..<max(pageCount, 1) {
            for index in [guess + distance, guess - distance]
            where (0..<pageCount).contains(index) && seen[index] == nil {
                return index
            }
        }
        return nil
    }

    private func decode(_ image: ImageAttachment) -> CGImage? {
        CGImageSourceCreateWithData(image.png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
}

private extension [Int] {
    func closest(to target: Int) -> Int? {
        self.min { abs($0 - target) < abs($1 - target) }
    }
}
