import CompanionCore
import CoreGraphics
@preconcurrency import ScreenCaptureKit

struct LiveWindowCapturer: WindowCapturing {
    private let hasPermission: @Sendable () -> Bool

    init(hasPermission: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }) {
        self.hasPermission = hasPermission
    }

    func captureFrontWindow(pid: Int32, focusedFrame: CGRect?) async throws -> ImageAttachment {
        // Calling SCK without this check can trigger the system prompt on every summon.
        guard hasPermission() else { throw CaptureError.permissionDenied }

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let candidates = content.windows.compactMap { window -> WindowCandidate? in
            guard let owner = window.owningApplication else { return nil }
            return WindowCandidate(windowID: window.windowID, pid: owner.processID,
                                   layer: window.windowLayer, frame: window.frame)
        }
        let focusedCG = focusedFrame.map { ScreenGeometry.flipped($0, primaryHeight: ScreenGeometry.primaryDisplayHeight()) }
        guard let windowID = WindowMatcher.pick(candidates, pid: pid, focusedFrame: focusedCG),
              let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.noCapturableWindow
        }

        // A single-window filter naturally leaves out our panel and the glow.
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let size = ScreenGeometry.fittedPixelSize(width: Int((filter.contentRect.width * scale).rounded()),
                                                  height: Int((filter.contentRect.height * scale).rounded()))
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return try ImageEncoding.attachment(image)
    }
}
