import CompanionCore
import Foundation

public final class ProviderRegistry: Sendable {
    private let secrets: any SecretStoring
    private let openAICompatibleBaseURL: @Sendable () -> URL
    private let session: URLSession
    private let prewarmGate = PrewarmGate()

    public init(secrets: any SecretStoring, openAICompatibleBaseURL: @escaping @Sendable () -> URL,
                session: URLSession = ProviderRegistry.makeSession()) {
        self.secrets = secrets
        self.openAICompatibleBaseURL = openAICompatibleBaseURL
        self.session = session
    }

    /// Anthropic sends `ping` events during long thinking, so the 60 s idle timeout does not cut slow answers.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// Reads the key on every call. Throws `LLMError.missingAPIKey(providerID:)` when the provider's key is absent or blank.
    public func provider(for model: ModelRef) throws -> any LLMProvider {
        switch model.providerID {
        case ModelRef.anthropicProviderID:
            return AnthropicAdapter(apiKey: try key(SecretKey.anthropicAPIKey, for: model), session: session, prewarmGate: prewarmGate)
        case ModelRef.openAICompatibleProviderID:
            return OpenAICompatibleAdapter(apiKey: try key(SecretKey.openAICompatibleAPIKey, for: model),
                                           baseURL: openAICompatibleBaseURL(), session: session, prewarmGate: prewarmGate)
        default:
            throw LLMError.http(status: 0, message: "Unknown provider: \(model.providerID)")
        }
    }

    private func key(_ name: String, for model: ModelRef) throws -> String {
        let key = secrets.secret(for: name)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if key.isEmpty { throw LLMError.missingAPIKey(providerID: model.providerID) }
        return key
    }
}
