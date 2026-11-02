import CompanionCore
@testable import CompanionSession
import Foundation
import Testing

@Test func settingsURLs() {
    #expect(PermissionKind.screenRecording.settingsURL.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    #expect(PermissionKind.accessibility.settingsURL.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
}

@MainActor @Test func openSettingsUsesInjectedOpener() {
    var opened: [URL] = []
    let service = PermissionsService(open: { opened.append($0) })
    service.openSettings(for: .accessibility)
    #expect(opened == [PermissionKind.accessibility.settingsURL])
}
