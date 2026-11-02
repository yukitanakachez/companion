import CompanionCore
import CoreGraphics

protocol WindowCapturing: Sendable {
    /// focusedFrame: the AX focused-window frame in AppKit global coordinates (nil → largest window).
    func captureFrontWindow(pid: Int32, focusedFrame: CGRect?) async throws -> ImageAttachment
}

protocol RegionCapturing: Sendable {
    func capture(_ selection: RegionSelection) async throws -> ImageAttachment
}

enum RegionExclusion {
    /// Running apps whose windows must never appear in a region: our own and any blocklisted app.
    static func bundleIDsToExclude(running: [String], ownBundleID: String, config: BlocklistConfig) -> Set<String> {
        let blocked = Set(config.bundleIDs.map { $0.lowercased() })
        let own = ownBundleID.lowercased()
        return Set(running.filter { $0.lowercased() == own || blocked.contains($0.lowercased()) })
    }
}
