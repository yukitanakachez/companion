import AppKit
import WebKit

enum AnswerWebError: Error { case timeout }

/// The pre-loaded transparent web view that renders the thread. Created once per bubble at launch,
/// so the first summon never pays WebKit start-up.
@MainActor final class AnswerWebController: NSObject {
    let webView: WKWebView
    private(set) var isReady = false
    var onContentHeight: ((CGFloat) -> Void)?

    private var pending: [ThreadMessage]?
    private var rendered: [ThreadMessage] = []
    private var hasRendered = false
    private let indexURL: URL?

    override init() {
        let configuration = WKWebViewConfiguration()
        let proxy = WeakMessageProxy()
        configuration.userContentController.add(proxy, name: "companion")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        indexURL = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "web")
        super.init()
        proxy.target = self
        webView.navigationDelegate = self
        if let indexURL {
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        }
    }

    /// Before ready: keeps only the latest thread. On ready: full render of it, then diffs.
    func apply(_ thread: [ThreadMessage]) {
        guard isReady else {
            pending = thread
            return
        }
        let command: AnswerRenderCommand = hasRendered ? AnswerRenderDiff.command(from: rendered, to: thread) : .render(thread)
        hasRendered = true
        rendered = thread
        if let script = AnswerScript.script(for: command) {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    func waitUntilReady(timeout: Duration) async throws {
        if isReady { return }
        let deadline = ContinuousClock.now + timeout
        while !isReady {
            if ContinuousClock.now >= deadline { throw AnswerWebError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func evaluate(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UncheckedResult, Error>) in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: UncheckedResult(value: value))
                }
            }
        }.value
    }

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            if let thread = pending {
                pending = nil
                apply(thread)
            }
        case "height":
            if let value = message["value"] as? NSNumber { onContentHeight?(CGFloat(value.doubleValue)) }
        default:
            break
        }
    }
}

private struct UncheckedResult: @unchecked Sendable { let value: Any? }

extension AnswerWebController: WKNavigationDelegate {
    /// Links come from model output, so only web links leave the bubble.
    static func opensExternally(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// Reloads and re-renders, so a killed web process never leaves a blank answer.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        pending = pending ?? rendered
        hasRendered = false
        rendered = []
        if let indexURL { webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent()) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        if navigationAction.navigationType == .linkActivated {
            if let url, Self.opensExternally(url) { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        } else {
            decisionHandler(url?.standardizedFileURL == indexURL?.standardizedFileURL ? .allow : .cancel)
        }
    }
}

/// `WKUserContentController` retains its handlers; this keeps it from retaining the controller.
@MainActor private final class WeakMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: AnswerWebController?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message.body)
    }
}
