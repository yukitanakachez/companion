import AppKit
import Testing
@testable import CompanionUI

extension WindowTests { @MainActor @Suite struct CaptureGlowTests {
    let r1 = CGRect(x: 100, y: 100, width: 300, height: 200), r2 = CGRect(x: 500, y: 300, width: 300, height: 200)
    @Test func flashShowsClickThroughGlowThenCloses() async throws {
        TestApp.ensure(); let keyBefore = NSApp.keyWindow
        let t = ContinuousClock().measure { CaptureGlow.flash(r1) }; let p = try #require(CaptureGlow.activePanel)
        #expect(t < .milliseconds(20) && p.frame == r1.insetBy(dx: -6, dy: -6) && p.ignoresMouseEvents && !p.canBecomeKey && NSApp.keyWindow === keyBefore)
        try await Task.sleep(for: .milliseconds(900)); #expect(CaptureGlow.activePanel == nil && !p.isVisible)
        CaptureGlow.flash(.zero); #expect(CaptureGlow.activePanel == nil)   // empty rect ignored
        #expect(CaptureGlow.fadeIn == 0.08 && CaptureGlow.hold == 0.25 && CaptureGlow.fadeOut == 0.3)
    }
    @Test func rapidFlashesKeepOneGlow() async throws {
        TestApp.ensure()
        CaptureGlow.flash(r1); let first = CaptureGlow.activePanel
        try await Task.sleep(for: .milliseconds(300)); CaptureGlow.flash(r2); #expect(first?.isVisible == false)
        try await Task.sleep(for: .milliseconds(400)); #expect(CaptureGlow.activePanel?.frame == r2.insetBy(dx: -6, dy: -6))   // r1's stale timer fired
        try await Task.sleep(for: .milliseconds(400)); #expect(CaptureGlow.activePanel == nil)
    }
}}
