import CompanionCore
import Foundation
import Testing
@testable import CompanionBridge

@Suite struct BrowserContextTests {
    private func mathResult(_ context: TabContext) throws -> String { "{\"context\":" + (try jsonString(context)) + "}" }

    @Test func pushedContextIsCached() async throws {
        let (server, port, token, _) = try await makeServer()
        let dia = try await ScriptedExtension.connect(port: port, token: token)
        try await dia.push(fixture: "ext-tabActivated.json"); try await dia.push(fixture: "ext-tabContext-youtube.json")
        #expect(await eventually { await server.browserContext.cachedActiveTabContext() }?.youtube?.playheadSeconds == 761)
        #expect(await server.browserContext.isConnected())
        await server.stop()
    }
    @Test func requestActiveTabContextAsksTheExtension() async throws {
        let (server, port, token, _) = try await makeServer()
        let dia = try await ScriptedExtension.connect(port: port, token: token)
        let math = try fixtureContext("ext-tabContext-math.json")
        async let result = server.browserContext.requestActiveTabContext(timeout: .seconds(2))
        let req = try #require(await dia.nextRequest())
        #expect(req == .getTabContext(id: req.id, tabId: nil))
        try await dia.respond(id: req.id, resultJSON: try mathResult(math))
        #expect(await result == math)
        #expect(await server.browserContext.cachedActiveTabContext() == math)
        await server.stop()
    }
    @Test func nullContextResponseIsNil() async throws {
        let (server, port, token, _) = try await makeServer()
        let dia = try await ScriptedExtension.connect(port: port, token: token)
        async let result = server.browserContext.requestActiveTabContext(timeout: .seconds(2))
        let req = try #require(await dia.nextRequest())
        try await dia.respond(id: req.id, resultJSON: #"{"context":null}"#)
        #expect(await result == nil)
        #expect(await server.browserContext.cachedActiveTabContext() == nil)
        await server.stop()
    }
    @Test func noBrowserMeansNilAndNotConnected() async throws {
        let (server, _, _, _) = try await makeServer()
        let started = ContinuousClock.now
        #expect(await server.browserContext.requestActiveTabContext(timeout: .milliseconds(300)) == nil)
        #expect(ContinuousClock.now - started < .milliseconds(100))
        #expect(await server.browserContext.isConnected() == false)
        await server.stop()
    }
    @Test func silentExtensionReturnsNilWithinTimeout() async throws {   // Review Focus 3
        let (server, port, token, _) = try await makeServer()
        let dia = try await ScriptedExtension.connect(port: port, token: token)
        let math = try fixtureContext("ext-tabContext-math.json")
        let started = ContinuousClock.now
        async let silent = server.browserContext.requestActiveTabContext(timeout: .milliseconds(300))
        let first = try #require(await dia.nextRequest())
        #expect(await silent == nil)
        #expect(ContinuousClock.now - started < .milliseconds(550))

        try await dia.respond(id: first.id, resultJSON: try mathResult(math))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await server.browserContext.cachedActiveTabContext() == nil)

        async let second = server.browserContext.requestActiveTabContext(timeout: .seconds(2))
        let next = try #require(await dia.nextRequest())
        try await dia.respond(id: next.id, resultJSON: try mathResult(math))
        #expect(await second == math)
        await server.stop()
    }
    @Test func requestGoesOnlyToActiveBrowser() async throws {           // Review Focus 2
        let (server, port, token, _) = try await makeServer()
        let dia = try await ScriptedExtension.connect(port: port, token: token)
        try await dia.push(fixture: "ext-tabActivated.json"); try await dia.push(fixture: "ext-tabContext-youtube.json")
        #expect(await eventually { await server.browserContext.cachedActiveTabContext()?.youtube } != nil)

        let chrome = try await ScriptedExtension.connect(port: port, token: token, browserName: "Chrome")
        var math = try fixtureContext("ext-tabContext-math.json"); math.tabId = 12
        try await chrome.push(fixture: "ext-tabActivated.json"); try await chrome.push(.tabContext(math))
        #expect(await eventually { await server.browserContext.cachedActiveTabContext()?.page } != nil)

        async let result = server.browserContext.requestActiveTabContext(timeout: .seconds(2))
        let req = try #require(await chrome.nextRequest())
        #expect(await dia.nextRequest(timeout: .milliseconds(300)) == nil)
        try await chrome.respond(id: req.id, resultJSON: try mathResult(math))
        #expect(await result == math)

        chrome.disconnect()
        #expect(await eventually { await server.browserContext.cachedActiveTabContext()?.youtube }?.videoId == "abc123XYZ00")
        await server.stop()
    }
    @Test func disconnectClearsConnectionAndCache() async throws {
        let (server, port, token, _) = try await makeServer()
        let dia = try await ScriptedExtension.connect(port: port, token: token)
        try await dia.push(fixture: "ext-tabActivated.json"); try await dia.push(fixture: "ext-tabContext-youtube.json")
        #expect(await eventually { await server.browserContext.cachedActiveTabContext() } != nil)
        dia.disconnect()
        #expect(await eventually { await server.browserContext.isConnected() ? nil : true } == true)
        #expect(await server.browserContext.cachedActiveTabContext() == nil)
        await server.stop()
    }
    @Test func messagesSentJustBeforeDisconnectLeaveNothingBehind() async throws {
        let (server, port, token, _) = try await makeServer()
        for _ in 0..<20 {
            let dia = try await ScriptedExtension.connect(port: port, token: token)
            try await dia.push(fixture: "ext-tabActivated.json"); try await dia.push(fixture: "ext-tabContext-youtube.json")
            dia.disconnect()
        }
        #expect(await eventually { await server.browserContext.isConnected() ? nil : true } == true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await server.browserContext.cachedActiveTabContext() == nil)
        await server.stop()
    }
}
