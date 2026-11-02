import CompanionCore
import Foundation
import Network

enum BridgeListener {
    static let maxMessageBytes = 16_777_216

    static func makeWebSocketOptions() -> NWProtocolWebSocket.Options {
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.maximumMessageSize = maxMessageBytes
        webSocket.autoReplyPing = true
        return webSocket
    }

    static func makeParameters(port: UInt16) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(makeWebSocketOptions(), at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = false
        return parameters
    }

    /// Tries `ports` in order and returns the first listener that becomes ready.
    static func bind(ports: [UInt16], queue: DispatchQueue,
                     onConnection: @escaping @Sendable (NWConnection) -> Void) async throws -> (listener: NWListener, port: UInt16) {
        for port in ports {
            guard let listener = try? NWListener(using: makeParameters(port: port)) else { continue }
            listener.newConnectionHandler = onConnection
            if let bound = await waitUntilBound(listener, queue: queue) { return (listener, bound) }
            listener.cancel()
        }
        throw BridgeError(code: .internal, message: "No free bridge port in \(ports)")
    }

    private static func waitUntilBound(_ listener: NWListener, queue: DispatchQueue) async -> UInt16? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UInt16?, Never>) in
            // Runs only on `queue`, which is serial, so a plain flag is safe here.
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue)
                case .failed, .waiting, .cancelled:
                    resumed = true
                    continuation.resume(returning: nil)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }
}
