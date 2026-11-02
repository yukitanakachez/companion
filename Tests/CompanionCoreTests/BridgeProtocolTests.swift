import CompanionCore
import CompanionTestSupport
import Foundation
import Testing

private func decodeExt(_ name: String) throws -> ExtensionToApp {
    try JSONDecoder().decode(ExtensionToApp.self, from: Fixtures.bridgeFixture(name))
}
private func decodeApp(_ name: String) throws -> AppToExtension {
    try JSONDecoder().decode(AppToExtension.self, from: Fixtures.bridgeFixture(name))
}

@Test func everyExtensionFixtureDecodesAndRoundTrips() throws {
    for name in try Fixtures.allBridgeFixtureNames() where name.hasPrefix("ext-") {
        let msg = try JSONDecoder().decode(ExtensionToApp.self, from: Fixtures.bridgeFixture(name))
        let again = try JSONDecoder().decode(ExtensionToApp.self, from: JSONEncoder().encode(msg))
        #expect(again == msg, "\(name)")
    }
}

@Test func everyAppFixtureDecodesAndRoundTrips() throws {
    for name in try Fixtures.allBridgeFixtureNames() where name.hasPrefix("app-") {
        let msg = try JSONDecoder().decode(AppToExtension.self, from: Fixtures.bridgeFixture(name))
        let again = try JSONDecoder().decode(AppToExtension.self, from: JSONEncoder().encode(msg))
        #expect(again == msg, "\(name)")
    }
}

/// Stronger than decode → encode → decode: Swift's output must be the same JSON as the fixture,
/// because the TypeScript side reads what Swift writes.
@Test func encodedMessagesMatchFixtureJSONExactly() throws {
    for name in try Fixtures.allBridgeFixtureNames() where !name.hasPrefix("invalid-") {
        let fixture = try Fixtures.bridgeFixture(name)
        let encoded = name.hasPrefix("ext-")
            ? try JSONEncoder().encode(try decodeExt(name))
            : try JSONEncoder().encode(try decodeApp(name))
        let expected = try JSONDecoder().decode(JSONValue.self, from: fixture)
        let actual = try JSONDecoder().decode(JSONValue.self, from: encoded)
        #expect(actual == expected, "\(name)")
    }
}

@Test func youtubeFixtureValues() throws {
    guard case .tabContext(let ctx) = try decodeExt("ext-tabContext-youtube.json") else { Issue.record("wrong case"); return }
    #expect(ctx.youtube?.playheadSeconds == 761)
    #expect(ctx.youtube?.transcript.count == 3)
    #expect(ctx.youtube?.transcriptStatus == .available)
}

@Test func blockedFixtureHasNoContent() throws {
    guard case .tabContext(let ctx) = try decodeExt("ext-tabContext-blocked.json") else { Issue.record("wrong case"); return }
    #expect(ctx.blocked)
    #expect(ctx.page == nil && ctx.youtube == nil && ctx.classroom == nil && ctx.drive == nil)
}

@Test func requestFixtures() throws {
    #expect(try decodeApp("app-request-fetchDrivePdf.json") == .request(.fetchDrivePdf(id: "r-2", fileId: "1AbCdEfGhIjKlMnOpQrStUvWxYz012345")))
    #expect(try decodeApp("app-request-getTabContext.json") == .request(.getTabContext(id: "r-1", tabId: nil)))
    #expect(try decodeApp("app-request-viewerInfo.json") == .request(.viewerInfo(id: "r-4", tabId: 34)))
    #expect(try decodeApp("app-request-viewerCapturePage.json") == .request(.viewerCapturePage(id: "r-5", tabId: 34, pageIndex: 246)))
    #expect(try decodeApp("app-request-viewerRestore.json") == .request(.viewerRestore(id: "r-6", tabId: 34, pageIndex: 87)))
}

