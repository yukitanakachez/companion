import AppKit
import SwiftUI

private final class GlowPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A brief glow outlining what was captured: click-through, never key, purely visual.
@MainActor public enum CaptureGlow {
    static let outset: CGFloat = 6, lineWidth: CGFloat = 3, cornerRadius: CGFloat = 12
    static let fadeIn = 0.08, hold = 0.25, fadeOut = 0.3

    private(set) static var activePanel: NSPanel?
    private static var generation = 0

    /// Returns immediately. A new flash closes the previous glow at once.
    public static func flash(_ rect: CGRect) {
        generation += 1
        activePanel?.close()
        activePanel = nil
        guard !rect.isEmpty, !rect.isNull else { return }

        let panel = GlowPanel(contentRect: rect.insetBy(dx: -outset, dy: -outset), styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)   // never over the bubble
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.alphaValue = 0
        panel.contentView = NSHostingView(rootView: GlowShape())
        panel.orderFrontRegardless()
        activePanel = panel

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fadeIn
            panel.animator().alphaValue = 1
        }, completionHandler: nil)

        let token = generation
        Task { @MainActor in
            try await Task.sleep(for: .seconds(fadeIn + hold))
            guard token == generation else { return }   // a stale timer never touches a newer glow
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = fadeOut
                panel.animator().alphaValue = 0
            }, completionHandler: nil)
            try await Task.sleep(for: .seconds(fadeOut))
            guard token == generation else { return }
            panel.close()
            activePanel = nil
        }
    }
}

private struct GlowShape: View {
    var body: some View {
        RoundedRectangle(cornerRadius: CaptureGlow.cornerRadius)
            .strokeBorder(AngularGradient(colors: Theme.aurora + [Theme.aurora[0]], center: .center), lineWidth: CaptureGlow.lineWidth)
            .shadow(color: Color(hex: 0x6E7BFF).opacity(0.6), radius: 8)
    }
}
