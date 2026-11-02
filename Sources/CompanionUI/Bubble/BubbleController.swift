import AppKit
import SwiftUI

/// Owns the bubble panel, built once here and reused for every summon.
@MainActor public final class BubbleController {
    let panel: BubblePanel
    let input: BubbleInputTextView
    private let viewModel: BubbleViewModel
    private let answer = AnswerWebController()
    private var popOutController: PopOutWindowController?
    private var lastContentHeight = BubbleMetrics.minHeight
    private var lastCursor: CGPoint = .zero

    var popOutWindow: NSWindow? { popOutController?.window }
    var popOutViewModel: BubbleViewModel? { popOutController?.viewModel }

    /// Builds the panel and pre-loads the answer web view, so the first `show` pays no start-up.
    public init(viewModel: BubbleViewModel) {
        self.viewModel = viewModel
        panel = BubblePanel(viewModel: viewModel)
        input = BubbleInputTextView(viewModel: viewModel)
        var popOutAction: () -> Void = {}
        var heightAction: (CGFloat) -> Void = { _ in }
        let hosting = NSHostingView(rootView: BubbleView(viewModel: viewModel, answer: answer, input: input, style: .bubble,
                                                         onPopOut: { popOutAction() }, onContentHeight: { heightAction($0) }))
        hosting.sizingOptions = []   // SwiftUI never resizes the panel
        panel.contentView = hosting
        popOutAction = { [weak self] in self?.popOut() }
        heightAction = { [weak self] in self?.contentHeightDidChange($0) }
        hosting.layoutSubtreeIfNeeded()   // puts the input in the window before the first `show`
    }

    /// True while the panel or the pop-out window is on screen.
    public var isVisible: Bool { panel.isVisible || (popOutWindow?.isVisible ?? false) }

    /// Positions, shows and focuses the bubble without activating the app; returns in < 50 ms.
    /// Calling it while visible repositions. If the pop-out window is open it is brought forward
    /// and focused instead, and the panel stays hidden.
    public func show(cursor: NSPoint, avoiding: CGRect?) {
        if let popOutController, popOutController.window.isVisible {
            popOutController.window.makeKeyAndOrderFront(nil)
            popOutController.focus()
            return
        }
        lastCursor = cursor
        let size = CGSize(width: BubbleMetrics.width, height: BubbleMetrics.clampedHeight(lastContentHeight))
        panel.setFrame(BubblePlacement.frame(cursor: cursor, size: size, screens: BubblePlacement.currentScreens(), avoid: avoiding),
                       display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()
        focusPanelInput()
    }

    /// Focuses the input of whichever window is visible.
    public func focusInput() {
        if let popOutController, popOutController.window.isVisible {
            popOutController.focus()
        } else if panel.isVisible {
            panel.makeKey()
            focusPanelInput()
        }
    }

    /// Orders the panel out and closes the pop-out; idempotent. The bubble never hides itself on
    /// Esc: `bubbleDidClose` is the signal, and the coordinator calls this.
    public func hide() {
        panel.orderOut(nil)
        popOutWindow?.close()
    }

    /// Moves the thread into the larger window. No-op unless the panel is visible.
    public func popOut() {
        guard panel.isVisible else { return }
        let visibleFrame = BubblePlacement.screen(for: CGPoint(x: panel.frame.midX, y: panel.frame.midY),
                                                  in: BubblePlacement.currentScreens())?.visibleFrame
        panel.orderOut(nil)
        let controller = popOutController ?? PopOutWindowController(viewModel: viewModel)
        popOutController = controller
        controller.show(centeredIn: visibleFrame)
    }

    /// Resizes the panel to its content, keeping the edge nearest the cursor fixed.
    func contentHeightDidChange(_ height: CGFloat) {
        lastContentHeight = height
        guard panel.isVisible else { return }
        let target = BubbleMetrics.clampedHeight(height)
        let screens = BubblePlacement.currentScreens()
        guard let visible = (BubblePlacement.screen(for: lastCursor, in: screens) ?? screens.first)?.visibleFrame else { return }
        let frame = BubblePlacement.resized(panel.frame, toHeight: target, anchorTop: panel.frame.maxY <= lastCursor.y, visibleFrame: visible)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private func focusPanelInput() {
        input.syncFromViewModel()
        panel.makeFirstResponder(input)
    }
}
