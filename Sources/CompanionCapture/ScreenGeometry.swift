import CoreGraphics

enum ScreenGeometry {
    static func primaryDisplayHeight() -> CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    /// AppKit global (bottom-left) ⇄ CG global (top-left); self-inverse: y' = H − y − h.
    static func flipped(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x, y: primaryHeight - rect.origin.y - rect.height, width: rect.width, height: rect.height)
    }

    static func fittedPixelSize(width: Int, height: Int,
                                longEdge: Int = CaptureConstants.longEdgePixels) -> (width: Int, height: Int) {
        let scale = min(1, Double(longEdge) / Double(max(width, height, 1)))
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// selection: AppKit global points. displayFrameCG: SCDisplay.frame (CG global points).
    /// Returns display-local, top-left-origin pixels, clamped to the display, integral.
    static func displayPixelRect(selection: CGRect, displayFrameCG: CGRect,
                                 primaryHeight: CGFloat, scale: CGFloat) -> CGRect {
        let cg = flipped(selection, primaryHeight: primaryHeight)
        let local = cg.offsetBy(dx: -displayFrameCG.minX, dy: -displayFrameCG.minY)
            .intersection(CGRect(origin: .zero, size: displayFrameCG.size))
        guard !local.isNull else { return .zero }
        return CGRect(x: local.minX * scale, y: local.minY * scale,
                      width: local.width * scale, height: local.height * scale).integral
    }
}
