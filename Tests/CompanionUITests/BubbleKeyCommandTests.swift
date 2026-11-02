import AppKit
import Testing
@testable import CompanionUI

struct BubbleKeyCommandTests {
    func cmd(_ k: UInt16, _ c: String, _ m: NSEvent.ModifierFlags = []) -> BubbleKeyCommand? {
        BubbleKeyCommand.from(keyCode: k, charactersIgnoringModifiers: c, modifiers: m)
    }
    @Test func mapping() {
        #expect(cmd(36, "\r") == .submit); #expect(cmd(76, "\u{3}", [.numericPad]) == .submit)
        #expect(cmd(36, "\r", [.shift]) == .insertNewline); #expect(cmd(48, "\t") == .cycleModel); #expect(cmd(53, "\u{1b}") == .close)
        #expect(cmd(4, "h", [.command]) == .toggleHint); #expect(cmd(38, "h", [.command]) == .toggleHint)   // Dvorak position
        #expect(cmd(45, "n", [.command]) == .newChat)
        #expect(cmd(4, "h", [.command, .shift]) == nil); #expect(cmd(0, "a") == nil)
        #expect(cmd(48, "\t", [.shift]) == nil); #expect(cmd(36, "\r", [.command]) == nil)
    }
}
