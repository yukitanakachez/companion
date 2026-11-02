@testable import CompanionLLM
import CompanionCore
import CompanionTestSupport
import Foundation
import os
import Testing

private let openAI = URL(string: "https://api.openai.com/v1")!
private let compatible = ModelRef(providerID: "openai-compatible", modelID: "gpt-test", displayName: "GPT")

private func registry(_ secrets: [String: String] = [:]) -> ProviderRegistry {
    ProviderRegistry(secrets: FakeSecretStore(secrets), openAICompatibleBaseURL: { openAI })
}

struct ProviderRegistryTests {
    @Test func anthropicModelGetsAnthropicAdapter() throws {
        let p = try registry([SecretKey.anthropicAPIKey: "sk-ant-test"]).provider(for: ModelCatalog.sonnet55)
        #expect((p as? AnthropicAdapter)?.apiKey == "sk-ant-test" && p.providerID == "anthropic")
    }

    @Test func keyIsTrimmed() throws {
        let p = try registry([SecretKey.anthropicAPIKey: " sk-ant-test\n"]).provider(for: ModelCatalog.haiku45)
        #expect((p as? AnthropicAdapter)?.apiKey == "sk-ant-test")
    }

    @Test(arguments: [nil, "", "   \n"] as [String?])
    func blankKeysThrowMissingAPIKey(_ key: String?) {
        let reg = registry(key.map { [SecretKey.anthropicAPIKey: $0] } ?? [:])
        #expect(throws: LLMError.missingAPIKey(providerID: "anthropic")) { try reg.provider(for: ModelCatalog.haiku45) }
    }

    @Test func keyIsReadOnEveryCall() throws {
        let secrets = FakeSecretStore()
        let reg = ProviderRegistry(secrets: secrets, openAICompatibleBaseURL: { openAI })
        #expect(throws: LLMError.missingAPIKey(providerID: "anthropic")) { try reg.provider(for: ModelCatalog.haiku45) }
        try secrets.setSecret("sk-ant-new", for: SecretKey.anthropicAPIKey)
        #expect((try reg.provider(for: ModelCatalog.haiku45) as? AnthropicAdapter)?.apiKey == "sk-ant-new")
    }

    @Test func openAICompatibleUsesBaseURLClosureAtCallTime() throws {
        let a = URL(string: "https://a.test/v1")!
        let b = URL(string: "https://b.test/v1")!
        let box = OSAllocatedUnfairLock(initialState: a)
        let reg = ProviderRegistry(secrets: FakeSecretStore([SecretKey.openAICompatibleAPIKey: "sk-test"]),
                                   openAICompatibleBaseURL: { box.withLock { $0 } })
        let first = try reg.provider(for: compatible)
        #expect((first as? OpenAICompatibleAdapter)?.baseURL == a && first.providerID == "openai-compatible")
        box.withLock { $0 = b }
        #expect((try reg.provider(for: compatible) as? OpenAICompatibleAdapter)?.baseURL == b)
    }

    @Test func openAICompatibleMissingKeyThrows() {
        #expect(throws: LLMError.missingAPIKey(providerID: "openai-compatible")) { try registry().provider(for: compatible) }
    }

    @Test func unknownProviderThrows() {
        let unknown = ModelRef(providerID: "gemini-native", modelID: "x", displayName: "x")
        #expect(throws: LLMError.http(status: 0, message: "Unknown provider: gemini-native")) { try registry().provider(for: unknown) }
    }

    @Test func prewarmIsSharedAcrossProviders() async throws {
        let s = StubServer()
        let reg = ProviderRegistry(secrets: FakeSecretStore([SecretKey.openAICompatibleAPIKey: "sk-test"]),
                                   openAICompatibleBaseURL: { s.baseURL.appending(path: "v1") }, session: s.session)
        try await reg.provider(for: compatible).prewarm()
        try await reg.provider(for: compatible).prewarm()
        #expect(s.requests.count == 1)
        #expect(s.requests.first?.method == "HEAD")
    }
}
