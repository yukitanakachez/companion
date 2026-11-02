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
    private var pingTask: Task<Void, Never>?
    private var nextConnection: UInt64 = 0
    private var sessions: [ConnectionID: BridgeSession] = [:]
    private var authenticated: [Authenticated] = []
    nonisolated let timings: BridgeTimings
    // `let` actors, so the client reaches them without hopping through the server actor.
    nonisolated let cache = ContextCache()
    nonisolated let multiplexer = RequestMultiplexer()

    public nonisolated var browserContext: any BrowserContextProviding { BridgeClient(server: self) }

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
            startPinging()
            return bound.port
        } catch {
            accepting = false
            throw error
        }
    }

    public func stop() async {
        accepting = false
        pingTask?.cancel()
        pingTask = nil
        listener?.cancel()
        listener = nil
        port = nil
        let open = sessions
        sessions = [:]
        authenticated = []
        await multiplexer.failAll()
        for (id, session) in open {
            await session.close(code: .protocolCode(.goingAway))
            await cache.connectionClosed(id)
        }
    }

    public func updateBlocklist(_ config: BlocklistConfig) async {
        blocklist = config
        for session in authenticated { session.session.enqueue(.config(blocklist: config)) }
    }

    /// Connected browsers are listed in authentication order.
    public func status() async -> BridgeStatus {
        BridgeStatus(port: port, connectedBrowsers: authenticated.map(\.hello.browserName))
    }

    /// The active browser if it is authenticated, else the most recently authenticated session.
    func requestTarget() async -> ConnectionID? {
        if let active = await cache.activeConnection(), hasAuthenticatedSession(active) { return active }
        return authenticated.last?.id
    }

    func send(_ message: AppToExtension, to connection: ConnectionID) throws {
        guard let target = authenticated.first(where: { $0.id == connection }) else {
            throw BridgeError(code: .notConnected, message: "Extension not connected")
        }
        target.session.enqueue(message)
    }

    func hasAuthenticatedSession() -> Bool { !authenticated.isEmpty }

    func hasAuthenticatedSession(_ connection: ConnectionID) -> Bool {
        authenticated.contains { $0.id == connection }
    }

    private func startPinging() {
        let interval = timings.pingInterval
        pingTask = Task { [weak self] in
            while (try? await Task.sleep(for: interval)) != nil {
                await self?.pingAuthenticatedSessions()
            }
        }
    }

    private func pingAuthenticatedSessions() {
        for session in authenticated { session.session.enqueue(.ping) }
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
                message: { [cache, multiplexer] id, message in
                    switch message {
                    case .tabActivated, .tabContext, .youtubePlayhead, .tabClosed:
                        await cache.apply(message, from: id)
                    case .response(let response):
                        await multiplexer.handleResponse(response, from: id)
                    case .hello, .progress:
                        break   // No contract API consumes progress.
                    }
                },
                binary: { [multiplexer] id, header, payload in
                    await multiplexer.handleBinary(header, payload, from: id)
                },
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

    private func sessionClosed(_ id: ConnectionID) async {
        sessions[id] = nil
        authenticated.removeAll { $0.id == id }
        await cache.connectionClosed(id)
        await multiplexer.connectionClosed(id)
    }
}

extension BridgeServer {
    public nonisolated var documentFetcher: any DocumentFetching { BridgeClient(server: self) }
    public nonisolated var viewerDriver: any ViewerDriving { BridgeClient(server: self) }

    /// The browser holding that tab if it is authenticated, else `requestTarget()`.
    func viewerTarget(tabId: Int) async -> ConnectionID? {
        if let owner = await cache.connection(forTab: tabId), hasAuthenticatedSession(owner) { return owner }
        return await requestTarget()
    }
}
