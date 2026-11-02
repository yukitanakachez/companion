import CoreGraphics

/// Frame is in CG global coordinates.
struct WindowCandidate: Sendable, Equatable {
    var windowID: CGWindowID
    var pid: Int32
    var layer: Int
    var frame: CGRect
}

enum WindowMatcher {
    private static let minimumOverlap: CGFloat = 0.5

    /// Only pid-owned, layer-0 windows. Best IoU with focusedFrame (CG global) if ≥ 0.5, else the largest area.
    static func pick(_ windows: [WindowCandidate], pid: Int32, focusedFrame: CGRect?) -> CGWindowID? {
        let owned = windows.filter { $0.pid == pid && $0.layer == 0 }
        if let focusedFrame,
           let best = owned.max(by: { iou($0.frame, focusedFrame) < iou($1.frame, focusedFrame) }),
           iou(best.frame, focusedFrame) >= minimumOverlap {
            return best.windowID
        }
        return owned.max(by: { area($0.frame) < area($1.frame) })?.windowID
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = a.intersection(b)
        guard !overlap.isNull else { return 0 }
        let shared = area(overlap), union = area(a) + area(b) - shared
        return union > 0 ? shared / union : 0
    }
}
