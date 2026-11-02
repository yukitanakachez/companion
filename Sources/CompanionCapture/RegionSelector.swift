import AppKit
import CoreGraphics

enum RegionDrag {
    /// Normalized and clamped to screenFrame; nil if either side is under the minimum.
    nonisolated static func rect(from start: CGPoint, to end: CGPoint, screenFrame: CGRect) -> CGRect? {
        let dragged = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                             width: abs(end.x - start.x), height: abs(end.y - start.y))
        let clamped = dragged.intersection(screenFrame)
        guard !clamped.isNull, clamped.width >= CaptureConstants.minRegionSide,
              clamped.height >= CaptureConstants.minRegionSide else { return nil }
        return clamped
    }
}

@MainActor public enum RegionSelector {
    private static var session: RegionSelectionSession?

    /// The dragged region, or nil on Esc. A call made while a selection is already open returns nil immediately.
    public static func select() async -> RegionSelection? {
        guard session == nil else { return nil }
        return await withCheckedContinuation { continuation in
            let newSession = RegionSelectionSession { selection in
                session = nil
                continuation.resume(returning: selection)
            }
            session = newSession
            newSession.begin()
        }
    }
}

@MainActor private final class RegionSelectionSession {
    private var panels: [RegionOverlayPanel] = []
    private var finish: ((RegionSelection?) -> Void)?

    init(finish: @escaping (RegionSelection?) -> Void) {
        self.finish = finish
    }

    func begin() {
        panels = NSScreen.screens.map { screen in
            RegionOverlayPanel(screen: screen, onSelect: { [weak self] rect in
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                self?.end(RegionSelection(rect: rect, displayID: number?.uint32Value ?? CGMainDisplayID()))
            }, onCancel: { [weak self] in
                self?.end(nil)
            })
        }
        guard !panels.isEmpty else { return end(nil) }
        panels.forEach { $0.orderFrontRegardless() }
        // The key panel takes Esc without activating us, so the user's app stays frontmost for capture.
        let mouse = NSEvent.mouseLocation
        (panels.first { $0.frame.contains(mouse) } ?? panels[0]).makeKey()
        NSCursor.crosshair.set()
    }

    private func end(_ selection: RegionSelection?) {
        guard let finish else { return }
        self.finish = nil
        panels.forEach { $0.orderOut(nil) }
        panels = []
        NSCursor.arrow.set()
        finish(selection)
    }
}

@MainActor private final class RegionOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init(screen: NSScreen, onSelect: @escaping (CGRect) -> Void, onCancel: @escaping () -> Void) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        backgroundColor = NSColor.black.withAlphaComponent(0.15)
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = RegionOverlayView(screenFrame: screen.frame, onSelect: onSelect, onCancel: onCancel)
        contentView = view
        initialFirstResponder = view
    }
}

@MainActor private final class RegionOverlayView: NSView {
    private let screenFrame: CGRect
    private let onSelect: (CGRect) -> Void
    private let onCancel: () -> Void
    private var dragStart: CGPoint?
    /// Global AppKit coordinates.
    private var selection: CGRect?

    init(screenFrame: CGRect, onSelect: @escaping (CGRect) -> Void, onCancel: @escaping () -> Void) {
        self.screenFrame = screenFrame
        self.onSelect = onSelect
        self.onCancel = onCancel
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel() } else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        NSCursor.crosshair.set()
        dragStart = NSEvent.mouseLocation
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        selection = RegionDrag.rect(from: dragStart, to: NSEvent.mouseLocation, screenFrame: screenFrame)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragStart else { return }
        self.dragStart = nil
        selection = nil
        needsDisplay = true
        // A drag that's too small keeps the overlay up.
        if let rect = RegionDrag.rect(from: dragStart, to: NSEvent.mouseLocation, screenFrame: screenFrame) {
            onSelect(rect)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let selection else { return }
        let local = selection.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        NSColor.clear.setFill()
        local.fill(using: .copy)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: local.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }
}
