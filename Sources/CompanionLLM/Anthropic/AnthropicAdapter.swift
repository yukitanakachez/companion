import CompanionCore
import Foundation

final class AnthropicAdapter: LLMProvider {
    let apiKey: String
    let baseURL: URL
    private let transport: SSETransport
    private let prewarmGate: PrewarmGate

    init(apiKey: String, session: URLSession, baseURL: URL = AnthropicRequestEncoder.defaultBaseURL,
         prewarmGate: PrewarmGate = PrewarmGate()) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.transport = SSETransport(session: session)
        self.prewarmGate = prewarmGate
    }

    var providerID: String { ModelRef.anthropicProviderID }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        do {
            let urlRequest = try AnthropicRequestEncoder.urlRequest(for: request, apiKey: apiKey, baseURL: baseURL)
            return transport.stream(urlRequest, decoder: AnthropicStreamDecoder(), errorMessage: AnthropicStreamDecoder.errorMessage(from:))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    func prewarm() async {
        await transport.prewarm(baseURL, gate: prewarmGate)
    }
}
