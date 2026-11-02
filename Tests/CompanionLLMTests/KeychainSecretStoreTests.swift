@testable import CompanionLLM
import CompanionCore
import Foundation
import Security
import Testing

private func cleanUp(_ service: String) {
    SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
}
private func uniqueService() -> String { "dev.local.Companion.tests.\(UUID().uuidString)" }

struct KeychainSecretStoreTests {
    @Test func setGetOverwriteDelete() throws {
        let service = uniqueService()
        defer { cleanUp(service) }
        let store = KeychainSecretStore(service: service)
        #expect(store.secret(for: SecretKey.anthropicAPIKey) == nil)
        try store.setSecret("sk-ant-1", for: SecretKey.anthropicAPIKey)
        #expect(store.secret(for: SecretKey.anthropicAPIKey) == "sk-ant-1")
        try store.setSecret("sk-ant-2", for: SecretKey.anthropicAPIKey)
        #expect(store.secret(for: SecretKey.anthropicAPIKey) == "sk-ant-2")
        try store.setSecret(nil, for: SecretKey.anthropicAPIKey)
        #expect(store.secret(for: SecretKey.anthropicAPIKey) == nil)
    }

    @Test func deletingMissingKeyDoesNotThrow() throws {
        let service = uniqueService()
        defer { cleanUp(service) }
        try KeychainSecretStore(service: service).setSecret(nil, for: "never-set")
    }

    @Test func keysAndServicesAreIsolated() throws {
        let (service, other) = (uniqueService(), uniqueService())
        defer { cleanUp(service); cleanUp(other) }
        let store = KeychainSecretStore(service: service)
        let otherStore = KeychainSecretStore(service: other)
        try store.setSecret("a", for: "one")
        try store.setSecret("b", for: "two")
        try otherStore.setSecret("c", for: "one")
        #expect(store.secret(for: "one") == "a" && store.secret(for: "two") == "b")
        #expect(otherStore.secret(for: "one") == "c" && otherStore.secret(for: "two") == nil)
    }

    @Test func unicodeRoundTrips() throws {
        let service = uniqueService()
        defer { cleanUp(service) }
        let store = KeychainSecretStore(service: service)
        try store.setSecret("pässwörd-🔑", for: "key")
        #expect(store.secret(for: "key") == "pässwörd-🔑")
    }
}
