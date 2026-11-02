import CompanionCore
import Foundation

final class OpenAICompatibleAdapter: LLMProvider {
    let apiKey: String
    let baseURL: URL
    private let transport: SSETransport
    private let prewarmGate: PrewarmGate

    init(apiKey: String, baseURL: URL, session: URLSession, prewarmGate: PrewarmGate = PrewarmGate()) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.transport = SSETransport(session: session)
        self.prewarmGate = prewarmGate
    }

    var providerID: String { ModelRef.openAICompatibleProviderID }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        do {
            let urlRequest = try OpenAICompatibleRequestEncoder.urlRequest(for: request, apiKey: apiKey, baseURL: baseURL)
            return transport.stream(urlRequest, decoder: OpenAICompatibleStreamDecoder(),
                                    errorMessage: OpenAICompatibleStreamDecoder.errorMessage(from:))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    func prewarm() async {
        await transport.prewarm(baseURL, gate: prewarmGate)
    }
}
