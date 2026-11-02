import CompanionCore

extension PermissionsService {
    public var status: PermissionStatus {
        PermissionStatus(screenRecording: screenRecordingGranted, accessibility: accessibilityGranted)
    }

    public func open(_ kind: PermissionKind) {
        openSettings(for: kind)
    }
}
