import CompanionCore
import CompanionTestSupport
import Foundation
import Testing
@testable import CompanionBridge

/// Decodes an inline wire message.
func ext(_ json: String) throws -> ExtensionToApp {
    try JSONDecoder().decode(ExtensionToApp.self, from: Data(json.utf8))
}

/// Decodes `contracts/fixtures/<name>`.
func fixtureMessage(_ name: String) throws -> ExtensionToApp {
    try JSONDecoder().decode(ExtensionToApp.self, from: Fixtures.bridgeFixture(name))
}

/// The `.tabContext` payload of a fixture.
func fixtureContext(_ name: String) throws -> TabContext {
    guard case .tabContext(let context) = try fixtureMessage(name) else {
        throw BridgeError(code: .internal, message: "\(name) is not a tabContext fixture")
    }
    return context
}

func jsonString(_ value: some Encodable) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

/// Records an issue unless `body` throws a `BridgeError` with `code`.
func expectBridgeError(_ code: BridgeErrorCode, sourceLocation: SourceLocation = #_sourceLocation,
                       _ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("Expected BridgeError(\(code)), but nothing was thrown", sourceLocation: sourceLocation)
    } catch let error as BridgeError {
        #expect(error.code == code, "\(error.message)", sourceLocation: sourceLocation)
    } catch {
        Issue.record("Expected BridgeError(\(code)), got \(error)", sourceLocation: sourceLocation)
    }
}

extension BridgeTimings {
    static let fast = BridgeTimings(helloTimeout: .seconds(1), pingInterval: .seconds(60),
                                    drivePdfTimeout: .seconds(3), viewerTimeout: .seconds(1))
}

/// A started server on an ephemeral port with appVersion "test-1.0".
func makeServer(timings: BridgeTimings = .fast, blocklist: BlocklistConfig = .starter) async throws
    -> (server: BridgeServer, port: UInt16, token: String, secrets: FakeSecretStore) {
    let secrets = FakeSecretStore()
    let server = BridgeServer(secrets: secrets, blocklist: blocklist, ports: [0], appVersion: "test-1.0", timings: timings)
    let port = try await server.start()
    return (server, port, try BridgePairing.token(in: secrets), secrets)
}

/// Polls `probe` every 10 ms until it returns non-nil or `timeout` passes.
func eventually<T: Sendable>(timeout: Duration = .seconds(2), _ probe: @Sendable () async -> T?) async -> T? {
    let deadline = ContinuousClock.now + timeout
    while true {
        if let value = await probe() { return value }
        if ContinuousClock.now >= deadline { return nil }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
