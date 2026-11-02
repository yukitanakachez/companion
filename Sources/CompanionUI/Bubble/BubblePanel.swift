import AppKit

/// Key handling shared by the panel and the pop-out window. An accessory app has no main menu to
/// lean on: ⌘H must toggle hints rather than hide the app, and the Edit shortcuts need routing here.
@MainActor enum BubbleWindowKeys {
    static func performKeyEquivalent(_ event: NSEvent, in window: NSWindow, viewModel: BubbleViewModel) -> Bool {
        let responder = window.firstResponder
        if (responder as? NSTextView)?.hasMarkedText() == true { return false }   // the input method owns every key
        if let command = BubbleKeyCommand.from(keyCode: event.keyCode,
                                               charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                                               modifiers: event.modifierFlags),
           command == .toggleHint || command == .newChat {
            return viewModel.handle(command)
        }
        guard let action = editAction(event), let responder else { return false }
        return responder.tryToPerform(action, with: nil)
    }

    private static func editAction(_ event: NSEvent) -> Selector? {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (mods, event.charactersIgnoringModifiers?.lowercased()) {
        case ([.command], "x"): return #selector(NSText.cut(_:))
        case ([.command], "c"): return #selector(NSText.copy(_:))
        case ([.command], "v"): return #selector(NSText.paste(_:))
        case ([.command], "a"): return #selector(NSText.selectAll(_:))
        case ([.command], "z"): return Selector(("undo:"))
        case ([.command, .shift], "z"): return Selector(("redo:"))
        default: return nil
        }
    }
}

/// The single non-activating bubble panel: takes keys while the front app stays active.
/// Its style mask is set here and never mutated.
final class BubblePanel: NSPanel {
    private let viewModel: BubbleViewModel

    init(viewModel: BubbleViewModel) {
        self.viewModel = viewModel
        super.init(contentRect: CGRect(x: 0, y: 0, width: BubbleMetrics.width, height: BubbleMetrics.minHeight),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        BubbleWindowKeys.performKeyEquivalent(event, in: self, viewModel: viewModel) || super.performKeyEquivalent(with: event)
    }

    /// Esc when the input isn't focused.
    override func cancelOperation(_ sender: Any?) {
        viewModel.handle(.close)
    }
}
