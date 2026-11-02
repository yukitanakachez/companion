import CompanionCore
@testable import CompanionSession
import Foundation
import Testing

private func withSuite(_ body: (UserDefaults) -> Void) {
    let name = "companion.tests.\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: name)!
    defer { suite.removePersistentDomain(forName: name) }
    body(suite)
}

@Test func opensSettingsOnceWhenSomethingIsMissing() {
    withSuite { suite in
        #expect(FirstRunPolicy.shouldOpenSettings(screenRecording: false, accessibility: true, hasAnyAPIKey: true, defaults: suite))
        #expect(!FirstRunPolicy.shouldOpenSettings(screenRecording: false, accessibility: true, hasAnyAPIKey: true, defaults: suite))
        #expect(suite.bool(forKey: "onboarding.settingsShown.v1"))
    }
}

@Test func missingKeyAloneCounts() {
    withSuite { suite in
        #expect(FirstRunPolicy.shouldOpenSettings(screenRecording: true, accessibility: true, hasAnyAPIKey: false, defaults: suite))
    }
}

@Test func doesNotOpenWhenEverythingIsReady() {
    withSuite { suite in
        #expect(!FirstRunPolicy.shouldOpenSettings(screenRecording: true, accessibility: true, hasAnyAPIKey: true, defaults: suite))
        #expect(suite.object(forKey: FirstRunPolicy.shownKey) == nil)
    }
}

@MainActor @Test func permissionKindMapsToPane() {
    var opened: [URL] = []
    PermissionsService(open: { opened.append($0) }).open(.screenRecording)
    #expect(opened == [PermissionKind.screenRecording.settingsURL])
}
