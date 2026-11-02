import AppKit
import CompanionCore
import CompanionTestSupport
import Testing
@testable import CompanionUI

struct OrbPlacementTests {   // main/left as in BubblePlacementTests
    let home = CGPoint(x: 1473, y: 99), far = CGPoint(x: -500, y: 500)
    @Test func defaultIsBottomRightInset24() { #expect(OrbPlacement.defaultCenter(mainVisibleFrame: main.visibleFrame) == home) }
    @Test func savedPositionOnMissingDisplayFallsBack() {
        #expect(OrbPlacement.resolve(saved: far, screens: [main, left]) == far)
        #expect(OrbPlacement.resolve(saved: far, screens: [main]) == home && OrbPlacement.resolve(saved: nil, screens: [main]) == home)
    }
    @Test func dragThreshold() { #expect(!OrbPlacement.isDrag(from: .zero, to: CGPoint(x: 2, y: 2)) && OrbPlacement.isDrag(from: .zero, to: CGPoint(x: 3, y: 0))) }
}
extension WindowTests { @MainActor @Suite struct OrbControllerTests {
    let spot = CGPoint(x: 700, y: 300)
    init() { TestApp.ensure() }
    @Test func followsOrbEnabledAndSetVisible() {
        let store = FakeSettingsStore(); let c = OrbController(settings: store) {}; let p = c.panel
        defer { c.setVisible(false) }
        #expect(p.isVisible && !p.canBecomeKey && p.level == .floating && p.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary]))
        store.update { $0.orbEnabled = false }; #expect(!p.isVisible)
        store.update { $0.orbEnabled = true }; #expect(p.isVisible)
        c.setVisible(false); #expect(!p.isVisible)
    }
    @Test func clickSummonsDragSavesAndRestores() {
        let store = FakeSettingsStore(); var summons = 0; let c = OrbController(settings: store) { summons += 1 }
        defer { c.setVisible(false) }
        c.handleMouseUp(dragged: false, center: spot); #expect(summons == 1 && store.settings.orbPosition == nil)
        c.handleMouseUp(dragged: true, center: spot)
        #expect(summons == 1 && store.settings.orbPosition == spot && c.panel.frame == OrbPlacement.panelFrame(center: spot))
        let second = OrbController(settings: store) {}; defer { second.setVisible(false) }
        #expect(second.panel.frame == OrbPlacement.panelFrame(center: spot))   // a new controller starts there
    }
}}
