import CompanionCore
import Foundation

struct RequestOutcome: Sendable {
    var response: BridgeResponse
    var chunks: ChunkAssembler?
}

/// Ids, continuations, timeouts and binary-chunk collection for requests to the extension.
/// Whichever of response, timeout, disconnect, send failure or chunk error arrives first wins.
actor RequestMultiplexer {
    private struct Pending {
        let connection: ConnectionID
        let continuation: CheckedContinuation<RequestOutcome, any Error>
        var assembler: ChunkAssembler?
        var timeoutTask: Task<Void, Never>?
    }

    private var pending: [String: Pending] = [:]
    private var counter = 0

    init() {}

    var pendingCount: Int { pending.count }

    /// Allocates "r-<n>", registers a waiter for `connection`, sends, then waits for the response, the timeout,
    /// the connection closing, or a chunk error. An `ok: false` response throws its `error` payload.
    func perform(on connection: ConnectionID, timeout: Duration,
                 _ makeRequest: (String) -> BridgeRequest,
                 send: @escaping @Sendable (BridgeRequest) async throws -> Void) async throws -> RequestOutcome {
        counter += 1
        let id = "r-\(counter)"
        let request = makeRequest(id)
        return try await withCheckedThrowingContinuation { continuation in
            // Registered before sending: a fast extension can answer before `send` returns.
            pending[id] = Pending(connection: connection, continuation: continuation, assembler: nil, timeoutTask: nil)
            pending[id]?.timeoutTask = Task { [weak self] in
                guard (try? await Task.sleep(for: timeout)) != nil else { return }
                await self?.finish(id, .failure(BridgeError(code: .timeout, message: "\(request.method) timed out")))
            }
            Task { [weak self] in
                do {
                    try await send(request)
                } catch {
                    await self?.finish(id, .failure(Self.notConnected))
                }
            }
        }
    }

    func handleResponse(_ response: BridgeResponse, from connection: ConnectionID) {
        guard let entry = pending[response.id], entry.connection == connection else { return }
        if response.ok {
            finish(response.id, .success(RequestOutcome(response: response, chunks: entry.assembler)))
        } else {
            finish(response.id, .failure(response.error ?? BridgeError(code: .internal, message: "Error response without error payload")))
        }
    }

    func handleBinary(_ header: BinaryFrameHeader, _ payload: Data, from connection: ConnectionID) {
        guard var entry = pending[header.id], entry.connection == connection else { return }
        var assembler = entry.assembler ?? ChunkAssembler(requestID: header.id)
        do {
            try assembler.add(header, payload)
            entry.assembler = assembler
            pending[header.id] = entry
        } catch {
            finish(header.id, .failure(error))
        }
    }

    /// That connection's pending requests fail with `.notConnected`.
    func connectionClosed(_ connection: ConnectionID) {
        for (id, entry) in pending where entry.connection == connection { finish(id, .failure(Self.notConnected)) }
    }

    /// Every pending request fails with `.notConnected`.
    func failAll() {
        for id in pending.keys { finish(id, .failure(Self.notConnected)) }
    }

    private static let notConnected = BridgeError(code: .notConnected, message: "Extension not connected")

    private func finish(_ id: String, _ result: Result<RequestOutcome, any Error>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeoutTask?.cancel()
        entry.continuation.resume(with: result)
    }
}
