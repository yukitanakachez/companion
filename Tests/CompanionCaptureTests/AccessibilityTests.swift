import Testing
import ApplicationServices
import Foundation
import CompanionCore
@testable import CompanionCapture

private final class FakeNode {
    let role: String
    let children: [FakeNode]
    init(_ role: String, _ children: [FakeNode] = []) { self.role = role; self.children = children }
}

@Test func secureFieldIsNeverRead() {
    #expect(!AXTextPolicy.isReadable(role: "AXTextField", subrole: "AXSecureTextField") && !AXTextPolicy.isReadable(role: nil, subrole: "AXSecureTextField"))
    #expect(AXTextPolicy.isReadable(role: "AXTextArea", subrole: nil) && AXTextPolicy.isReadable(role: "AXTextField", subrole: "AXSearchField"))
}
@Test func addressFieldParsing() {
    #expect(BrowserURLParser.url(fromAddressField: "secure.chase.com/web/auth/dashboard")?.host == "secure.chase.com")
    #expect(BrowserURLParser.url(fromAddressField: "https://www.youtube.com/watch?v=abc123XYZ00")?.host == "www.youtube.com")
    #expect(BrowserURLParser.url(fromAddressField: "chrome://newtab")?.host == "newtab")
    #expect(BrowserURLParser.url(fromAddressField: "localhost:3000")?.host == "localhost")
    #expect(BrowserURLParser.url(fromAddressField: "Search Google or type a URL") == nil && BrowserURLParser.url(fromAddressField: "") == nil)
}
@Test func treeSearchFindsWebAreaWithinBudget() {
    let web = FakeNode("AXWebArea")
    let tabs = (0..<20).map { _ in FakeNode("AXTab") }
    let root = FakeNode("AXWindow", [FakeNode("AXToolbar", tabs), FakeNode("AXGroup", [FakeNode("AXGroup", [web])])])
    let far = ContinuousClock.now + .seconds(60)
    func search(max: Int = 1000, deadline: ContinuousClock.Instant = far, descend: (FakeNode) -> Bool = { _ in true },
                visited: inout Int) -> FakeNode? {
        var count = 0
        defer { visited = count }
        return AXTreeSearch.firstMatch(root: root, maxVisited: max, deadline: deadline, children: \.children, descend: descend,
                                       matches: { count += 1; return $0.role == "AXWebArea" })
    }
    var visited = 0
    #expect(search(visited: &visited) === web)
    #expect(search(max: 5, visited: &visited) == nil)
    #expect(search(descend: { $0.role != "AXToolbar" }, visited: &visited) === web && visited <= 6)
    #expect(search(deadline: .now - .seconds(1), visited: &visited) == nil)
}
@Test func resolverSkipsOwnApp() {
    var asked = false
    #expect(FrontAppResolver.resolve(frontmost: dia, ownBundleID: "dev.local.Companion", windowOwners: { asked = true; return [] }) == dia && !asked)
    let me = FrontAppInfo(bundleID: "dev.local.Companion", appName: "Companion", pid: 1, windowTitle: nil, windowFrame: nil)
    #expect(FrontAppResolver.resolve(frontmost: me, ownBundleID: me.bundleID, windowOwners: { [me, preview] }) == preview)
    #expect(FrontAppResolver.resolve(frontmost: nil, ownBundleID: me.bundleID, windowOwners: { [me] }) == nil)
}
@Test func untrustedReaderReturnsNilText() async {
    let r = LiveAccessibilityReader(ownBundleID: "x", isTrusted: { false })
    #expect(await r.focusedWindow(pid: getpid()) == nil)      // one await per #expect: `await` can't follow `&&`
    #expect(await r.selectedText(pid: getpid()) == nil)
    #expect(await r.focusedText(pid: getpid()) == nil)
    #expect(await r.browserURL(pid: getpid()) == nil)
}
@Test(.enabled(if: AXIsProcessTrusted())) func liveReaderAnswersQuicklyForFrontApp() async {
    let r = LiveAccessibilityReader(ownBundleID: "dev.local.Companion.tests")
    guard let front = await r.frontApp() else { return }
    let start = ContinuousClock.now
    _ = await r.focusedWindow(pid: front.pid)
    _ = await r.selectedText(pid: front.pid)
    _ = await r.focusedText(pid: front.pid)
    _ = await r.browserURL(pid: front.pid)
    #expect(ContinuousClock.now - start < .milliseconds(500))
}
@Test(.enabled(if: ProcessInfo.processInfo.environment["COMPANION_MANUAL"] == "1")) func manualReadFrontApp() async throws {
    try await Task.sleep(for: .seconds(3))     // switch to Dia
    let r = LiveAccessibilityReader(ownBundleID: "dev.local.Companion.tests")
    guard let front = await r.frontApp() else { print("no front app"); return }
    print("front:", front)
    print("window:", await r.focusedWindow(pid: front.pid) as Any)
    print("selected:", await r.selectedText(pid: front.pid) as Any)
    print("focused:", await r.focusedText(pid: front.pid) as Any)
    print("url:", await r.browserURL(pid: front.pid) as Any)
}
