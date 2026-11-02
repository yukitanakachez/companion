import AppKit
import SwiftUI

private final class PopOutWindow: NSWindow {
    var viewModel: BubbleViewModel?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let viewModel, BubbleWindowKeys.performKeyEquivalent(event, in: self, viewModel: viewModel) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        viewModel?.handle(.close)
    }
}

/// The larger window the thread moves into. Same view model; its own input and answer controller.
@MainActor final class PopOutWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let input: BubbleInputTextView
    let viewModel: BubbleViewModel
    private let answer = AnswerWebController()

    init(viewModel: BubbleViewModel) {
        self.viewModel = viewModel
        input = BubbleInputTextView(viewModel: viewModel)
        let popOut = PopOutWindow(contentRect: CGRect(origin: .zero, size: BubbleMetrics.popOutSize),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
        popOut.viewModel = viewModel
        window = popOut
        super.init()
        window.title = "Companion"
        window.contentMinSize = BubbleMetrics.popOutMinSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: BubbleView(viewModel: viewModel, answer: answer, input: input, style: .window,
                                                                onPopOut: {}, onContentHeight: { _ in }))
    }

    func show(centeredIn visibleFrame: CGRect?) {
        if let visibleFrame {
            let size = window.frame.size
            window.setFrameOrigin(CGPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
        focus()
    }

    func focus() {
        input.syncFromViewModel()
        window.makeFirstResponder(input)
    }

    /// Red button: the coordinator hears `bubbleDidClose`, exactly as for Esc.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        viewModel.close()
        return true
    }
}
