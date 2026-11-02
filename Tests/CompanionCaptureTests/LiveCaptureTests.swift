import Testing
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit
import CompanionCore
@testable import CompanionCapture

@Test func capturersThrowWithoutPermissionBeforeTouchingSCK() async {
    await #expect(throws: CaptureError.permissionDenied) {
        try await LiveWindowCapturer(hasPermission: { false }).captureFrontWindow(pid: getpid(), focusedFrame: nil) }
    await #expect(throws: CaptureError.permissionDenied) {
        try await LiveRegionCapturer(ownBundleID: "x", blocklist: { .starter }, hasPermission: { false })
            .capture(RegionSelection(rect: R(0, 0, 50, 50), displayID: CGMainDisplayID())) }
}
@Test func regionExclusionIncludesOwnAndBlockedApps() {
    #expect(RegionExclusion.bundleIDsToExclude(running: ["dev.local.Companion", "com.1password.1password", "com.google.Chrome"],
                                               ownBundleID: "dev.local.Companion", config: .starter)
            == ["dev.local.Companion", "com.1password.1password"])
}
@Test func regionExclusionIgnoresBundleIDCase() {
    #expect(RegionExclusion.bundleIDsToExclude(running: ["COM.1Password.1PASSWORD"], ownBundleID: "x", config: .starter)
            == ["COM.1Password.1PASSWORD"])
}
@Test(.enabled(if: CGPreflightScreenCaptureAccess())) func liveWindowCaptureProducesDownscaledPNG() async throws {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let candidates = content.windows.filter {
            $0.windowLayer == 0 && $0.frame.width >= 200 && $0.frame.height >= 200
                && ($0.owningApplication?.processID ?? getpid()) != getpid()
        }
        guard let window = candidates.first, let pid = window.owningApplication?.processID else { return }
        let largest = candidates.filter { $0.owningApplication?.processID == pid }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }!
        let a = try await LiveWindowCapturer().captureFrontWindow(pid: pid, focusedFrame: nil)
        #expect(Array(a.png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        #expect(max(a.pixelWidth, a.pixelHeight) <= 1500)
        let aspect = Double(a.pixelWidth) / Double(a.pixelHeight), expected = largest.frame.width / largest.frame.height
        #expect(abs(aspect - expected) / expected < 0.02)
    } catch let error as SCStreamError where error.code == .userDeclined {
        return    // a pending re-prompt
    }
}
@Test(.enabled(if: CGPreflightScreenCaptureAccess())) func liveRegionCaptureOfMainDisplay() async throws {
    do {
        let a = try await LiveRegionCapturer(ownBundleID: "dev.local.Companion.tests", blocklist: { .starter })
            .capture(RegionSelection(rect: R(100, 100, 300, 200), displayID: CGMainDisplayID()))
        #expect(Array(a.png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        #expect(abs(Double(a.pixelWidth) / Double(a.pixelHeight) - 1.5) < 0.02)
    } catch let error as SCStreamError where error.code == .userDeclined {
        return
    }
}
