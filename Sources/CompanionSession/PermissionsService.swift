import AppKit
import ApplicationServices
import CompanionCore
import CoreGraphics

extension PermissionKind {
    public var settingsURL: URL {
        let pane = switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

@MainActor protocol PermissionChecking: AnyObject {
    var screenRecordingGranted: Bool { get }
    var accessibilityGranted: Bool { get }
    func openSettings(for permission: PermissionKind)
}

@MainActor public final class PermissionsService: PermissionChecking {
    private let open: @MainActor (URL) -> Void

    public init(open: @escaping @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) }) {
        self.open = open
    }

    /// Never prompts.
    public var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }
    /// Never prompts.
    public var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt, which is also what lists Companion in the System Settings pane.
    public func request(_ permission: PermissionKind) {
        switch permission {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            // The literal key: Swift 6 rejects the mutable C global kAXTrustedCheckOptionPrompt.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    }

    public func openSettings(for permission: PermissionKind) {
        open(permission.settingsURL)
    }
}
