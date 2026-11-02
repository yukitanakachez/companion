import Testing
import AppKit
import CompanionCore
@testable import CompanionCapture

private let main = R(0, 0, 1512, 982)

@Test func dragNormalizesDirection() { #expect(RegionDrag.rect(from: P(100, 100), to: P(50, 40), screenFrame: main) == R(50, 40, 50, 60)) }
@Test func dragClampsToScreen()      { #expect(RegionDrag.rect(from: P(1400, 900), to: P(1700, 1100), screenFrame: main) == R(1400, 900, 112, 82)) }
@Test func tinyDragIsIgnored()       { #expect(RegionDrag.rect(from: P(0, 0), to: P(7, 20), screenFrame: main) == nil) }
@Test func dragRectOnNegativeXScreen() {
    #expect(RegionDrag.rect(from: P(-100, 500), to: P(-400, 300), screenFrame: R(-1920, 0, 1920, 1080)) == R(-400, 300, 300, 200))
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["COMPANION_MANUAL"] == "1")) func manualRegionSelection() async throws {
    NSApplication.shared.setActivationPolicy(.accessory)
    var result: RegionSelection?
    var finished = false
    Task { @MainActor in
        result = await RegionSelector.select()
        finished = true
    }
    while !finished {
        await Task.yield()
        while let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }
    print("selection:", result as Any)
    if let result {
        let image = try await LiveRegionCapturer(ownBundleID: "dev.local.Companion.tests", blocklist: { .starter }).capture(result)
        print("pixels:", image.pixelWidth, "x", image.pixelHeight)
    }
}
