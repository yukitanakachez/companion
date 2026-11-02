import CoreGraphics
import Foundation
import CompanionCore
import CompanionTestSupport
@testable import CompanionCapture

let dia = FrontAppInfo(bundleID: "company.thebrowser.dia", appName: "Dia", pid: 4242, windowTitle: nil, windowFrame: nil)
let safari = FrontAppInfo(bundleID: "com.apple.Safari", appName: "Safari", pid: 4343, windowTitle: nil, windowFrame: nil)
let preview = FrontAppInfo(bundleID: "com.apple.Preview", appName: "Preview", pid: 5151, windowTitle: nil, windowFrame: nil)
let onePassword = FrontAppInfo(bundleID: "com.1password.1password", appName: "1Password", pid: 777, windowTitle: nil, windowFrame: nil)
let img = Fixtures.samplePNG()
let siteBlocked = PrivacyDecision.blocked(reason: "This site is on your blocklist")

struct NotATabContext: Error {}

/// Decodes a bridge fixture as `ExtensionToApp` and unwraps `.tabContext`.
func tabFixture(_ name: String) throws -> TabContext {
    guard case .tabContext(let tab) = try JSONDecoder().decode(ExtensionToApp.self, from: Fixtures.bridgeFixture(name)) else {
        throw NotATabContext()
    }
    return tab
}

func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// `PrivacyGate.evaluate` shorthand.
func ev(_ front: FrontAppInfo?, browser: Bool, tab: TabContext? = nil, url: String? = nil,
        config: BlocklistConfig = .starter) -> PrivacyDecision {
    PrivacyGate.evaluate(front: front, isBrowser: browser, tab: tab, browserURL: url.flatMap { URL(string: $0) }, config: config)
}

extension CapturedContext {
    var pieces: [ContextPiece] { items.map(\.piece) }
    var notices: [ContextNotice] {
        items.compactMap { if case .notice(let notice) = $0.piece { notice } else { nil } }
    }
    var chips: [String] { items.map(\.chipLabel) }
}
