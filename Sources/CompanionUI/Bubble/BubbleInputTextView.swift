import AppKit
import SwiftUI

/// An `NSTextView`, not a SwiftUI `TextField`: focus must be set synchronously in a non-activating
/// panel, and Return/Tab/Esc must be intercepted before AppKit's defaults (Esc would trigger `complete:`).
final class BubbleInputTextView: NSTextView {
    private let viewModel: BubbleViewModel

    init(viewModel: BubbleViewModel) {
        self.viewModel = viewModel
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0   // lines the caret up with the placeholder overlay
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        font = .systemFont(ofSize: 13)
        textColor = .white
        insertionPointColor = Theme.accentNS
        drawsBackground = false
        isRichText = false
        allowsUndo = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        minSize = .zero
        maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        autoresizingMask = [.width]
        textContainerInset = .zero
        typingAttributes = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `string = viewModel.inputText` when they differ.
    func syncFromViewModel() {
        if string != viewModel.inputText, !hasMarkedText() { string = viewModel.inputText }
    }

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {   // the input method owns every key during a composition
            super.keyDown(with: event)
            return
        }
        guard let command = BubbleKeyCommand.from(keyCode: event.keyCode,
                                                  charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                                                  modifiers: event.modifierFlags) else {
            super.keyDown(with: event)
            return
        }
        if command == .insertNewline {
            insertNewlineIgnoringFieldEditor(nil)
        } else {
            viewModel.handle(command)
            syncFromViewModel()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        viewModel.inputText = string
    }
}

/// Hosts a given input instance; it grows to 5 lines, then scrolls.
struct BubbleInputField: NSViewRepresentable {
    static let lineHeight: CGFloat = 17
    static let maxLines = 5

    let input: BubbleInputTextView
    let text: String      // read so SwiftUI re-runs `updateNSView` when the view model changes
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = input
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        input.syncFromViewModel()
        if let manager = input.layoutManager, let container = input.textContainer {
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container).height
            let clamped = min(max(used, Self.lineHeight), Self.lineHeight * CGFloat(Self.maxLines))
            if clamped != height { DispatchQueue.main.async { height = clamped } }
        }
    }
}
