import CoreGraphics

enum OrbPlacement {
    static let diameter: CGFloat = 30, inset: CGFloat = 24, panelSize: CGFloat = 58, dragThreshold: CGFloat = 3

    static func defaultCenter(mainVisibleFrame: CGRect) -> CGPoint {
        let fromEdge = inset + diameter / 2
        return CGPoint(x: mainVisibleFrame.maxX - fromEdge, y: mainVisibleFrame.minY + fromEdge)
    }

    /// The saved center if it is inside some display's visible frame inset by 15, else the default
    /// on the first screen (so an orb saved on an unplugged display comes back).
    static func resolve(saved: CGPoint?, screens: [ScreenGeometry]) -> CGPoint {
        if let saved, screens.contains(where: { $0.visibleFrame.insetBy(dx: 15, dy: 15).contains(saved) }) { return saved }
        return defaultCenter(mainVisibleFrame: screens.first?.visibleFrame ?? .zero)
    }

    static func isDrag(from: CGPoint, to: CGPoint) -> Bool {
        hypot(to.x - from.x, to.y - from.y) >= dragThreshold
    }

    static func panelFrame(center: CGPoint) -> CGRect {
        CGRect(x: center.x - panelSize / 2, y: center.y - panelSize / 2, width: panelSize, height: panelSize)
    }
}
