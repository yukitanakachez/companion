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
