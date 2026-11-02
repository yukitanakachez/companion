import CompanionCore
import CompanionTestSupport
import Foundation
import Testing
@testable import CompanionBridge

@Suite struct FrameCodecTests {
    @Test func decodesEveryExtensionFixture() throws {
        for name in try Fixtures.allBridgeFixtureNames() where name.hasPrefix("ext-") {
            _ = try FrameCodec.decodeText(Fixtures.bridgeFixture(name))
        }
    }
    @Test func encodesTheWireShape() throws {
        let encoded = try JSONSerialization.jsonObject(with: FrameCodec.encode(.ping)) as? NSDictionary
        #expect(encoded == (try JSONSerialization.jsonObject(with: Fixtures.bridgeFixture("app-ping.json")) as? NSDictionary))
    }
    @Test func versionIsCheckedBeforeType() async throws {
        await expectBridgeError(.versionMismatch) { _ = try FrameCodec.decodeText(Fixtures.bridgeFixture("invalid-version.json")) }
        await expectBridgeError(.versionMismatch) {
            _ = try FrameCodec.decodeText(Data(#"{"v":2,"type":"hello","token":"x","extensionVersion":"9.0","browserName":"Dia"}"#.utf8))
        }
    }
    @Test func malformedTextIsNotAVersionMismatch() {
        let error = #expect(throws: (any Error).self) { try FrameCodec.decodeText(Data("not json".utf8)) }
        #expect((error as? BridgeError)?.code != .versionMismatch)
    }
}
