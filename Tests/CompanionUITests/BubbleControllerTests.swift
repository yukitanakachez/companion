import AppKit
import CompanionCore
import Testing
@testable import CompanionUI

extension WindowTests { @MainActor @Suite struct BubbleControllerTests {
    let vm = BubbleViewModel(), rec = RecordingBubbleActions()
    let c: BubbleController
    init() { TestApp.ensure(); vm.actions = rec; c = BubbleController(viewModel: vm) }
    var screen: CGRect { NSScreen.screens[0].visibleFrame }

    @Test func panelFlags() {
        let p = c.panel
        #expect(p.styleMask.contains(.nonactivatingPanel) && p.isFloatingPanel && p.level == .floating)
        #expect(p.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]))
        #expect(!p.hidesOnDeactivate && p.canBecomeKey && !p.becomesKeyOnlyIfNeeded && p.animationBehavior == .none && !p.isReleasedWhenClosed)
    }
    @Test func showIsFastFocusesInputAndDoesNotActivate() {
        defer { c.hide() }
        let wasActive = NSApp.isActive
        let t = ContinuousClock().measure { c.show(cursor: CGPoint(x: screen.midX, y: screen.midY), avoiding: nil) }
        #expect(t < .milliseconds(50)); #expect(c.isVisible)
        withKnownIssue("macOS grants no key window to anyone while the screen is locked", isIntermittent: true) {
            #expect(c.panel.isKeyWindow)
        } when: { TestApp.screenIsLocked }
        #expect(c.panel.firstResponder === c.input); #expect(NSApp.isActive == wasActive)
        #expect(c.panel.frame.width == 380 && screen.contains(c.panel.frame))
    }
    @Test func commandKeysAreHandledBeforeTheMainMenu() {
        defer { c.hide() }
        c.show(cursor: CGPoint(x: screen.midX, y: screen.midY), avoiding: nil)
        #expect(c.panel.performKeyEquivalent(with: keyEvent(4, "h", [.command])))
        #expect(c.panel.performKeyEquivalent(with: keyEvent(45, "n", [.command])))
        c.panel.cancelOperation(nil)
        #expect(rec.calls == [.toggleHint, .newChat, .close])
    }
    // An accessory app's non-activating panel gets no Edit menu, so these would otherwise do nothing.
    @Test func editingShortcutsWorkWithoutAnEditMenu() {
        defer { c.hide() }
        c.show(cursor: CGPoint(x: screen.midX, y: screen.midY), avoiding: nil)
        c.input.insertText("hello", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(c.panel.performKeyEquivalent(with: keyEvent(0, "a", [.command])))
        #expect(c.input.selectedRange() == NSRange(location: 0, length: 5))
        #expect(c.panel.performKeyEquivalent(with: keyEvent(7, "x", [.command])))
        #expect(c.input.string == "" && vm.inputText == "")
        #expect(c.panel.performKeyEquivalent(with: keyEvent(9, "v", [.command])))
        #expect(c.input.string == "hello" && vm.inputText == "hello")
    }
    @Test func rapidShowHideKeepsOnePanel() {
        defer { c.hide() }
        let p = c.panel
        for i in 0..<50 { c.show(cursor: CGPoint(x: screen.minX + 300 + CGFloat(i), y: screen.midY), avoiding: nil); c.hide() }
        let last = CGPoint(x: screen.minX + 400, y: screen.midY.rounded()); c.show(cursor: last, avoiding: nil)
        #expect(c.panel === p && c.isVisible && p.alphaValue == 1)
        #expect(NSApp.windows.filter { $0 is BubblePanel && $0.isVisible }.count == 1)
        #expect(p.frame == BubblePlacement.frame(cursor: last, size: p.frame.size, screens: BubblePlacement.currentScreens(), avoid: nil))
    }
    @Test func contentGrowthClampsInsideTheScreen() {
        defer { c.hide() }
        c.show(cursor: CGPoint(x: screen.midX, y: screen.midY), avoiding: nil)
        c.contentHeightDidChange(5000); #expect(c.panel.frame.height == 520 && screen.contains(c.panel.frame))
        c.contentHeightDidChange(10);   #expect(c.panel.frame.height == 72)
    }
    // Context set while the panel is hidden (a resumed thread, chips landing first) must not open it clipped.
    @Test func showSizesToContentSetWhileHidden() {
        defer { c.hide() }
        let items = (0..<8).map { _ in ContextItem(piece: .transcriptWindow(segments: [], from: 581, to: 761)) }
        vm.setContext(CapturedContext(front: nil, privacy: .allowed, kind: .youtube, items: items, isComplete: true))
        c.show(cursor: CGPoint(x: screen.midX, y: screen.midY), avoiding: nil)
        #expect(c.panel.frame.height > 100)
    }
    @Test func contentAddedWhileVisibleResizesThePanel() {
        defer { c.hide() }
        c.show(cursor: CGPoint(x: screen.midX, y: screen.midY), avoiding: nil)
        let before = c.panel.frame.height
        let items = (0..<8).map { _ in ContextItem(piece: .transcriptWindow(segments: [], from: 581, to: 761)) }
        vm.setContext(CapturedContext(front: nil, privacy: .allowed, kind: .youtube, items: items, isComplete: true))
        for _ in 0..<30 where c.panel.frame.height == before { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        #expect(c.panel.frame.height > before)
    }
    @Test func popOutSharesTheThread() throws {
        defer { c.hide() }
        vm.resetThread([ThreadMessage(role: .user, markdown: "q")]); c.show(cursor: CGPoint(x: screen.midX, y: screen.midY), avoiding: nil)
        c.popOut(); let w = try #require(c.popOutWindow)
        #expect(!c.panel.isVisible && w.isVisible && c.isVisible && c.popOutViewModel === vm)
        #expect(w.contentRect(forFrameRect: w.frame).size == CGSize(width: 640, height: 720))
        #expect(w.contentMinSize == CGSize(width: 480, height: 400) && w.styleMask.contains(.resizable))
        c.show(cursor: .zero, avoiding: nil); #expect(!c.panel.isVisible && w.isVisible)   // show focuses the pop-out
        c.hide(); #expect(!c.isVisible && !w.isVisible)
    }
}}
