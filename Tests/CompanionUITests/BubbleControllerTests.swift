import AppKit
import CompanionCore
import CompanionTestSupport
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
    // Spec 5.1: capture and AX read the front app right after a summon, so it must stay frontmost.
    // NSApp.isActive can't check that: it goes true when this panel becomes key and false when it
    // hides, while NSRunningApplication.current.isActive and the frontmost app don't change, bundled
    // or not. Only "not us" is asserted, because a person can switch apps during the test.
    @Test func showIsFastFocusesInputAndDoesNotActivate() {
        defer { c.hide() }
        let t = ContinuousClock().measure { c.show(cursor: CGPoint(x: screen.midX, y: screen.midY), avoiding: nil) }
        #expect(t < .milliseconds(50)); #expect(c.isVisible)
        withKnownIssue("macOS grants no key window to anyone while the screen is locked", isIntermittent: true) {
            #expect(c.panel.isKeyWindow)
        } when: { TestApp.screenIsLocked }
        #expect(c.panel.firstResponder === c.input)
        #expect(c.panel.frame.width == 380 && screen.contains(c.panel.frame))
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))   // activation is asynchronous; long enough to see one land
        #expect(NSWorkspace.shared.frontmostApplication != NSRunningApplication.current)
        #expect(!NSRunningApplication.current.isActive)
    }
    // windowNumber 0 leaves routing to NSApp, which sends the key to whichever window is key.
    @Test func keysRoutedByTheAppReachTheInput() {
        defer { c.hide() }
        c.show(cursor: CGPoint(x: screen.midX, y: screen.midY), avoiding: nil)
        NSApp.sendEvent(keyEvent(12, "q"))
        withKnownIssue("macOS grants no key window to anyone while the screen is locked", isIntermittent: true) {
            #expect(c.input.string == "q" && vm.inputText == "q")
        } when: { TestApp.screenIsLocked }
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
    @Test func aDragSticksThroughHeightChangesUntilTheNextShow() {
        defer { c.hide() }
        let cursor = CGPoint(x: screen.midX.rounded(), y: screen.midY.rounded())
        c.show(cursor: cursor, avoiding: nil)
        let top = screen.maxY - 40
        c.panel.setFrameOrigin(CGPoint(x: screen.minX + 20, y: top - c.panel.frame.height))   // what a drag does
        c.contentHeightDidChange(300)
        #expect(c.panel.frame.minX == screen.minX + 20 && c.panel.frame.maxY == top && c.panel.frame.height == 300)
        c.contentHeightDidChange(400)
        #expect(c.panel.frame.minX == screen.minX + 20 && c.panel.frame.maxY == top && c.panel.frame.height == 400)
        c.hide()
        c.show(cursor: cursor, avoiding: nil)
        #expect(c.panel.frame == BubblePlacement.frame(cursor: cursor, size: c.panel.frame.size, screens: BubblePlacement.currentScreens(), avoid: nil))
    }
    // Hosting can swallow clicks, so this asks AppKit what a mouse-down at each spot would actually reach.
    @Test func emptyPartsOfTheBubbleReachTheDragAreaAndTheInputDoesNot() throws {
        defer { c.hide() }
        vm.setModelName("Haiku 4.5")
        c.show(cursor: CGPoint(x: screen.midX, y: screen.midY), avoiding: nil)
        let content = try #require(c.panel.contentView)
        content.layoutSubtreeIfNeeded()
        let hit = { (p: CGPoint) in content.superview?.hitTest(content.convert(p, to: content.superview)) ?? content.hitTest(p) }
        let bounds = content.bounds
        #expect(hit(CGPoint(x: 4, y: 4)) is BubbleDragArea)                                 // chrome corner
        #expect(hit(CGPoint(x: bounds.midX, y: bounds.maxY - 4)) is BubbleDragArea)          // chrome top or bottom edge
        let footerY = content.isFlipped ? bounds.maxY - 18 : 18
        #expect(hit(CGPoint(x: 40, y: footerY)) is BubbleDragArea)                           // the footer's text
        let inputPoint = c.input.convert(CGPoint(x: 5, y: 5), to: content)
        #expect(hit(inputPoint) === c.input)
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
    @Test func summonActivatesForAnOpenPopOutAndHideGivesFocusBack() {
        var activations = 0, restores = 0
        c.focusHooks = BubbleFocusHooks(activate: { activations += 1 }, captureFrontmost: { { restores += 1 } })
        c.show(cursor: CGPoint(x: screen.midX, y: screen.midY), avoiding: nil)
        c.popOut(); #expect(activations == 1 && restores == 0)
        c.show(cursor: .zero, avoiding: nil); #expect(activations == 2)
        c.focusInput(); #expect(activations == 3)
        c.hide(); #expect(restores == 1)
        c.hide(); #expect(restores == 1)
    }
    @Test func hidingTheBubbleAloneTouchesNoFocus() {
        var restores = 0
        c.focusHooks = BubbleFocusHooks(activate: {}, captureFrontmost: { { restores += 1 } })
        c.show(cursor: CGPoint(x: screen.midX, y: screen.midY), avoiding: nil); c.hide()
        #expect(restores == 0)
    }
    @Test func tenPageThumbnailsAllFit() {
        let page = { (i: Int) in RenderedPage(printedLabel: "\(i)", pdfIndex: i, image: Fixtures.samplePNG(), text: "") }
        let one = BubbleViewModel(); one.setPageThumbnails([page(1)])
        let oneController = BubbleController(viewModel: one); oneController.show(cursor: CGPoint(x: screen.midX, y: screen.midY), avoiding: nil)
        let single = oneController.panel.frame.height; oneController.hide()
        vm.setPageThumbnails((1...10).map(page)); c.show(cursor: CGPoint(x: screen.midX, y: screen.midY), avoiding: nil); defer { c.hide() }
        #expect(c.panel.frame.height > single)   // the tenth wraps instead of clipping
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
