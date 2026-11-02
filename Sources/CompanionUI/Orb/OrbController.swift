import AppKit
import CompanionCore

private final class OrbPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The small always-on-top orb. Visible while `AppSettings.orbEnabled` and `setVisible(true)` both hold.
@MainActor public final class OrbController {
    let panel: NSPanel
    private let settings: any SettingsStoring
    private let onSummon: @MainActor () -> Void
    private var requested = true

    public init(settings: any SettingsStoring, onSummon: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.onSummon = onSummon
        let center = OrbPlacement.resolve(saved: settings.settings.orbPosition, screens: BubblePlacement.currentScreens())
        panel = OrbPanel(contentRect: OrbPlacement.panelFrame(center: center), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let side = OrbPlacement.panelSize
        panel.contentView = OrbView(frame: CGRect(x: 0, y: 0, width: side, height: side)) { [weak self] dragged, center in
            self?.handleMouseUp(dragged: dragged, center: center)
        }
        settings.addObserver { [weak self] in self?.apply($0) }
        apply(settings.settings)
    }

    public func setVisible(_ visible: Bool) {
        requested = visible
        apply(settings.settings)
    }

    /// Click → summon. Drag → snap back if dropped off every display, then save the center.
    func handleMouseUp(dragged: Bool, center: CGPoint) {
        guard dragged else {
            onSummon()
            return
        }
        let resolved = OrbPlacement.resolve(saved: center, screens: BubblePlacement.currentScreens())
        panel.setFrame(OrbPlacement.panelFrame(center: resolved), display: true)
        settings.update { $0.orbPosition = resolved }
    }

    private func apply(_ settings: AppSettings) {
        if settings.orbEnabled && requested {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }
}
