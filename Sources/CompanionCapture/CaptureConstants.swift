import CoreGraphics

enum CaptureConstants {
    static let longEdgePixels = 1500
    static let focusedTextCap = 8_000
    static let pageTextCap = 20_000
    static let mathCap = 50
    static let axWalkMaxElements = 150
    static let transcriptLookback: Double = 180
    static let axMessagingTimeout: Float = 0.05
    static let minRegionSide: CGFloat = 8
    static let imageTimeout: Duration = .seconds(2)
    static let axWalkMaxDuration: Duration = .milliseconds(40)
}

enum CaptureError: Error, Sendable, Equatable {
    case permissionDenied, noCapturableWindow, displayNotFound, encodingFailed
}