@Test func requestIdAndMethod() {
    let cases: [(BridgeRequest, String, String)] = [
        (.getTabContext(id: "a", tabId: nil), "a", "getTabContext"),
        (.fetchDrivePdf(id: "b", fileId: "f"), "b", "fetchDrivePdf"),
        (.viewerInfo(id: "c", tabId: 1), "c", "viewerInfo"),
        (.viewerCapturePage(id: "d", tabId: 1, pageIndex: 2), "d", "viewerCapturePage"),
        (.viewerRestore(id: "e", tabId: 1, pageIndex: 2), "e", "viewerRestore"),
    ]
    for (request, id, method) in cases {
        #expect(request.id == id)
        #expect(request.method == method)
    }
}

@Test func simpleMessageFixtures() throws {
    #expect(try decodeApp("app-helloAck.json") == .helloAck(appVersion: "0.1.0"))
    #expect(try decodeApp("app-ping.json") == .ping)
    #expect(try decodeApp("app-config.json") == .config(blocklist: BlocklistConfig(bundleIDs: ["com.1password.1password"], domains: ["chase.com", "1password.com"])))
    #expect(try decodeExt("ext-tabClosed.json") == .tabClosed(tabId: 12))
    #expect(try decodeExt("ext-progress.json") == .progress(ProgressMessage(id: "r-5", step: "Viewer page 240 of 412")))
    #expect(try decodeExt("ext-youtubePlayhead.json") == .youtubePlayhead(YouTubePlayheadMessage(tabId: 12, videoId: "abc123XYZ00", playheadSeconds: 766.5, chapter: "Finding the roots")))
    #expect(try decodeExt("ext-tabActivated.json") == .tabActivated(TabActivatedMessage(tabId: 12, windowId: 3, url: "https://www.youtube.com/watch?v=abc123XYZ00", title: "Solving Quadratics by Factoring - YouTube")))
    #expect(try decodeExt("ext-hello.json") == .hello(HelloMessage(token: "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0", extensionVersion: "0.1.0", browserName: "Dia")))
}

@Test func responseResults() throws {
    guard case .response(let r) = try decodeExt("ext-response-viewerInfo.json") else { Issue.record("wrong case"); return }
    #expect(try r.decodeResult(ViewerInfo.self) == ViewerInfo(pageCount: 412, currentIndex: 87))
    guard case .response(let e) = try decodeExt("ext-response-downloadBlocked.json") else { Issue.record("wrong case"); return }
    #expect(e.ok == false && e.error?.code == .downloadBlocked)
}

@Test func typedResultsDecodeFromFixtures() throws {
    guard case .response(let tab) = try decodeExt("ext-response-tabContext.json"),
          case .response(let pdf) = try decodeExt("ext-response-drivePdf.json"),
          case .response(let page) = try decodeExt("ext-response-viewerPage.json") else { Issue.record("wrong case"); return }
    #expect(try tab.decodeResult(TabContextResult.self) == TabContextResult(context: nil))
    #expect(try pdf.decodeResult(DrivePdfResult.self) == DrivePdfResult(fileId: "1AbCdEfGhIjKlMnOpQrStUvWxYz012345", title: "Algebra 2 Textbook.pdf", byteLength: 2097152))
    #expect(try page.decodeResult(ViewerPageResult.self).pageIndex == 246)
}

@Test func emptyResultFromNull() throws {
    let r = BridgeResponse(id: "r-6", ok: true, result: nil, error: nil)
    #expect(try r.decodeResult(EmptyResult.self) == EmptyResult())
}

@Test func emptyResultFromEmptyObject() throws {
    let r = BridgeResponse(id: "r-6", ok: true, result: .object([:]), error: nil)
    #expect(try r.decodeResult(EmptyResult.self) == EmptyResult())
}

@Test func versionMismatchThrows() throws {
    #expect(throws: BridgeError.self) { try JSONDecoder().decode(AppToExtension.self, from: Fixtures.bridgeFixture("invalid-version.json")) }
    do {
        _ = try JSONDecoder().decode(ExtensionToApp.self, from: Fixtures.bridgeFixture("invalid-version.json"))
        Issue.record("expected a throw")
    } catch let error as BridgeError {
        #expect(error.code == .versionMismatch)
    }
}

