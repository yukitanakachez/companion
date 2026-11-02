import SwiftUI
import WebKit

struct AnswerWebView: NSViewRepresentable {
    let controller: AnswerWebController
    let thread: [ThreadMessage]

    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) { controller.apply(thread) }
}
