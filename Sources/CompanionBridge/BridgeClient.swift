import CompanionCore
import Foundation

/// Adapts `BridgeServer` to the CompanionCore service protocols.
struct BridgeClient: BrowserContextProviding {
    let server: BridgeServer

    func cachedActiveTabContext() async -> TabContext? {
        await server.cache.activeTabContext()
    }

    func requestActiveTabContext(timeout: Duration) async -> TabContext? {
        guard let target = await server.requestTarget() else { return nil }
        do {
            let outcome = try await perform(on: target, timeout: timeout) { .getTabContext(id: $0, tabId: nil) }
            guard let context = try outcome.response.decodeResult(TabContextResult.self).context else { return nil }
            await server.cache.store(context, from: target)
            return context
        } catch {
            return nil
        }
    }

    func isConnected() async -> Bool {
        await server.hasAuthenticatedSession()
    }

    private func perform(on target: ConnectionID, timeout: Duration,
                         _ makeRequest: @escaping @Sendable (String) -> BridgeRequest) async throws -> RequestOutcome {
        try await server.multiplexer.perform(on: target, timeout: timeout, makeRequest) { [server] request in
            try await server.send(.request(request), to: target)
        }
    }
}
