import AppKit

typealias ScreenGeometry = (frame: CGRect, visibleFrame: CGRect)

enum BubbleMetrics {
    static let width: CGFloat = 380, minHeight: CGFloat = 72, maxHeight: CGFloat = 520, cornerRadius: CGFloat = 14
    static let cursorOffset = CGVector(dx: 16, dy: -16)
    static let popOutSize = CGSize(width: 640, height: 720), popOutMinSize = CGSize(width: 480, height: 400)
    static func clampedHeight(_ contentHeight: CGFloat) -> CGFloat { min(max(contentHeight, minHeight), maxHeight) }
}

enum BubblePlacement {
    private static let avoidGap: CGFloat = 12

    static func frame(cursor c: CGPoint, size: CGSize, screens: [ScreenGeometry], avoid: CGRect?) -> CGRect {
        let (w, h) = (size.width, size.height)
        let ox = BubbleMetrics.cursorOffset.dx, oy = -BubbleMetrics.cursorOffset.dy
        let rightBelow = CGRect(x: c.x + ox, y: c.y - oy - h, width: w, height: h)
        guard let visible = (screen(for: c, in: screens) ?? screens.first)?.visibleFrame else { return rightBelow }

        let cursorCandidates = [
            rightBelow,
            CGRect(x: c.x - ox - w, y: c.y - oy - h, width: w, height: h),
            CGRect(x: c.x + ox, y: c.y + oy, width: w, height: h),
            CGRect(x: c.x - ox - w, y: c.y + oy, width: w, height: h),
        ]
        var candidates = cursorCandidates
        if let avoid {
            candidates += [
                CGRect(x: avoid.maxX + avoidGap, y: c.y - oy - h, width: w, height: h),
                CGRect(x: avoid.minX - avoidGap - w, y: c.y - oy - h, width: w, height: h),
                CGRect(x: c.x + ox, y: avoid.minY - avoidGap - h, width: w, height: h),
                CGRect(x: c.x + ox, y: avoid.maxY + avoidGap, width: w, height: h),
            ]
        }
        if let best = candidates.first(where: { visible.contains($0) && !(avoid?.intersects($0) ?? false) }) { return best }
        if let inside = cursorCandidates.first(where: { visible.contains($0) }) { return inside }

        let capped = CGSize(width: min(w, visible.width), height: min(h, visible.height))
        return CGRect(x: min(max(rightBelow.minX, visible.minX), visible.maxX - capped.width),
                      y: min(max(rightBelow.minY, visible.minY), visible.maxY - capped.height),
                      width: capped.width, height: capped.height)
    }

    /// Keeps the top edge (anchorTop) or bottom edge fixed, then shifts/clamps into visibleFrame.
    static func resized(_ frame: CGRect, toHeight height: CGFloat, anchorTop: Bool, visibleFrame: CGRect) -> CGRect {
        let h = min(height, visibleFrame.height)
        let y = anchorTop ? frame.maxY - h : frame.minY
        return CGRect(x: frame.minX, y: min(max(y, visibleFrame.minY), visibleFrame.maxY - h), width: frame.width, height: h)
    }

    /// Max edges inclusive: `NSEvent.mouseLocation` can sit exactly on a display's top or right edge.
    static func screen(for point: CGPoint, in screens: [ScreenGeometry]) -> ScreenGeometry? {
        screens.first {
            point.x >= $0.frame.minX && point.x <= $0.frame.maxX && point.y >= $0.frame.minY && point.y <= $0.frame.maxY
        }
    }

    @MainActor static func currentScreens() -> [ScreenGeometry] {
        NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }
}
