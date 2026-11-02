import Testing
import Foundation
import CompanionCore
@testable import CompanionCapture

@Test func blockedBundleID() {
    #expect(ev(onePassword, browser: false) == .blocked(reason: "1Password is on your blocklist"))
    #expect(ev(FrontAppInfo(bundleID: "COM.1PASSWORD.1password", appName: "1Password", pid: 1, windowTitle: nil, windowFrame: nil),
               browser: false) != .allowed)                                              // case-insensitive
}
@Test func blockedTabFlagAloneBlocks() throws {                                          // even with an empty domain list
    #expect(ev(dia, browser: true, tab: try tabFixture("ext-tabContext-blocked.json"), config: BlocklistConfig(bundleIDs: [], domains: [])) == siteBlocked)
}
@Test func domainSuffixMatching() {
    #expect(PrivacyGate.hostMatches("secure.chase.com", domain: "chase.com") && PrivacyGate.hostMatches("chase.com", domain: "chase.com"))
    #expect(PrivacyGate.hostMatches("SECURE.Chase.COM.", domain: "chase.com"))          // lowercased, trailing dot ignored
    #expect(!PrivacyGate.hostMatches("notchase.com", domain: "chase.com") && !PrivacyGate.hostMatches("chase.com.evil.test", domain: "chase.com"))
}
@Test func browserURLUsedWhenNoTab() { #expect(ev(dia, browser: true, url: "https://www.paypal.com/myaccount") == siteBlocked) }
@Test func eitherHostMatchingBlocks() throws {        // tab says youtube, AX URL says chase → blocked (conservative)
    let yt = try tabFixture("ext-tabContext-youtube.json")
    #expect(ev(dia, browser: true, tab: yt, url: "https://chase.com") == siteBlocked && ev(dia, browser: true, tab: yt) == .allowed)
}
@Test func unknownSiteInBrowserIsUnchecked() throws {
    var noURL = try tabFixture("ext-tabContext-youtube.json"); noURL.url = ""
    #expect(ev(dia, browser: true) == .siteUnchecked && ev(dia, browser: true, tab: noURL) == .siteUnchecked)
}
@Test func nonBrowserAndUnknownFrontAreAllowed() { #expect(ev(preview, browser: false) == .allowed && ev(nil, browser: false) == .allowed) }
@Test func specValues() {
    #expect(CaptureConstants.longEdgePixels == 1500 && CaptureConstants.transcriptLookback == 180)
    #expect(CaptureConstants.focusedTextCap == 8_000 && CaptureConstants.axMessagingTimeout == 0.05)
    #expect(BridgeConstants.hotPathTimeout == .milliseconds(300))
}
