import CompanionCore
import Testing
@testable import CompanionBridge

private let dia = ConnectionID(raw: 1)
private let chrome = ConnectionID(raw: 2)

@Suite struct ContextCacheTests {
    private func diaOnYouTube() async throws -> ContextCache {
        let cache = ContextCache()
        await cache.apply(try fixtureMessage("ext-tabActivated.json"), from: dia)
        await cache.apply(try fixtureMessage("ext-tabContext-youtube.json"), from: dia)
        return cache
    }
    private func activate(_ tabId: Int) throws -> ExtensionToApp {
        try ext(#"{"v":1,"type":"tabActivated","tabId":\#(tabId),"windowId":3,"url":"https://example-homework.test/unit4/q3","title":"Unit 4"}"#)
    }

    @Test func activeTabReturnsItsSnapshot() async throws {
        let cache = try await diaOnYouTube()
        #expect(await cache.activeTabContext()?.youtube?.videoId == "abc123XYZ00")
        #expect(await cache.activeConnection() == dia)
    }
    @Test func switchToTabWithoutContextIsNil() async throws {        // Review Focus 1
        let cache = try await diaOnYouTube()
        await cache.apply(try activate(21), from: dia)
        #expect(await cache.activeTabContext() == nil)
        await cache.apply(try fixtureMessage("ext-tabContext-math.json"), from: dia)
        #expect(await cache.activeTabContext()?.tabId == 21)
        await cache.apply(try activate(12), from: dia)
        #expect(await cache.activeTabContext()?.youtube?.videoId == "abc123XYZ00")
    }
    @Test func playheadUpdatesOnlyMatchingVideo() async throws {
        let cache = try await diaOnYouTube()
        await cache.apply(try fixtureMessage("ext-youtubePlayhead.json"), from: dia)
        #expect(await cache.activeTabContext()?.youtube?.playheadSeconds == 766.5)
        #expect(await cache.activeTabContext()?.youtube?.chapter == "Finding the roots")
        await cache.apply(try ext(#"{"v":1,"type":"youtubePlayhead","tabId":12,"videoId":"zzzzzzzzzzz","playheadSeconds":900}"#), from: dia)
        #expect(await cache.activeTabContext()?.youtube?.playheadSeconds == 766.5)
    }
    @Test func tabClosedDropsSnapshotAndActivation() async throws {
        let cache = try await diaOnYouTube()
        await cache.apply(try fixtureMessage("ext-tabClosed.json"), from: dia)
        #expect(await cache.activeTabContext() == nil)
        #expect(await cache.activeConnection() == nil)
    }
    @Test func blockedContextIsCachedVerbatim() async throws {
        let cache = ContextCache()
        await cache.apply(try activate(40), from: dia)
        await cache.apply(try fixtureMessage("ext-tabContext-blocked.json"), from: dia)
        #expect(await cache.activeTabContext()?.blocked == true)
        #expect(await cache.activeTabContext()?.page == nil)
    }
    @Test func twoConnectionsSameTabId() async throws {               // Review Focus 2
        let cache = try await diaOnYouTube()
        var math = try fixtureContext("ext-tabContext-math.json"); math.tabId = 12
        await cache.apply(try activate(12), from: chrome)
        await cache.apply(.tabContext(math), from: chrome)
        #expect(await cache.activeTabContext()?.page?.title == "Unit 4 Quiz Review")
        await cache.apply(try activate(12), from: dia)
        #expect(await cache.activeTabContext()?.youtube != nil)
        await cache.connectionClosed(dia)
        #expect(await cache.activeTabContext()?.page?.title == "Unit 4 Quiz Review")
        await cache.connectionClosed(chrome)
        #expect(await cache.activeTabContext() == nil)
    }
    @Test func staleStoreDoesNotMoveTheActiveTab() async throws {     // Review Focus 1
        let cache = try await diaOnYouTube()
        let youtube = try #require(await cache.activeTabContext())
        await cache.apply(try activate(21), from: dia)
        await cache.store(youtube, from: dia)                          // an answer that raced the tab switch
        #expect(await cache.activeTabContext() == nil)
        await cache.apply(try fixtureMessage("ext-tabContext-math.json"), from: dia)
        #expect(await cache.activeTabContext()?.tabId == 21)
    }
    @Test func closedConnectionCannotComeBack() async throws {
        let cache = ContextCache()
        await cache.connectionClosed(chrome)
        await cache.store(try fixtureContext("ext-tabContext-math.json"), from: chrome)
        await cache.apply(try activate(21), from: chrome)
        #expect(await cache.activeConnection() == nil)
        #expect(await cache.activeTabContext() == nil)
        #expect(await cache.connection(forTab: 21) == nil)
    }
    @Test func storeActivatesWhenNothingIsActive() async throws {
        let cache = ContextCache()
        await cache.store(try fixtureContext("ext-tabContext-math.json"), from: chrome)
        #expect(await cache.activeConnection() == chrome)
        #expect(await cache.activeTabContext()?.tabId == 21)
    }
    @Test func storeDoesNotStealActiveFromAnotherBrowser() async throws {
        let cache = try await diaOnYouTube()
        await cache.store(try fixtureContext("ext-tabContext-math.json"), from: chrome)
        #expect(await cache.activeConnection() == dia)
        #expect(await cache.connection(forTab: 21) == chrome)
    }
}
