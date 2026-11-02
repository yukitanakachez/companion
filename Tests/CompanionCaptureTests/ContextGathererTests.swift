import Testing
import ApplicationServices
import CoreGraphics
import Foundation
import CompanionCore
import CompanionTestSupport
@testable import CompanionCapture

private func gatherer(ax: FakeAccessibilityReader = FakeAccessibilityReader(front: dia),
                      window: FakeWindowCapturer = FakeWindowCapturer(),
                      region: FakeRegionCapturer = FakeRegionCapturer(),
                      browser: any BrowserContextProviding = FakeBrowserContextProvider(),
                      imageTimeout: Duration = CaptureConstants.imageTimeout) -> ContextGatherer {
    ContextGatherer(accessibility: ax, windowCapturer: window, regionCapturer: region, browser: browser,
                    blocklist: { .starter }, imageTimeout: imageTimeout)
}

/// Every run must hold exactly one complete emission, and it must come last.
private func run(_ g: ContextGatherer, _ request: GatherRequest = .frontWindow,
                 sourceLocation: SourceLocation = #_sourceLocation) async -> Collected {
    let r = await collect(await g.gather(request), since: .now)
    #expect(r.emissions.filter(\.isComplete).count == 1, sourceLocation: sourceLocation)
    #expect(r.final.isComplete, sourceLocation: sourceLocation)
    return r
}

private func hasWindowImage(_ c: CapturedContext) -> Bool {
    c.pieces.contains { if case .windowImage = $0 { true } else { false } }
}
private func hasCapture(_ c: CapturedContext) -> Bool {
    c.pieces.contains {
        switch $0 {
        case .windowImage, .regionImage, .selectedText, .focusedText: true
        default: false
        }
    }
}
private func hasVideoChips(_ c: CapturedContext) -> Bool {
    c.chips.contains { $0.hasPrefix("▶") || $0.hasPrefix("transcript") }
}

