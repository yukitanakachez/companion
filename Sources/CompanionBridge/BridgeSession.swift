import CompanionCore
import Foundation
import Network

/// One WebSocket connection: receive loop, hello timer and handshake.
actor BridgeSession {
    struct Events: Sendable {
        var authenticated: @Sendable (BridgeSession, HelloMessage) async -> Void
        var message: @Sendable (ConnectionID, ExtensionToApp) async -> Void
        var binary: @Sendable (ConnectionID, BinaryFrameHeader, Data) async -> Void
        /// Exactly once.
        var closed: @Sendable (ConnectionID) async -> Void
    }

    private enum State { case awaitingHello, authenticated, closing }
    private enum Frame { case text(Data), binary(Data), peerClosed, ignored, ended }

    /// How long a close frame may take to flush before the connection is cancelled anyway.
    private static let closeFlushLimit: DispatchTimeInterval = .seconds(1)

    nonisolated let id: ConnectionID
    private nonisolated let connection: NWConnection
    private nonisolated let queue: DispatchQueue
    private let timings: BridgeTimings
    private let expectedToken: @Sendable () -> String?
    private let events: Events
    private var state = State.awaitingHello
    private var helloTimer: Task<Void, Never>?
    private var closedFired = false

    init(id: ConnectionID, connection: NWConnection, queue: DispatchQueue, timings: BridgeTimings,
         expectedToken: @escaping @Sendable () -> String?, events: Events) {
        self.id = id
        self.connection = connection
        self.queue = queue
        self.timings = timings
        self.expectedToken = expectedToken
        self.events = events
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                Task { await self?.connectionEnded() }
            default:
                break
            }
        }
        connection.start(queue: queue)
        let timeout = timings.helloTimeout
        helloTimer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            await self?.helloTimedOut()
        }
        Task { await receiveLoop() }
    }

    /// Call only from `BridgeServer`'s actor: `NWConnection.send` keeps call order, so frames enqueued
    /// synchronously there reach the extension in that order.
    nonisolated func enqueue(_ message: AppToExtension) {
        guard let data = try? FrameCodec.encode(message) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { [connection] error in
            if error != nil { connection.cancel() }
        })
    }

    func close(code: NWProtocolWebSocket.CloseCode) {
        guard state != .closing else { return }
        state = .closing
        helloTimer?.cancel()
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = code
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        let connection = connection
        connection.send(content: nil, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
        // A peer that never finished the upgrade or stopped reading must not hold the socket open.
        queue.asyncAfter(deadline: .now() + Self.closeFlushLimit) { connection.cancel() }
    }

    private func helloTimedOut() {
        guard state == .awaitingHello else { return }
        close(code: .privateCode(BridgeConstants.closeCodeUnauthorized))
    }

    private func connectionEnded() async {
        state = .closing
        helloTimer?.cancel()
        guard !closedFired else { return }
        closedFired = true
        await events.closed(id)
    }

    /// Each event is awaited before the next frame is read, so a connection's order reaches the cache intact.
    private func receiveLoop() async {
        while state != .closing {
            let frame = await nextFrame()
            guard state != .closing else { return }
            switch frame {
            case .text(let data): await handleText(data)
            case .binary(let data): await handleBinary(data)
            case .ignored: continue
            case .peerClosed, .ended:
                connection.cancel()
                return
            }
        }
    }

    private func nextFrame() async -> Frame {
        await withCheckedContinuation { continuation in
            connection.receiveMessage { content, context, _, error in
                if error != nil { return continuation.resume(returning: .ended) }
                guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                        as? NWProtocolWebSocket.Metadata else {
                    return continuation.resume(returning: .ended)
                }
                switch metadata.opcode {
                case .text: continuation.resume(returning: .text(content ?? Data()))
                case .binary: continuation.resume(returning: .binary(content ?? Data()))
                case .close: continuation.resume(returning: .peerClosed)
                default: continuation.resume(returning: .ignored)
                }
            }
        }
    }

    private func handleText(_ data: Data) async {
        let message: ExtensionToApp
        do {
            message = try FrameCodec.decodeText(data)
        } catch let error as BridgeError where error.code == .versionMismatch {
            close(code: .privateCode(BridgeConstants.closeCodeVersionMismatch))
            return
        } catch {
            if state == .awaitingHello { close(code: .privateCode(BridgeConstants.closeCodeUnauthorized)) }
            return
        }

        if state == .awaitingHello {
            guard case .hello(let hello) = message, tokenMatches(hello.token) else {
                close(code: .privateCode(BridgeConstants.closeCodeUnauthorized))
                return
            }
            state = .authenticated
            helloTimer?.cancel()
            await events.authenticated(self, hello)
        } else if case .hello = message {
            return
        } else {
            await events.message(id, message)
        }
    }

    private func handleBinary(_ data: Data) async {
        guard state == .authenticated else {
            close(code: .privateCode(BridgeConstants.closeCodeUnauthorized))
            return
        }
        guard let frame = try? BinaryFrame.decode(data) else { return }
        await events.binary(id, frame.header, frame.payload)
    }

    /// Constant-time for equal lengths. A missing or empty expected token never matches.
    private func tokenMatches(_ presented: String) -> Bool {
        guard let expected = expectedToken(), !expected.isEmpty else { return false }
        let a = Array(presented.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
