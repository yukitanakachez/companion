import AppKit
import CompanionCore
import SwiftUI

/// An accessory app has no Edit menu, so the window routes ⌘X/C/V/A/Z itself: API keys get pasted here.
final class EditShortcutWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        BubbleWindowKeys.performEdit(event, in: self) || super.performKeyEquivalent(with: event)
    }
}

@MainActor public final class SettingsWindowController {
    let viewModel: SettingsViewModel
    private(set) var window: NSWindow?
    private var closeObserver: (any NSObjectProtocol)?

    public init(settings: any SettingsStoring, secrets: any SecretStoring,
                bridgeStatus: @escaping @MainActor () async -> BridgeStatus?,
                pairingToken: @escaping @MainActor () -> String,
                regenerateToken: @escaping @MainActor () -> String,
                permissions: @escaping @MainActor () -> PermissionStatus,
                openPermission: @escaping @MainActor (PermissionKind) -> Void) {
        viewModel = SettingsViewModel(settings: settings, secrets: secrets, bridgeStatus: bridgeStatus,
                                      pairingToken: pairingToken, regenerateToken: regenerateToken,
                                      permissions: permissions, openPermission: openPermission)
    }

    /// Keeps the last tab (`.general` the first time).
    public func show() { show(tab: viewModel.selectedTab) }

    private func makeWindow() -> NSWindow {
        let window = EditShortcutWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 480), styleMask: [.titled, .closable],
                                        backing: .buffered, defer: false)
        window.title = "Companion Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(viewModel: viewModel))
        window.center()
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.viewModel.commitAll()
                self?.viewModel.stopPolling()
            }
        }
        return window
    }

    fileprivate func present(tab: SettingsTab) {
        NSApp.activate()
        let window = self.window ?? makeWindow()
        self.window = window
        viewModel.selectedTab = tab
        window.makeKeyAndOrderFront(nil)
        viewModel.startPolling()
    }
}

extension SettingsWindowController {
    public func show(tab: SettingsTab) { present(tab: tab) }
}
