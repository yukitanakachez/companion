import AppKit
import ApplicationServices
import CompanionCore
import Foundation

/// AXUIElements stay local to each call and are never stored. `AXEnhancedUserInterface` and
/// `AXManualAccessibility` are deliberately not set: they change how the browser behaves.
struct LiveAccessibilityReader: AccessibilityReading {
    private let ownBundleID: String
    private let isTrusted: @Sendable () -> Bool

    init(ownBundleID: String, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.ownBundleID = ownBundleID
        self.isTrusted = isTrusted
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), CaptureConstants.axMessagingTimeout)
    }

    func frontApp() async -> FrontAppInfo? {
        FrontAppResolver.resolve(frontmost: NSWorkspace.shared.frontmostApplication.flatMap(Self.info),
                                 ownBundleID: ownBundleID, windowOwners: Self.windowOwners)
    }

    func focusedWindow(pid: Int32) async -> FocusedWindowInfo? {
        guard isTrusted(), let window = element(Self.application(pid), kAXFocusedWindowAttribute) else { return nil }
        var frame: CGRect?
        if let position: CGPoint = axValue(window, kAXPositionAttribute, .cgPoint, .zero),
           let size: CGSize = axValue(window, kAXSizeAttribute, .cgSize, .zero) {
            frame = ScreenGeometry.flipped(CGRect(origin: position, size: size),
                                           primaryHeight: ScreenGeometry.primaryDisplayHeight())
        }
        return FocusedWindowInfo(title: string(window, kAXTitleAttribute), frame: frame)
    }

    func selectedText(pid: Int32) async -> String? {
        guard let focused = readableFocusedElement(pid: pid) else { return nil }
        return nonEmpty(string(focused, kAXSelectedTextAttribute))
    }

    func focusedText(pid: Int32) async -> String? {
        guard let focused = readableFocusedElement(pid: pid) else { return nil }
        return nonEmpty(string(focused, kAXValueAttribute))
    }

    func browserURL(pid: Int32) async -> URL? {
        guard isTrusted(), let window = element(Self.application(pid), kAXFocusedWindowAttribute) else { return nil }
        // Both passes share one budget. After kAXErrorCannotComplete the app is not answering,
        // so every remaining read short-circuits and the queue drains without further IPC.
        let deadline = ContinuousClock.now + CaptureConstants.axWalkMaxDuration
        var visited = 0
        var stalled = false
        func read(_ node: AXUIElement, _ attribute: String) -> CFTypeRef? {
            if stalled { return nil }
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(node, attribute as CFString, &value)
            if result == .cannotComplete { stalled = true }
            return result == .success ? value : nil
        }
        func role(_ node: AXUIElement) -> String? { read(node, kAXRoleAttribute) as? String }
        func children(_ node: AXUIElement) -> [AXUIElement] {
            (read(node, kAXChildrenAttribute) as? [AnyObject] ?? []).compactMap(Self.asElement)
        }

        let webArea = AXTreeSearch.firstMatch(
            root: window, maxVisited: CaptureConstants.axWalkMaxElements, deadline: deadline,
            children: children, descend: { _ in true },
            matches: { visited += 1; return role($0) == "AXWebArea" })
        if let webArea, let value = read(webArea, "AXURL"), CFGetTypeID(value) == CFURLGetTypeID() {
            return (value as! CFURL) as URL
        }

        // Fallback: never descend into the page, so its own inputs can't pass for the address bar.
        var parsed: URL?
        _ = AXTreeSearch.firstMatch(
            root: window, maxVisited: max(0, CaptureConstants.axWalkMaxElements - visited), deadline: deadline,
            children: children, descend: { role($0) != "AXWebArea" },
            matches: { node in
                let nodeRole = role(node)
                guard nodeRole == "AXTextField" || nodeRole == "AXComboBox",
                      AXTextPolicy.isReadable(role: nodeRole, subrole: read(node, kAXSubroleAttribute) as? String),
                      let text = read(node, kAXValueAttribute) as? String else { return false }
                parsed = BrowserURLParser.url(fromAddressField: text)
                return parsed != nil
            })
        return parsed
    }

    // MARK: - Helpers

    private static func application(_ pid: Int32) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, CaptureConstants.axMessagingTimeout)
        return app
    }

    /// The focused element, only when it is provably not a secure field. A role or subrole that
    /// can't be read (a timeout, say) counts as unreadable: fail closed.
    private func readableFocusedElement(pid: Int32) -> AXUIElement? {
        guard isTrusted(), let focused = element(Self.application(pid), kAXFocusedUIElementAttribute),
              let role = string(focused, kAXRoleAttribute) else { return nil }
        var subrole: CFTypeRef?
        switch AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subrole) {
        case .success, .noValue, .attributeUnsupported: break
        default: return nil
        }
        return AXTextPolicy.isReadable(role: role, subrole: subrole as? String) ? focused : nil
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    private func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        copy(parent, attribute).flatMap { Self.asElement($0) }
    }

    private func axValue<T>(_ element: AXUIElement, _ attribute: String, _ type: AXValueType, _ initial: T) -> T? {
        guard let raw = copy(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var result = initial
        return AXValueGetValue(raw as! AXValue, type, &result) ? result : nil
    }

    private static func asElement(_ value: AnyObject) -> AXUIElement? {
        CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! AXUIElement) : nil
    }

    private func nonEmpty(_ text: String?) -> String? {
        text?.isEmpty == false ? text : nil
    }

    private static func info(_ app: NSRunningApplication) -> FrontAppInfo? {
        guard let bundleID = app.bundleIdentifier else { return nil }
        return FrontAppInfo(bundleID: bundleID, appName: app.localizedName ?? bundleID,
                            pid: app.processIdentifier, windowTitle: nil, windowFrame: nil)
    }

    /// On-screen layer-0 window owners, front to back.
    private static func windowOwners() -> [FrontAppInfo] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.compactMap { window in
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  let app = NSRunningApplication(processIdentifier: pid) else { return nil }
            return info(app)
        }
    }
}
