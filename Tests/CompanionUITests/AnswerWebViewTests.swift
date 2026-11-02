import AppKit
import Foundation
import Testing
import WebKit
@testable import CompanionUI

extension WindowTests { @MainActor @Suite struct AnswerWebViewTests {
    let c: AnswerWebController
    let window: NSWindow
    init() {
        TestApp.ensure()
        c = AnswerWebController()
        window = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 380, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        c.webView.frame = CGRect(x: 0, y: 0, width: 380, height: 300)
        window.contentView?.addSubview(c.webView)
    }
    @Test func recoversWhenTheWebProcessDies() async throws {
        try await c.waitUntilReady(timeout: .seconds(10))
        c.apply([ThreadMessage(role: .assistant, markdown: "$x^2$")])
        c.webViewWebContentProcessDidTerminate(c.webView)
        #expect(!c.isReady)
        try await c.waitUntilReady(timeout: .seconds(10))
        #expect(try await c.evaluate("document.querySelectorAll('.katex').length > 0") as? Bool == true)
    }
    @Test func onlyWebLinksOpen() {
        #expect(AnswerWebController.opensExternally(URL(string: "https://a.com")!) && AnswerWebController.opensExternally(URL(string: "HTTP://a.com")!))
        for bad in ["smb://x/y", "file:///etc/passwd", "x-app://do", "mailto:a@b.c"] { #expect(!AnswerWebController.opensExternally(URL(string: bad)!)) }
    }
    @Test func webResourcesArePresent() throws {
        for f in ["index.html", "renderer.js", "katex.min.css"] { #expect(Bundle.module.url(forResource: f, withExtension: nil, subdirectory: "web") != nil) }
        let cssURL = try #require(Bundle.module.url(forResource: "katex.min", withExtension: "css", subdirectory: "web"))
        let css = try String(contentsOf: cssURL, encoding: .utf8)
        let names = css.matches(of: /fonts\/([A-Za-z0-9_-]+\.woff2)/).map { String($0.1) }
        #expect(!names.isEmpty)
        for name in Set(names) {
            #expect(FileManager.default.fileExists(atPath: cssURL.deletingLastPathComponent().appendingPathComponent("fonts/\(name)").path), "\(name)")
        }
    }
    @Test func rendersKaTeXInWebView() async throws {
        c.apply([ThreadMessage(role: .assistant, markdown: "$x^2$")])     // before the page has loaded
        try await c.waitUntilReady(timeout: .seconds(10))
        #expect(try await c.evaluate("document.querySelectorAll('.katex').length > 0") as? Bool == true)
    }
    @Test func deltaTextSurvivesTheBridge() async throws {
        let id = UUID(), tricky = "\\frac{1}{2} \"q\" </script>\n\u{2028}$5 and $6 \\$"
        c.apply([ThreadMessage(id: id, role: .assistant, markdown: "", isStreaming: true)]); try await c.waitUntilReady(timeout: .seconds(10))
        c.apply([ThreadMessage(id: id, role: .assistant, markdown: tricky, isStreaming: true)])
        #expect(try await c.evaluate("window.companion.debugMarkdown('\(id.uuidString)')") as? String == tricky)
    }
    @Test func reportsContentHeightForLongAnswers() async throws {
        var heights: [CGFloat] = []; c.onContentHeight = { heights.append($0) }
        c.apply([ThreadMessage(role: .assistant, markdown: (1...60).map { "Paragraph \($0) with $x_\($0)$." }.joined(separator: "\n\n"))])
        try await c.waitUntilReady(timeout: .seconds(10))
        for _ in 0..<40 where (heights.last ?? 0) <= 520 { try await Task.sleep(for: .milliseconds(50)) }
        #expect((heights.last ?? 0) > 520)
    }
}}
