import CompanionCore
import CoreGraphics
import Foundation

/// frame: AppKit global coordinates.
struct FocusedWindowInfo: Sendable, Equatable {
    var title: String?
    var frame: CGRect?
}

protocol AccessibilityReading: Sendable {
    /// bundleID, appName, pid only (windowTitle/windowFrame nil); no AX needed.
    func frontApp() async -> FrontAppInfo?
    func focusedWindow(pid: Int32) async -> FocusedWindowInfo?
    /// nil when empty or the focused element is secure.
    func selectedText(pid: Int32) async -> String?
    /// AXValue of the focused element; nil for AXSecureTextField.
    func focusedText(pid: Int32) async -> String?
    /// AXWebArea "AXURL", else the toolbar address field.
    func browserURL(pid: Int32) async -> URL?
}

enum AXTextPolicy {
    private static let secure = "AXSecureTextField"

    static func isReadable(role: String?, subrole: String?) -> Bool {
        role != secure && subrole != secure
    }
}

enum FocusedTextPolicy {
    /// What is on screen, when the element can say. Otherwise the newest characters of its full value:
    /// in Terminal or an editor the oldest scrollback is the least useful part.
    static func choose(visible: String?, value: () -> String?) -> String? {
        if let visible, !visible.isEmpty { return visible }
        guard let full = value(), !full.isEmpty else { return nil }
        return String(full.suffix(CaptureConstants.focusedTextCap))
    }
}

enum BrowserURLParser {
    /// Browsers hide the scheme in the address bar, so a bare host is accepted. Search text is not a URL.
    static func url(fromAddressField text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        if trimmed.contains("://") {
            return URL(string: trimmed).flatMap { $0.host == nil ? nil : $0 }
        }
        guard let url = URL(string: "https://" + trimmed), let host = url.host else { return nil }
        return host == "localhost" || host.contains(".") ? url : nil
    }
}

enum AXTreeSearch {
    /// Breadth-first; nil once maxVisited nodes were visited or the deadline passed.
    static func firstMatch<Node>(root: Node, maxVisited: Int, deadline: ContinuousClock.Instant,
                                 children: (Node) -> [Node], descend: (Node) -> Bool,
                                 matches: (Node) -> Bool) -> Node? {
        var queue = [root]
        var next = 0
        while next < queue.count, next < maxVisited, ContinuousClock.now < deadline {
            let node = queue[next]
            next += 1
            if matches(node) { return node }
            if descend(node) { queue.append(contentsOf: children(node)) }
        }
        return nil
    }
}

enum FrontAppResolver {
    /// Frontmost unless it is us or nil; then the first window owner (front to back) that isn't us.
    static func resolve(frontmost: FrontAppInfo?, ownBundleID: String, windowOwners: () -> [FrontAppInfo]) -> FrontAppInfo? {
        if let frontmost, frontmost.bundleID != ownBundleID { return frontmost }
        return windowOwners().first { $0.bundleID != ownBundleID }
    }
}
