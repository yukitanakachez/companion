import AppKit
import CompanionCapture
import CompanionCore
import CompanionLLM
import CompanionSession
import CompanionUI

/// Composition root: builds the objects and wires callbacks. Behaviour lives in CompanionSession.
private struct NoBrowserContext: BrowserContextProviding {
    func cachedActiveTabContext() async -> TabContext? { nil }
    func requestActiveTabContext(timeout: Duration) async -> TabContext? { nil }
    func isConnected() async -> Bool { false }
}

@MainActor final class AppEnvironment {
    let coordinator: SummonCoordinator
    let trace: LatencyTrace
    let settingsWindow: SettingsWindowController

    private let secrets: KeychainSecretStore
    private let settings: UserDefaultsSettingsStore
    private let mirror: SettingsMirror
    private let permissions: PermissionsService
    private let viewModel: BubbleViewModel
    private let bubble: BubbleController
    private let orb: OrbController
    private let hotkeys: HotkeyManager

    init() {
        let secrets = KeychainSecretStore()
        let settings = UserDefaultsSettingsStore()
        let mirror = SettingsMirror(store: settings)
        let permissions = PermissionsService()
        let trace = LatencyTrace()
        let providers = ProviderRegistry(secrets: secrets, openAICompatibleBaseURL: { mirror.openAICompatibleBaseURL })
        let viewModel = BubbleViewModel()
        let bubble = BubbleController(viewModel: viewModel)   // panel built at launch (spec §5.1)
        let settingsWindow = SettingsWindowController(
            settings: settings, secrets: secrets,
            bridgeStatus: { nil }, pairingToken: { "" }, regenerateToken: { "" },
            permissions: { permissions.status }, openPermission: { permissions.open($0) })
        let coordinator = SummonCoordinator(viewModel: viewModel, bubble: bubble, providers: providers,
                                            settings: settings, permissions: permissions, trace: trace,
                                            openSettings: { settingsWindow.show() })
        viewModel.actions = coordinator
        coordinator.attach(gatherer: ContextGatherer.live(browser: NoBrowserContext(), blocklist: { mirror.blocklist },
                                                          ownBundleID: "dev.local.Companion"))

        self.secrets = secrets
        self.settings = settings
        self.mirror = mirror
        self.permissions = permissions
        self.trace = trace
        self.viewModel = viewModel
        self.bubble = bubble
        self.settingsWindow = settingsWindow
        self.coordinator = coordinator
        orb = OrbController(settings: settings, onSummon: { coordinator.summon() })
        hotkeys = HotkeyManager(onSummon: { coordinator.summon() }, onRegion: { coordinator.summonRegion() })
    }

    func launch() {
        orb.setVisible(settings.settings.orbEnabled)
        settings.addObserver { [orb] in orb.setVisible($0.orbEnabled) }
        let status = permissions.status
        let hasAnyAPIKey = secrets.secret(for: SecretKey.anthropicAPIKey) != nil
            || secrets.secret(for: SecretKey.openAICompatibleAPIKey) != nil
        if FirstRunPolicy.shouldOpenSettings(screenRecording: status.screenRecording, accessibility: status.accessibility,
                                             hasAnyAPIKey: hasAnyAPIKey, defaults: .standard) {
            // The request is what lists Companion in those System Settings panes.
            if !status.screenRecording { permissions.request(.screenRecording) }
            if !status.accessibility { permissions.request(.accessibility) }
            settingsWindow.show()
        }
    }
}
