import CompanionCore
import CompanionTestSupport
import Foundation
import Testing

@Test func fixtureNames() throws {
    let names = try Fixtures.allBridgeFixtureNames()
    #expect(names.contains("ext-hello.json"))
    #expect(names.contains("app-ping.json"))
    #expect(names.count == 24)
    #expect(names.filter { $0.hasPrefix("ext-") }.count == 15)
    #expect(names.filter { $0.hasPrefix("app-") }.count == 8)
    #expect(names.filter { $0.hasPrefix("invalid-") }.count == 1)
    #expect(names == names.sorted())
}

@Test func samplePNGIsARealPNG() {
    let image = Fixtures.samplePNG()
    #expect(Array(image.png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
    #expect(image.pixelWidth == 4)
    #expect(image.pixelHeight == 3)
    #expect(Fixtures.samplePNG(width: 2, height: 5).pixelHeight == 5)
}

private func request() -> LLMRequest {
    LLMRequest(model: ModelCatalog.haiku45, system: "s", messages: [])
}

@Test func fakeLLMDefaultStreamRecordsTheRequest() async throws {
    let fake = FakeLLMProvider()
    var events: [LLMStreamEvent] = []
    for try await event in fake.stream(request()) { events.append(event) }
    #expect(events == [.textDelta("Hello"), .finished(stopReason: "end_turn")])
    #expect(fake.requests == [request()])
    #expect(fake.providerID == "fake")
}

@Test func fakeLLMFailureThrowsBeforeYieldingAnything() async {
    let fake = FakeLLMProvider(failure: LLMError.http(status: 529, message: "Overloaded"))
    var events: [LLMStreamEvent] = []
    do {
        for try await event in fake.stream(request()) { events.append(event) }
        Issue.record("expected a throw")
    } catch {
        #expect(error as? LLMError == .http(status: 529, message: "Overloaded"))
    }
    #expect(events.isEmpty)
    #expect(fake.requests.count == 1)
}

@Test func fakeLLMDelaySpacesEvents() async throws {
    let fake = FakeLLMProvider(events: [.textDelta("a"), .textDelta("b"), .finished(stopReason: nil)], delayPerEvent: .milliseconds(30))
    let clock = ContinuousClock()
    let start = clock.now
    var count = 0
    for try await _ in fake.stream(request()) { count += 1 }
    #expect(count == 3)
    #expect(clock.now - start >= .milliseconds(60))
}

@Test func fakeLLMCountsPrewarms() async {
    let fake = FakeLLMProvider()
    await fake.prewarm()
    await fake.prewarm()
    #expect(fake.prewarmCount == 2)
}

private func tab(_ id: Int) -> TabContext {
    TabContext(tabId: id, url: "https://a.test", title: "A", capturedAtMs: 0, blocked: false, page: nil, youtube: nil, classroom: nil, drive: nil)
}

@Test func fakeBrowserTimesOutWhenFreshIsTooSlow() async {
    let fake = FakeBrowserContextProvider(fresh: tab(1), freshDelay: .milliseconds(500))
    #expect(await fake.requestActiveTabContext(timeout: .milliseconds(300)) == nil)
    #expect(await fake.requestCount == 1)
}

@Test func fakeBrowserReturnsFreshInTime() async {
    let fake = FakeBrowserContextProvider(fresh: tab(2), freshDelay: .milliseconds(10))
    #expect(await fake.requestActiveTabContext(timeout: .milliseconds(300)) == tab(2))
}

@Test func fakeBrowserCacheAndConnection() async {
    let fake = FakeBrowserContextProvider(cached: tab(1), connected: false)
    #expect(await fake.cachedActiveTabContext() == tab(1))
    await fake.setCached(tab(3))
    #expect(await fake.cachedActiveTabContext() == tab(3))
    await fake.setCached(nil)
    #expect(await fake.cachedActiveTabContext() == nil)
    #expect(await fake.isConnected() == false)
    #expect(await fake.requestCount == 0)
}

@Test func fakeSecretStoreSetGetDelete() throws {
    let store = FakeSecretStore(["a": "1"])
    #expect(store.secret(for: "a") == "1")
    try store.setSecret("2", for: "b")
    #expect(store.secret(for: "b") == "2")
    try store.setSecret(nil, for: "a")
    #expect(store.secret(for: "a") == nil)
}

@MainActor @Test func fakeSettingsNotifiesObserversSynchronously() {
    let store = FakeSettingsStore()
    var seen: [Bool] = []
    store.addObserver { seen.append($0.orbEnabled) }
    store.addObserver { seen.append($0.orbEnabled) }
    store.update { $0.orbEnabled = false }
    #expect(store.settings.orbEnabled == false)
    #expect(seen == [false, false])
}

@Test func fakeDocumentFetcherReturnsKnownFiles() async throws {
    let fake = FakeDocumentFetcher(files: ["f": (Data([1]), "Book.pdf")])
    let result = try await fake.fetchDrivePDF(fileId: "f")
    #expect(result.data == Data([1]) && result.title == "Book.pdf")
    await #expect(throws: BridgeError.self) { try await fake.fetchDrivePDF(fileId: "missing") }
    #expect(await fake.requestedFileIDs == ["f", "missing"])
}

@Test func fakeDocumentFetcherFailureWins() async {
    let failure = BridgeError(code: .downloadBlocked, message: "x")
    let fake = FakeDocumentFetcher(files: ["f": (Data(), "t")], failure: failure)
    do {
        _ = try await fake.fetchDrivePDF(fileId: "f")
        Issue.record("expected a throw")
    } catch {
        #expect(error as? BridgeError == failure)
    }
    #expect(await fake.requestedFileIDs == ["f"])
}

@Test func fakeViewerRecordsCapturesAndRestore() async throws {
    let fake = FakeViewerDriver(info: ViewerInfo(pageCount: 5, currentIndex: 2), page: { Fixtures.samplePNG(width: $0 + 1, height: 1) })
    #expect(try await fake.viewerInfo(tabId: 1) == ViewerInfo(pageCount: 5, currentIndex: 2))
    #expect(try await fake.capturePage(tabId: 1, pageIndex: 3).pixelWidth == 4)
    _ = try await fake.capturePage(tabId: 1, pageIndex: 0)
    #expect(await fake.capturedIndices == [3, 0])
    #expect(await fake.restoredIndex == nil)
    try await fake.restore(tabId: 1, pageIndex: 2)
    #expect(await fake.restoredIndex == 2)
}
