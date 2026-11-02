import Foundation

public final class ProviderRegistry: Sendable {
    /// Anthropic sends `ping` events during long thinking, so the 60 s idle timeout does not cut slow answers.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}
