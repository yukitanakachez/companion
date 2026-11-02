import KeyboardShortcuts
import Testing
@testable import CompanionUI

struct HotkeyManagerTests {
    @MainActor @Test func defaults() {
        #expect(KeyboardShortcuts.Name.summon.defaultShortcut == .init(.space, modifiers: [.option]))
        #expect(KeyboardShortcuts.Name.regionCapture.defaultShortcut == .init(.space, modifiers: [.option, .shift]))
    }
    @MainActor @Test func routesNamesToCallbacks() {
        var s = 0, r = 0; let m = HotkeyManager(onSummon: { s += 1 }, onRegion: { r += 1 })
        m.handle(.summon); m.handle(.regionCapture); m.handle(.regionCapture); #expect(s == 1 && r == 2)
    }
}
