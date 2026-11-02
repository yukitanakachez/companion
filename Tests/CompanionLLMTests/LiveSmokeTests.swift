@testable import CompanionLLM
import CompanionCore
import CompanionTestSupport
import Foundation
import Testing

private let liveKey = ProcessInfo.processInfo.environment["COMPANION_LIVE_ANTHROPIC_KEY"]

struct LiveSmokeTests {
    /// Opt-in: runs only with COMPANION_LIVE_ANTHROPIC_KEY set. Never commit a key.
    @Test(.enabled(if: liveKey != nil), .timeLimit(.minutes(1)))
    func liveHaikuTimeToFirstToken() async throws {
        let registry = ProviderRegistry(secrets: FakeSecretStore([SecretKey.anthropicAPIKey: try #require(liveKey)]),
                                        openAICompatibleBaseURL: { URL(string: "https://api.openai.com/v1")! })
        let provider = try registry.provider(for: ModelCatalog.haiku45)
        await provider.prewarm()
        let context = CapturedContext(front: nil, privacy: .allowed, kind: .genericWindow,
                                      items: [ContextItem(piece: .windowImage(Fixtures.samplePNG(width: 1500, height: 1000)))], isComplete: true)
        let (system, messages) = PromptBuilder().build(question: "Reply with one short sentence: what is 2+2?",
                                                       context: context, history: [], hintMode: false)
        let start = ContinuousClock.now
        var firstToken: Duration?
        var last: LLMStreamEvent?
        for try await event in provider.stream(LLMRequest(model: ModelCatalog.haiku45, system: system, messages: messages, maxTokens: 128)) {
            if case .textDelta = event, firstToken == nil { firstToken = ContinuousClock.now - start }
            last = event
        }
        let elapsed = try #require(firstToken)
        if case .finished = last {} else { Issue.record("last event was \(String(describing: last))") }
        print("Haiku 4.5 time to first token: \(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000) ms (spec budget ≈ 1000–1500 ms)")
    }
}
