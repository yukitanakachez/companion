import AppKit
import CompanionCore
import CompanionUI

final class MenuTarget: NSObject {
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @MainActor @objc func run() { action() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let settings = DemoSettingsStore()
let viewModel = BubbleViewModel()
let bubble = BubbleController(viewModel: viewModel)
let coordinator = DemoCoordinator(viewModel: viewModel, bubble: bubble)
viewModel.actions = coordinator

let orb = OrbController(settings: settings, onSummon: { coordinator.summon() })
let hotkeys = HotkeyManager(onSummon: { coordinator.summon() }, onRegion: { coordinator.summonRegion() })

let pairingCode = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
let settingsWindow = SettingsWindowController(
    settings: settings, secrets: DemoSecretStore(),
    bridgeStatus: { BridgeStatus(port: 47823, connectedBrowsers: ["Dia"]) },
    pairingToken: { pairingCode },
    regenerateToken: { pairingCode },
    permissions: { PermissionStatus(screenRecording: true, accessibility: true) },
    openPermission: { print("open permission: \($0)") })
coordinator.settingsWindow = settingsWindow

let settingsTarget = MenuTarget { settingsWindow.show() }
let quitTarget = MenuTarget { NSApp.terminate(nil) }
let menu = NSMenu()
let settingsItem = NSMenuItem(title: "Settings…", action: #selector(MenuTarget.run), keyEquivalent: "")
settingsItem.target = settingsTarget
menu.addItem(settingsItem)
let quitItem = NSMenuItem(title: "Quit", action: #selector(MenuTarget.run), keyEquivalent: "")
quitItem.target = quitTarget
menu.addItem(quitItem)
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.title = "Demo"
statusItem.menu = menu

app.run()