@Test func extensionNotConnectedStillCompletesFast() async throws {          // Review Focus #3 (overview)
    let browser = FakeBrowserContextProvider(cached: nil, fresh: try tabFixture("ext-tabContext-youtube.json"),
                                             freshDelay: .seconds(1), connected: false)
    let r = await run(gatherer(browser: browser))
    #expect(r.finalAt < .milliseconds(500))
    #expect(hasWindowImage(r.final))
    #expect(r.final.notices.contains(.extensionNotConnected))
    #expect(!hasVideoChips(r.final))
    #expect(await browser.requestCount == 0)                                  // not connected → never asked
}
@Test func stubbornExtensionIsAbandonedAtHotPathTimeout() async throws {
    let r = await run(gatherer(browser: StubbornBrowserProvider(fresh: try tabFixture("ext-tabContext-youtube.json"), after: 1)))
    #expect(r.finalAt < .milliseconds(500))
    #expect(hasWindowImage(r.final))
    #expect(r.final.notices == [.siteNotChecked])
    #expect(!hasVideoChips(r.final))
}
@Test func cachedTabSkipsRequestAndAXURL() async throws {
    let ax = FakeAccessibilityReader(front: dia)
    let browser = FakeBrowserContextProvider(cached: try tabFixture("ext-tabContext-youtube.json"))
    let r = await run(gatherer(ax: ax, browser: browser))
    #expect(r.emissions[0].kind == .youtube && r.emissions[0].chips.contains("▶ 12:41 · Finding the roots"))
    #expect(r.final.tabId == 12)
    #expect(await browser.requestCount == 0)
    #expect(await ax.urlCalls == 0)
}
@Test func freshTabWithinWaitIsUsed() async throws {
    let browser = FakeBrowserContextProvider(fresh: try tabFixture("ext-tabContext-youtube.json"), freshDelay: .milliseconds(100))
    let r = await run(gatherer(browser: browser))
    #expect(r.final.kind == .youtube && !r.final.notices.contains(.siteNotChecked))
    #expect(r.final.tabId == 12)
}
@Test func itemIDsStayStableAcrossEmissions() async throws {
    let browser = FakeBrowserContextProvider(cached: try tabFixture("ext-tabContext-youtube.json"))
    let r = await run(gatherer(ax: FakeAccessibilityReader(front: dia, selected: "s"), browser: browser))
    var seen: [String: UUID] = [:]
    for item in r.emissions.flatMap(\.items) {
        #expect(seen[item.chipLabel, default: item.id] == item.id)
        seen[item.chipLabel] = item.id
    }
    #expect(r.emissions.count > 1)
}
@Test func blockedAppNeverCaptures() async {
    for request in [GatherRequest.frontWindow, .region(RegionSelection(rect: R(0, 0, 100, 100), displayID: 1))] {
        let ax = FakeAccessibilityReader(front: onePassword, selected: "secret", focused: "secret")
        let window = FakeWindowCapturer(), region = FakeRegionCapturer(), browser = FakeBrowserContextProvider()
        let r = await run(gatherer(ax: ax, window: window, region: region, browser: browser), request)
        #expect(r.emissions.allSatisfy { $0.pieces == [.notice(.contextOffForApp)] })
        #expect(r.final.privacy == .blocked(reason: "1Password is on your blocklist"))
        #expect(await window.calls == 0)
        #expect(await region.calls == 0)
        #expect(await ax.windowCalls == 0)
        #expect(await ax.textCalls == 0)
        #expect(await ax.urlCalls == 0)
        #expect(await browser.requestCount == 0)
    }
}
@Test func blockedSiteFromCachedTabOrAXURLNeverCaptures() async throws {
    let cachedWindow = FakeWindowCapturer()
    let cached = await run(gatherer(window: cachedWindow,
                                    browser: FakeBrowserContextProvider(cached: try tabFixture("ext-tabContext-blocked.json"))))
    #expect(cached.final.pieces == [.notice(.contextOffForSite)])
    #expect(await cachedWindow.calls == 0)

    let urlWindow = FakeWindowCapturer()
    let viaURL = await run(gatherer(ax: FakeAccessibilityReader(front: dia, url: URL(string: "https://secure.chase.com/x")),
                                    window: urlWindow, browser: FakeBrowserContextProvider(connected: false)))
    #expect(viaURL.final.pieces == [.notice(.contextOffForSite)])
    #expect(await urlWindow.calls == 0)
}
@Test func freshTabTurnsOutBlockedNeverEmitsCapture() async throws {
    let browser = FakeBrowserContextProvider(fresh: try tabFixture("ext-tabContext-blocked.json"), freshDelay: .milliseconds(100))
    let r = await run(gatherer(ax: FakeAccessibilityReader(front: dia, selected: "acct"), browser: browser))
    #expect(!r.emissions.contains(where: hasCapture))
    #expect(r.final.privacy == siteBlocked)
    #expect(r.final.front?.windowTitle == nil)
}
@Test func slowCapturerDoesNotDelayFirstEmission() async {
    let r = await run(gatherer(ax: FakeAccessibilityReader(front: preview), window: FakeWindowCapturer(delay: .milliseconds(400))))
    #expect(r.firstAt < .milliseconds(100))
    #expect(!r.emissions[0].isComplete && !r.emissions[0].hasImage)
    #expect(hasWindowImage(r.final))
}
@Test func imageTimeoutDropsImage() async {
    let r = await run(gatherer(ax: FakeAccessibilityReader(front: preview), window: FakeWindowCapturer(delay: .seconds(5)),
                               imageTimeout: .milliseconds(200)))
    #expect(r.finalAt < .seconds(1) && !r.final.hasImage)
}
@Test func regionRequestUsesRegionCapturer() async {
    let sel = RegionSelection(rect: R(10, 10, 300, 200), displayID: 1)
    let window = FakeWindowCapturer(), region = FakeRegionCapturer()
    let r = await run(gatherer(ax: FakeAccessibilityReader(front: preview), window: window, region: region), .region(sel))
    #expect(await region.calls == 1)
    #expect(await region.lastSelection == sel)
    #expect(await window.calls == 0)
    #expect(r.final.kind == .region && r.final.chips.first == "region")
}
@Test func windowFrameFlowsToCapturer() async {
    let window = FakeWindowCapturer()
    let r = await run(gatherer(ax: FakeAccessibilityReader(front: preview), window: window))
    #expect(await window.lastFocusedFrame == R(100, 100, 800, 600))
    #expect(r.final.front?.windowFrame == R(100, 100, 800, 600))
    #expect(r.final.front?.windowTitle == "Doc")
}
@Test func noCapturableWindowStillCompletesWithText() async {
    let r = await run(gatherer(ax: FakeAccessibilityReader(front: preview, selected: "x^2"),
                               window: FakeWindowCapturer(result: .failure(.noCapturableWindow))))
    #expect(r.final.chips == ["selection"])
}
@Test func missingPermissionsStillComplete() async {
    let r = await run(gatherer(ax: FakeAccessibilityReader(front: preview, window: nil),
                               window: FakeWindowCapturer(result: .failure(.permissionDenied))))
    #expect(r.finalAt < .milliseconds(500))
    #expect(r.final.kind == .genericWindow && r.final.items.isEmpty)
}
@Test func nonChromiumBrowserNeverConsultsExtension() async throws {
    let ax = FakeAccessibilityReader(front: safari)
    let browser = FakeBrowserContextProvider(cached: try tabFixture("ext-tabContext-youtube.json"))
    let r = await run(gatherer(ax: ax, browser: browser))
    #expect(!r.final.chips.contains { $0.hasPrefix("▶") })
    #expect(await browser.requestCount == 0)
    #expect(await ax.urlCalls == 1)
    #expect(r.final.notices.contains(.extensionNotConnected))
}
@Test func unknownFrontApp() async {
    let window = FakeWindowCapturer()
    let r = await run(gatherer(ax: FakeAccessibilityReader(front: nil), window: window))
    #expect(r.final.privacy == .allowed && r.final.kind == .genericWindow)
    #expect(await window.calls == 0)
}
@Test(.enabled(if: CGPreflightScreenCaptureAccess() && AXIsProcessTrusted())) func liveGatherCompletes() async {
    let g = ContextGatherer.live(browser: FakeBrowserContextProvider(connected: false), blocklist: { .starter },
                                 ownBundleID: "dev.local.Companion.tests")
    let r = await run(g)
    #expect(r.finalAt < .seconds(2) && r.final.front != nil)
}
