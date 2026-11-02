import CompanionCore
import CompanionTestSupport
import Foundation
import Network
import Testing
@testable import CompanionBridge

@Suite struct HandshakeTests {
    @Test func parametersAreLoopbackOnlyWith16MiBMessages() {
        let p = BridgeListener.makeParameters(port: 47823)
        #expect(p.requiredLocalEndpoint == .hostPort(host: "127.0.0.1", port: 47823))
        #expect(p.allowLocalEndpointReuse == false)
        // The stack hands back a new wrapper whose getters read defaults, so the configured values are
        // checked on the options themselves and proven on a live socket by the two tests below.
        #expect(p.defaultProtocolStack.applicationProtocols.first is NWProtocolWebSocket.Options)
        let ws = BridgeListener.makeWebSocketOptions()
        #expect(ws.maximumMessageSize == 16_777_216 && ws.autoReplyPing == true)
    }
    @Test func clientPingGetsAPong() async throws {
        let (server, port, token, _) = try await makeServer()
        let client = try await TestClient.connect(port: port)
        try await client.hello(token: token)
        _ = await client.next()
        #expect(await client.ping())
        await server.stop()
    }
    @Test func messageLimitIsEnforcedAt16MiB() async throws {
        let (server, port, token, _) = try await makeServer()
        let client = try await TestClient.connect(port: port)
        try await client.hello(token: token)
        _ = await client.next()
        try await client.send(text: String(repeating: "x", count: 16_000_000))   // under: ignored as junk, stays open
        #expect(await client.ping())
        try? await client.send(text: String(repeating: "x", count: 16_777_217))  // over: the connection dies
        #expect(await client.isClosed(timeout: .seconds(3)))
        await server.stop()
    }
    @Test func standardTimings() {
        #expect(BridgeTimings.standard == BridgeTimings(helloTimeout: .seconds(5), pingInterval: .seconds(20),
                                                        drivePdfTimeout: BridgeConstants.drivePdfTimeout, viewerTimeout: BridgeConstants.viewerRequestTimeout))
    }
    @Test func startCreatesTokenAndReturnsBoundPort() async throws {
        let secrets = FakeSecretStore()
        let server = BridgeServer(secrets: secrets, blocklist: .starter, ports: [0], appVersion: "test-1.0")
        #expect(try await server.start() > 0)
        #expect(secrets.secret(for: SecretKey.bridgeToken)?.count == 64)
        await server.stop()
    }
    @Test func skipsPortInUse() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let blocker = try NWListener(using: parameters)
        blocker.newConnectionHandler = { $0.cancel() }
        let queue = DispatchQueue(label: "test.blocker")
        let P: UInt16 = await withCheckedContinuation { continuation in
            blocker.stateUpdateHandler = { state in
                if case .ready = state { continuation.resume(returning: blocker.port!.rawValue); blocker.stateUpdateHandler = nil }
            }
            blocker.start(queue: queue)
        }
        defer { blocker.cancel() }

        let a = BridgeServer(secrets: FakeSecretStore(), blocklist: .starter, ports: [P, 0], appVersion: "t")
        #expect(try await a.start() != P)
        await a.stop()
        let b = BridgeServer(secrets: FakeSecretStore(), blocklist: .starter, ports: [P], appVersion: "t")
        await expectBridgeError(.internal) { _ = try await b.start() }
    }
    @Test func goodTokenGetsHelloAckThenConfig() async throws {
        var blocklist = BlocklistConfig.starter; blocklist.domains.append("example-homework.test")
        let (server, port, token, _) = try await makeServer(blocklist: blocklist)
        let client = try await TestClient.connect(port: port)
        try await client.hello(token: token)
        #expect(await client.next() == .helloAck(appVersion: "test-1.0"))
        #expect(await client.next() == .config(blocklist: blocklist))
        await server.stop()
    }
    @Test func wrongTokenIsClosed4001() async throws {
        let (server, port, _, _) = try await makeServer()
        let client = try await TestClient.connect(port: port)
        try await client.hello(token: String(repeating: "0", count: 64))
        #expect(await client.closeCode() == 4001)
        #expect(await client.next(timeout: .zero) == nil)
        await server.stop()
    }
    @Test func silenceIsClosed4001AfterHelloTimeout() async throws {
        var timings = BridgeTimings.fast; timings.helloTimeout = .milliseconds(200)
        let (server, port, _, _) = try await makeServer(timings: timings)
        let started = ContinuousClock.now
        let client = try await TestClient.connect(port: port)
        #expect(await client.closeCode(timeout: .seconds(2)) == 4001)
        #expect(ContinuousClock.now - started >= .milliseconds(150))
        await server.stop()
    }
    @Test func firstMessageMustBeHello() async throws {
        let (server, port, _, _) = try await makeServer()
        let client = try await TestClient.connect(port: port)
        try await client.send(fixture: "ext-tabActivated.json")
        #expect(await client.closeCode() == 4001)
        await server.stop()
    }
    @Test func binaryFirstFrameIsClosed4001() async throws {
        let (server, port, _, _) = try await makeServer()
        let client = try await TestClient.connect(port: port)
        try await client.send(binary: Data([1, 2, 3]))
        #expect(await client.closeCode() == 4001)
        await server.stop()
    }
    @Test func undecodableFirstFrameIsClosed4001() async throws {
        let (server, port, _, _) = try await makeServer()
        let client = try await TestClient.connect(port: port)
        try await client.send(text: "not json")
        #expect(await client.closeCode() == 4001)
        await server.stop()
    }
    @Test func versionMismatchIsClosed4002() async throws {
        let (server, port, token, _) = try await makeServer()
        let client = try await TestClient.connect(port: port)
        try await client.send(text: #"{"v":2,"type":"hello","token":"\#(token)","extensionVersion":"9.0","browserName":"Dia"}"#)
        #expect(await client.closeCode() == 4002)
        await server.stop()
    }
    @Test func stopClosesWith1001() async throws {
        let (server, port, token, _) = try await makeServer()
        let client = try await TestClient.connect(port: port)
        try await client.hello(token: token)
        _ = await client.next()
        await server.stop()
        #expect(await client.closeCode() == 1001)
    }
}
