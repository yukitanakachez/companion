import CompanionCore
import CompanionTestSupport
import Foundation
import Testing
@testable import CompanionBridge

@Suite struct KeepAliveStatusTests {
    private func handshaken(port: UInt16, token: String, browserName: String = "Dia") async throws -> TestClient {
        let client = try await TestClient.connect(port: port)
        try await client.hello(token: token, browserName: browserName)
        guard case .helloAck = await client.next(), case .config = await client.next() else {
            throw BridgeError(code: .unauthorized, message: "Handshake failed")
        }
        return client
    }

    @Test func authenticatedSessionsArePinged() async throws {
        var timings = BridgeTimings.fast; timings.pingInterval = .milliseconds(100)
        let (server, port, token, _) = try await makeServer(timings: timings)
        let client = try await handshaken(port: port, token: token)
        #expect(await client.next(timeout: .seconds(1)) == .ping)
        #expect(await client.next(timeout: .seconds(1)) == .ping)
        await server.stop()
    }
    @Test func unauthenticatedSessionsAreNotPinged() async throws {
        var timings = BridgeTimings.fast; timings.pingInterval = .milliseconds(50); timings.helloTimeout = .seconds(2)
        let (server, port, _, _) = try await makeServer(timings: timings)
        let client = try await TestClient.connect(port: port)
        #expect(await client.next(timeout: .milliseconds(400)) == nil)
        await server.stop()
    }
    @Test func updateBlocklistReachesEverySession() async throws {
        let (server, port, token, _) = try await makeServer()
        let a = try await handshaken(port: port, token: token)
        let b = try await handshaken(port: port, token: token, browserName: "Chrome")
        var blocklist = BlocklistConfig.starter; blocklist.domains.append("example-homework.test")
        await server.updateBlocklist(blocklist)
        #expect(await a.next() == .config(blocklist: blocklist))
        #expect(await b.next() == .config(blocklist: blocklist))
        let c = try await TestClient.connect(port: port)
        try await c.hello(token: token)
        #expect(await c.next() == .helloAck(appVersion: "test-1.0"))
        #expect(await c.next() == .config(blocklist: blocklist))
        await server.stop()
    }
    @Test func statusListsPortAndBrowsers() async throws {
        let secrets = FakeSecretStore()
        let server = BridgeServer(secrets: secrets, blocklist: .starter, ports: [0], appVersion: "test-1.0", timings: .fast)
        let before = await server.status()
        #expect(before.port == nil && before.connectedBrowsers.isEmpty)
        let port = try await server.start()
        let token = try BridgePairing.token(in: secrets)
        let dia = try await handshaken(port: port, token: token)
        let chrome = try await handshaken(port: port, token: token, browserName: "Chrome")
        let silent = try await TestClient.connect(port: port)   // never sends hello
        let during = await server.status()
        #expect(during.port == port && during.connectedBrowsers == ["Dia", "Chrome"])
        dia.disconnect()
        #expect(await eventually { let s = await server.status(); return s.connectedBrowsers == ["Chrome"] ? true : nil } == true)
        await server.stop()
        let after = await server.status()
        #expect(after.port == nil && after.connectedBrowsers.isEmpty)
        chrome.disconnect(); silent.disconnect()
    }
    @Test func regeneratedTokenOnlyAffectsNewConnections() async throws {
        var timings = BridgeTimings.fast; timings.pingInterval = .milliseconds(100)
        let (server, port, token, secrets) = try await makeServer(timings: timings)
        let a = try await handshaken(port: port, token: token)
        let fresh = try BridgePairing.regenerate(in: secrets)
        #expect(await a.next(timeout: .seconds(1)) == .ping)
        let old = try await TestClient.connect(port: port)
        try await old.hello(token: token)
        #expect(await old.closeCode() == 4001)
        let new = try await TestClient.connect(port: port)
        try await new.hello(token: fresh)
        #expect(await new.next() == .helloAck(appVersion: "test-1.0"))
        await server.stop()
    }
    @Test func stopThenStartServesAgain() async throws {
        let (server, _, token, _) = try await makeServer()
        await server.stop()
        let port = try await server.start()
        let client = try await handshaken(port: port, token: token)
        #expect(await server.status().connectedBrowsers == ["Dia"])
        client.disconnect()
        await server.stop()
    }
}
