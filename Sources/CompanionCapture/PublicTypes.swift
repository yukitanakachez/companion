import CoreGraphics

public struct RegionSelection: Sendable, Equatable {
    /// Global AppKit coordinates (bottom-left origin).
    public var rect: CGRect
    public var displayID: CGDirectDisplayID

    public init(rect: CGRect, displayID: CGDirectDisplayID) {
        self.rect = rect
        self.displayID = displayID
    }
}

public enum GatherRequest: Sendable, Equatable {
    case frontWindow
    case region(RegionSelection)
}
