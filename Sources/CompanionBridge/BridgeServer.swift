import CompanionCore
import Foundation
import Network

public actor BridgeServer {
    private struct Authenticated {
        let id: ConnectionID
        let session: BridgeSession
        let hello: HelloMessage
    }

    private let secrets: any SecretStoring
    private var blocklist: BlocklistConfig
    private let ports: [UInt16]
    private let appVersion: String
    private let queue = DispatchQueue(label: "dev.local.Companion.bridge")
    private var listener: NWListener?
    private var port: UInt16?
    private var accepting = false
    private var nextConnection: UInt64 = 0
    private var sessions: [ConnectionID: BridgeSession] = [:]
    private var authenticated: [Authenticated] = []
    nonisolated let timings: BridgeTimings

    public init(secrets: any SecretStoring, blocklist: BlocklistConfig,
                ports: [UInt16] = BridgeConstants.ports, appVersion: String) {
        self.init(secrets: secrets, blocklist: blocklist, ports: ports, appVersion: appVersion, timings: .standard)
    }

    init(secrets: any SecretStoring, blocklist: BlocklistConfig, ports: [UInt16], appVersion: String, timings: BridgeTimings) {
        self.secrets = secrets
        self.blocklist = blocklist
        self.ports = ports
        self.appVersion = appVersion
        self.timings = timings
    }

    public func start() async throws -> UInt16 {
        if let port { return port }
        _ = try BridgePairing.token(in: secrets)
        accepting = true
        do {
            let bound = try await BridgeListener.bind(ports: ports, queue: queue) { [weak self] connection in
                Task { await self?.accept(connection) }
            }
            listener = bound.listener
            port = bound.port
            return bound.port
        } catch {
            accepting = false
            throw error
        }
    }

    public func stop() async {
        accepting = false
        listener?.cancel()
        listener = nil
        port = nil
        let open = Array(sessions.values)
        sessions = [:]
        authenticated = []
        for session in open { await session.close(code: .protocolCode(.goingAway)) }
    }

    private func accept(_ connection: NWConnection) async {
        guard accepting else {
            connection.cancel()
            return
        }
        nextConnection += 1
        let id = ConnectionID(raw: nextConnection)
        let session = BridgeSession(
            id: id, connection: connection, queue: queue, timings: timings,
            // Read per connection, so a regenerated token applies only to new connections.
            expectedToken: { [secrets] in secrets.secret(for: SecretKey.bridgeToken) },
            events: BridgeSession.Events(
                authenticated: { [weak self] session, hello in await self?.sessionAuthenticated(session, hello) },
                message: { _, _ in },
                binary: { _, _, _ in },
                closed: { [weak self] id in await self?.sessionClosed(id) }))
        sessions[id] = session
        await session.start()
    }

    private func sessionAuthenticated(_ session: BridgeSession, _ hello: HelloMessage) {
        guard sessions[session.id] != nil else { return }
        authenticated.append(Authenticated(id: session.id, session: session, hello: hello))
        session.enqueue(.helloAck(appVersion: appVersion))
        session.enqueue(.config(blocklist: blocklist))
    }

    private func sessionClosed(_ id: ConnectionID) {
        sessions[id] = nil
        authenticated.removeAll { $0.id == id }
    }
}
