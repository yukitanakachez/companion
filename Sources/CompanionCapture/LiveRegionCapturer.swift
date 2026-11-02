import CompanionCore
import CoreGraphics
@preconcurrency import ScreenCaptureKit

struct LiveRegionCapturer: RegionCapturing {
    private let ownBundleID: String
    private let blocklist: @Sendable () -> BlocklistConfig
    private let hasPermission: @Sendable () -> Bool

    init(ownBundleID: String, blocklist: @escaping @Sendable () -> BlocklistConfig,
         hasPermission: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }) {
        self.ownBundleID = ownBundleID
        self.blocklist = blocklist
        self.hasPermission = hasPermission
    }

    func capture(_ selection: RegionSelection) async throws -> ImageAttachment {
        guard hasPermission() else { throw CaptureError.permissionDenied }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == selection.displayID }) else {
            throw CaptureError.displayNotFound
        }

        // Our own windows and any blocklisted app's windows never appear in a region.
        let excludedIDs = RegionExclusion.bundleIDsToExclude(running: content.applications.map(\.bundleIdentifier),
                                                             ownBundleID: ownBundleID, config: blocklist())
        let excluded = content.applications.filter { excludedIDs.contains($0.bundleIdentifier) }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])

        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = Int((CGFloat(display.width) * scale).rounded())
        configuration.height = Int((CGFloat(display.height) * scale).rounded())
        configuration.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let crop = ScreenGeometry.displayPixelRect(selection: selection.rect, displayFrameCG: display.frame,
                                                   primaryHeight: ScreenGeometry.primaryDisplayHeight(), scale: scale)
        guard !crop.isEmpty, let cropped = image.cropping(to: crop) else { throw CaptureError.encodingFailed }
        return try ImageEncoding.attachment(ImageEncoding.downscaled(cropped))
    }
}