@Test func versionIsCheckedBeforeType() {
    let data = Data(#"{"v":2,"type":"somethingNew"}"#.utf8)
    #expect(throws: BridgeError.self) { try JSONDecoder().decode(ExtensionToApp.self, from: data) }
}

@Test func unknownTypeAndMethodAreRejected() {
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(AppToExtension.self, from: Data(#"{"v":1,"type":"nope"}"#.utf8)) }
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(ExtensionToApp.self, from: Data(#"{"v":1,"type":"ping"}"#.utf8)) }
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(AppToExtension.self, from: Data(#"{"v":1,"type":"request","id":"x","method":"nope","params":{}}"#.utf8)) }
}

@Test func binaryFrameRoundTrip() throws {
    let header = BinaryFrameHeader(id: "r-2", seq: 0, last: true)
    let frame = try BinaryFrame.encode(header: header, payload: Data([0x25, 0x50, 0x44, 0x46]))
    let headerLen = frame.prefix(4).reduce(0) { $0 << 8 | Int($1) }
    #expect(headerLen == frame.count - 4 - 4)
    let decoded = try BinaryFrame.decode(frame)
    #expect(decoded.header == header && decoded.payload == Data([0x25, 0x50, 0x44, 0x46]))
}

@Test func binaryFrameHandlesDataSlices() throws {
    let header = BinaryFrameHeader(id: "r-2", seq: 1, last: false)
    let source = Data([9, 9, 1, 2, 3])
    let frame = try BinaryFrame.encode(header: header, payload: source[2...])
    let padded = Data([0, 0, 0]) + frame
    let decoded = try BinaryFrame.decode(padded[3...])
    #expect(decoded.header == header)
    #expect(Array(decoded.payload) == [1, 2, 3])
}

@Test func binaryFrameAllowsChunkAtTheLimitAndRejectsOverIt() throws {
    let header = BinaryFrameHeader(id: "r", seq: 0, last: true)
    let atLimit = try BinaryFrame.encode(header: header, payload: Data(count: BridgeConstants.maxChunkBytes))
    #expect(try BinaryFrame.decode(atLimit).payload.count == BridgeConstants.maxChunkBytes)
    #expect(throws: BridgeError.self) { try BinaryFrame.encode(header: header, payload: Data(count: BridgeConstants.maxChunkBytes + 1)) }
    #expect(throws: BridgeError.self) { try BinaryFrame.decode(atLimit + Data([0])) }
}

@Test func malformedBinaryFramesThrow() {
    #expect(throws: BridgeError.self) { try BinaryFrame.decode(Data([0, 0])) }
    #expect(throws: BridgeError.self) { try BinaryFrame.decode(Data([0, 0, 0, 9, 1])) }
    #expect(throws: BridgeError.self) { try BinaryFrame.decode(Data([0xFF, 0xFF, 0xFF, 0xFF, 1])) }
    #expect(throws: BridgeError.self) { try BinaryFrame.decode(Data([0, 0, 0, 1, 0x7B])) }
}

@Test func constants() {
    #expect(BridgeConstants.protocolVersion == 1)
    #expect(BridgeConstants.ports == [47823, 47824, 47825, 47826, 47827])
    #expect(BridgeConstants.maxChunkBytes == 1_048_576)
    #expect(BridgeConstants.helloTimeout == .seconds(5))
    #expect(BridgeConstants.hotPathTimeout == .milliseconds(300))
    #expect(BridgeConstants.pingInterval == .seconds(20))
    #expect(BridgeConstants.drivePdfTimeout == .seconds(120))
    #expect(BridgeConstants.viewerRequestTimeout == .seconds(10))
    #expect(BridgeConstants.closeCodeUnauthorized == 4001)
    #expect(BridgeConstants.closeCodeVersionMismatch == 4002)
}

@Test func jsonValueRoundTripsEveryCase() throws {
    let value = JSONValue.object(["a": .null, "b": .bool(true), "c": .number(1.5), "d": .string("s"), "e": .array([.number(1), .bool(false)])])
    #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
}
