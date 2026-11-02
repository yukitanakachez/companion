import CompanionCore
@testable import CompanionSession
import Foundation
import Testing

@MainActor private func withSuite(_ body: (UserDefaults) throws -> Void) rethrows {
    let name = "companion.tests.\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: name)!
    defer { suite.removePersistentDomain(forName: name) }
    try body(suite)
}

@MainActor @Test func emptySuiteGivesDefaults() {
    withSuite { suite in
        #expect(UserDefaultsSettingsStore(defaults: suite).settings == .default)
    }
}

@MainActor @Test func updatePersistsAcrossInstances() throws {
    try withSuite { suite in
        let store = UserDefaultsSettingsStore(defaults: suite)
        store.update {
            $0.orbEnabled = false
            $0.routing.youtube = ModelCatalog.sonnet55
        }
        #expect(store.settings.orbEnabled == false)
        #expect(UserDefaultsSettingsStore(defaults: suite).settings == store.settings)
        let data = try #require(suite.data(forKey: "settings.v1"))
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == store.settings)
    }
}

@MainActor @Test func observersRunSynchronouslyInOrder() {
    withSuite { suite in
        let store = UserDefaultsSettingsStore(defaults: suite)
        var log: [String] = []
        store.addObserver { #expect($0.orbEnabled == false); log.append("a") }
        store.addObserver { #expect($0.orbEnabled == false); log.append("b") }
        store.update { $0.orbEnabled = false }
        #expect(log == ["a", "b"])
    }
}

@MainActor @Test func unchangedUpdateDoesNotNotify() {
    withSuite { suite in
        let store = UserDefaultsSettingsStore(defaults: suite)
        var calls = 0
        store.addObserver { _ in calls += 1 }
        store.update { _ in }
        #expect(calls == 0)
    }
}

@MainActor @Test func corruptDataFallsBackToDefaults() {
    withSuite { suite in
        suite.set(Data("nope".utf8), forKey: "settings.v1")
        #expect(UserDefaultsSettingsStore(defaults: suite).settings == .default)
    }
}

@MainActor @Test func mirrorTracksUpdatesSynchronously() {
    withSuite { suite in
        let store = UserDefaultsSettingsStore(defaults: suite)
        let mirror = SettingsMirror(store: store)
        store.update { $0.blocklist.domains.append("example.com") }
        #expect(mirror.blocklist.domains.contains("example.com"))
    }
}

@MainActor @Test func mirrorBaseURLFallback() {
    withSuite { suite in
        let store = UserDefaultsSettingsStore(defaults: suite)
        let mirror = SettingsMirror(store: store)
        store.update { $0.openAICompatibleBaseURL = "" }
        #expect(mirror.openAICompatibleBaseURL == URL(string: "https://api.openai.com/v1"))
        store.update { $0.openAICompatibleBaseURL = "http://localhost:1234/v1" }
        #expect(mirror.openAICompatibleBaseURL == URL(string: "http://localhost:1234/v1"))
    }
}
