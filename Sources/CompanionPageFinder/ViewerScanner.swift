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
    /// Once the offset is known, unnumbered pages tried for one target before calling it missing,
    /// so back matter can't starve the targets after it.
    static let maxUnnumberedSteps = 5

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
        var probes = Probes(driver: driver, reader: reader, tabId: tabId, pageCount: info.pageCount)
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
            var unnumberedSteps = 0

            func record(_ index: Int, _ image: ImageAttachment) {
                found.append(ViewerCapture(printed: target, pageIndex: index, image: image))
                progress(.matched(printed: target, pdfIndex: index, method: .viewer))
                offset = target - index
            }

            while (0..<info.pageCount).contains(guess) {
                if let (index, image) = probes.unnumberedPage(between: target) {
                    record(index, image)
                    break
                }
                if probes.isBracketed(target) { break }
                guard let index = probes.nextIndex(for: target, guess: guess),
                      let page = try await probes.probe(index) else { break }
                if page.numbers.contains(target) {
                    record(index, page.image)
                    break
                }
                if let closest = page.numbers.closest(to: target) {
                    offset = closest - index
                    guess = target - closest + index
                } else {
                    guess = index                   // unnumbered page: the next pass steps to a neighbour
                    if offset != nil {
                        unnumberedSteps += 1
                        if unnumberedSteps >= Self.maxUnnumberedSteps { break }
                    }
                }
            }
        }
    }
}

/// The captures made so far, and the budget left for more.
private struct Probes {
    struct Page {
        var image: ImageAttachment
        /// What this page's page number could be. A page printing several numbers keeps only those that continue
        /// on a neighbour, since a running head's chapter number doesn't.
        var numbers: [Int]
    }

    let driver: any ViewerDriving
    let reader: any PrintedNumberReading
    let tabId: Int
    let pageCount: Int
    private var captured: [Int: (image: ImageAttachment, numbers: [Int])] = [:]
    private var pages: [Int: Page] = [:]
    private var budget = ViewerScanner.maxCaptures

    init(driver: any ViewerDriving, reader: any PrintedNumberReading, tabId: Int, pageCount: Int) {
        self.driver = driver
        self.reader = reader
        self.tabId = tabId
        self.pageCount = pageCount
    }

    /// The page at `index`, capturing it if needed; nil when it is unseen and the budget is spent.
    mutating func probe(_ index: Int) async throws -> Page? {
        if let page = pages[index] { return page }
        guard let raw = try await capture(index) else { return nil }
        var numbers = raw.numbers
        if numbers.count > 1 {
            let step = index + 1 < pageCount ? 1 : -1
            let neighbour = try await capture(index + step)?.numbers ?? []
            numbers = numbers.filter { neighbour.contains($0 + step) }
        }
        let page = Page(image: raw.image, numbers: numbers)
        pages[index] = page
        return page
    }

    private mutating func capture(_ index: Int) async throws -> (image: ImageAttachment, numbers: [Int])? {
        if let raw = captured[index] { return raw }
        guard budget > 0, (0..<pageCount).contains(index) else { return nil }
        budget -= 1
        let image = try await driver.capturePage(tabId: tabId, pageIndex: index)
        let raw = (image: image, numbers: decode(image).map(reader.numbers(inPageImage:)) ?? [])
        captured[index] = raw
        return raw
    }

    /// `guess`, or if it was already examined without `target`, the nearest unexamined index guess+1, guess−1, guess+2, …
    func nextIndex(for target: Int, guess: Int) -> Int? {
        guard let page = pages[guess], !page.numbers.contains(target) else { return guess }
        for distance in 1..<max(pageCount, 1) {
            for index in [guess + distance, guess - distance]
            where (0..<pageCount).contains(index) && pages[index] == nil {
                return index
            }
        }
        return nil
    }

    /// An examined unnumbered page whose neighbours print target − 1 and target + 1: a chapter opener.
    func unnumberedPage(between target: Int) -> (index: Int, image: ImageAttachment)? {
        for (index, page) in pages where page.numbers.isEmpty {
            if pages[index - 1]?.numbers.contains(target - 1) == true,
               pages[index + 1]?.numbers.contains(target + 1) == true {
                return (index, page.image)
            }
        }
        return nil
    }

    /// True when examined pages print numbers either side of `target` with only examined, target-less pages
    /// between them: no further capture can find it.
    func isBracketed(_ target: Int) -> Bool {
        let numbered = pages.filter { !$0.value.numbers.isEmpty }.keys.sorted()
        for (lower, upper) in zip(numbered, numbered.dropFirst()) {
            guard let below = pages[lower]?.numbers.closest(to: target), below < target,
                  let above = pages[upper]?.numbers.closest(to: target), above > target else { continue }
            if (lower...upper).allSatisfy({ pages[$0] != nil }) { return true }
        }
        return false
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
