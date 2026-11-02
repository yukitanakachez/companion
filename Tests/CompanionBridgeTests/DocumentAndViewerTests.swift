import CompanionCore
import CompanionTestSupport
import Foundation
import Testing
@testable import CompanionBridge

private let fileId = "1AbCdEfGhIjKlMnOpQrStUvWxYz012345"
private let pdf = ChunkAssemblerTests.pdf
private func pdfResult(byteLength: Int = 2_621_440, fileId: String = fileId) -> String {
    #"{"fileId":"\#(fileId)","title":"Algebra 2 Textbook.pdf","byteLength":\#(byteLength)}"#
}

@Suite struct DocumentAndViewerTests {
    @Test func fetchesPdfStreamedInThreeChunks() async throws {
        let (server, port, token, _) = try await makeServer()
        let dia = try await ScriptedExtension.connect(port: port, token: token)
        let got = Task { try await server.documentFetcher.fetchDrivePDF(fileId: fileId) }
        let req = try #require(await dia.nextRequest())
        #expect(req == .fetchDrivePdf(id: req.id, fileId: fileId))
        try await dia.sendChunks(id: req.id, data: pdf, order: [2, 0, 1])
        try await dia.respond(id: req.id, resultJSON: pdfResult())
        let (data, title) = try await got.value
        #expect(data == pdf && title == "Algebra 2 Textbook.pdf")
        await server.stop()
    }
    @Test func downloadBlockedIsThrown() async throws {
        let (server, port, token, _) = try await makeServer()
        let dia = try await ScriptedExtension.connect(port: port, token: token)
        let got = Task { try await server.documentFetcher.fetchDrivePDF(fileId: fileId) }
        let req = try #require(await dia.nextRequest())
        try await dia.respondError(id: req.id, code: "downloadBlocked", message: "The owner has disabled downloads for this file.")
        await expectBridgeError(.downloadBlocked) { _ = try await got.value }
        await server.stop()
    }
    @Test func byteLengthMismatchThrows() async throws {                                                              // Review Focus 5
        let (server, port, token, _) = try await makeServer()
        let dia = try await ScriptedExtension.connect(port: port, token: token)
        let got = Task { try await server.documentFetcher.fetchDrivePDF(fileId: fileId) }
        let req = try #require(await dia.nextRequest())
        try await dia.sendChunks(id: req.id, data: pdf)
        try await dia.respond(id: req.id, resultJSON: pdfResult(byteLength: 2_097_152))
        await expectBridgeError(.internal) { _ = try await got.value }
        await server.stop()
    }
    @Test func missingChunkThrowsInsteadOfTruncating() async throws {                                                 // Review Focus 5
        let (server, port, token, _) = try await makeServer()
        let dia = try await ScriptedExtension.connect(port: port, token: token)
        let got = Task { try await server.documentFetcher.fetchDrivePDF(fileId: fileId) }
        let req = try #require(await dia.nextRequest())
        try await dia.sendChunks(id: req.id, data: pdf, order: [0, 2])
        try await dia.respond(id: req.id, resultJSON: pdfResult())
        await expectBridgeError(.internal) { _ = try await got.value }
        await server.stop()
    }
    @Test func wrongFileIdThrows() async throws {
        let (server, port, token, _) = try await makeServer()
        let dia = try await ScriptedExtension.connect(port: port, token: token)
        let got = Task { try await server.documentFetcher.fetchDrivePDF(fileId: fileId) }
        let req = try #require(await dia.nextRequest())
        try await dia.respond(id: req.id, resultJSON: pdfResult(byteLength: 0, fileId: "someOtherFile"))
        await expectBridgeError(.internal) { _ = try await got.value }
        await server.stop()
    }
    @Test func disconnectMidTransferFailsFast() async throws {                                                        // Review Focus 4
        var timings = BridgeTimings.fast; timings.drivePdfTimeout = .seconds(30)
        let (server, port, token, _) = try await makeServer(timings: timings)
        let dia = try await ScriptedExtension.connect(port: port, token: token)
        let started = ContinuousClock.now
        let got = Task { try await server.documentFetcher.fetchDrivePDF(fileId: fileId) }
        let req = try #require(await dia.nextRequest())
        try await dia.sendChunks(id: req.id, data: pdf, order: [0, 1])
        dia.disconnect()
        await expectBridgeError(.notConnected) { _ = try await got.value }
        #expect(ContinuousClock.now - started < .seconds(1))

        let again = try await ScriptedExtension.connect(port: port, token: token)
        let second = Task { try await server.documentFetcher.fetchDrivePDF(fileId: fileId) }
        let retry = try #require(await again.nextRequest())
        try await again.sendChunks(id: retry.id, data: pdf)
        try await again.respond(id: retry.id, resultJSON: pdfResult())
        #expect(try await second.value.data == pdf)
        await server.stop()
    }
    @Test func noBrowserThrowsNotConnected() async throws {
        let (server, _, _, _) = try await makeServer()
        await expectBridgeError(.notConnected) { _ = try await server.documentFetcher.fetchDrivePDF(fileId: fileId) }
        await expectBridgeError(.notConnected) { _ = try await server.viewerDriver.viewerInfo(tabId: 34) }
        await server.stop()
    }
    @Test func notConnectedMessageMatchesTheSpec() async throws {
        let (server, _, _, _) = try await makeServer()
        do {
            _ = try await server.documentFetcher.fetchDrivePDF(fileId: fileId)
            Issue.record("expected throw")
        } catch {
            #expect((error as? BridgeError)?.message == "Extension not connected")
        }
        await server.stop()
    }
    @Test func requestTimeoutsUseInjectedValues() async throws {
        var timings = BridgeTimings.fast
        timings.drivePdfTimeout = .milliseconds(200); timings.viewerTimeout = .milliseconds(200)
        let (server, port, token, _) = try await makeServer(timings: timings)
        _ = try await ScriptedExtension.connect(port: port, token: token)
        await expectBridgeError(.timeout) { _ = try await server.documentFetcher.fetchDrivePDF(fileId: fileId) }
        await expectBridgeError(.timeout) { _ = try await server.viewerDriver.viewerInfo(tabId: 34) }
        await server.stop()
    }
    @Test func viewerInfoCaptureAndRestore() async throws {
        let (server, port, token, _) = try await makeServer()
        let dia = try await ScriptedExtension.connect(port: port, token: token)

        let info = Task { try await server.viewerDriver.viewerInfo(tabId: 34) }
        let infoReq = try #require(await dia.nextRequest())
        #expect(infoReq == .viewerInfo(id: infoReq.id, tabId: 34))
        try await dia.respond(id: infoReq.id, resultJSON: #"{"pageCount":412,"currentIndex":87}"#)
        #expect(try await info.value == ViewerInfo(pageCount: 412, currentIndex: 87))

        let sample = Fixtures.samplePNG(width: 4, height: 3)
        let page = Task { try await server.viewerDriver.capturePage(tabId: 34, pageIndex: 246) }
        let pageReq = try #require(await dia.nextRequest())
        #expect(pageReq == .viewerCapturePage(id: pageReq.id, tabId: 34, pageIndex: 246))
        try await dia.respond(id: pageReq.id, resultJSON: #"{"pageIndex":246,"pngBase64":"\#(sample.png.base64EncodedString())"}"#)
        let image = try await page.value
        #expect(image.pixelWidth == 4 && image.pixelHeight == 3 && image.png == sample.png)

        let restored = Task { try await server.viewerDriver.restore(tabId: 34, pageIndex: 87) }
        let restoreReq = try #require(await dia.nextRequest())
        #expect(restoreReq == .viewerRestore(id: restoreReq.id, tabId: 34, pageIndex: 87))
        try await dia.respond(id: restoreReq.id, resultJSON: "{}")
        try await restored.value
        await server.stop()
    }
    @Test func badCaptureThrowsInternal() async throws {
        let (server, port, token, _) = try await makeServer()
        let dia = try await ScriptedExtension.connect(port: port, token: token)
        let bad = Task { try await server.viewerDriver.capturePage(tabId: 34, pageIndex: 246) }
        let first = try #require(await dia.nextRequest())
        try await dia.respond(id: first.id, resultJSON: #"{"pageIndex":246,"pngBase64":"not-base64!"}"#)
        await expectBridgeError(.internal) { _ = try await bad.value }

        let sample = Fixtures.samplePNG().png.base64EncodedString()
        let wrongPage = Task { try await server.viewerDriver.capturePage(tabId: 34, pageIndex: 246) }
        let second = try #require(await dia.nextRequest())
        try await dia.respond(id: second.id, resultJSON: #"{"pageIndex":245,"pngBase64":"\#(sample)"}"#)
        await expectBridgeError(.internal) { _ = try await wrongPage.value }

        let notAnImage = Task { try await server.viewerDriver.capturePage(tabId: 34, pageIndex: 246) }
        let third = try #require(await dia.nextRequest())
        try await dia.respond(id: third.id, resultJSON: #"{"pageIndex":246,"pngBase64":"\#(Data("hello".utf8).base64EncodedString())"}"#)
        await expectBridgeError(.internal) { _ = try await notAnImage.value }
        await server.stop()
    }
    @Test func malformedResultThrowsInternal() async throws {
        let (server, port, token, _) = try await makeServer()
        let dia = try await ScriptedExtension.connect(port: port, token: token)
        let info = Task { try await server.viewerDriver.viewerInfo(tabId: 34) }
        let req = try #require(await dia.nextRequest())
        try await dia.respond(id: req.id, resultJSON: #"{"unexpected":true}"#)
        await expectBridgeError(.internal) { _ = try await info.value }
        await server.stop()
    }
    @Test func viewerRequestsGoToTheTabsBrowser() async throws {                                                      // Review Focus 2
        let (server, port, token, _) = try await makeServer()
        let dia = try await ScriptedExtension.connect(port: port, token: token)
        try await dia.push(fixture: "ext-tabContext-drive.json")
        #expect(await eventually { await server.cache.connection(forTab: 34) } != nil)
        let chrome = try await ScriptedExtension.connect(port: port, token: token, browserName: "Chrome")
        try await chrome.push(try ext(#"{"v":1,"type":"tabActivated","tabId":5,"windowId":1,"url":"https://example.test/","title":"Other"}"#))
        #expect(await eventually { await server.cache.activeConnection() } != nil)

        let info = Task { try await server.viewerDriver.viewerInfo(tabId: 34) }
        let req = try #require(await dia.nextRequest())
        #expect(await chrome.nextRequest(timeout: .milliseconds(300)) == nil)
        try await dia.respond(id: req.id, resultJSON: #"{"pageCount":1,"currentIndex":0}"#)
        _ = try await info.value
        await server.stop()
    }
}
