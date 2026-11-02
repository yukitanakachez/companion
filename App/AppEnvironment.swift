import AppKit
import CompanionBridge
import CompanionCapture
import CompanionCore
import CompanionLLM
import CompanionPageFinder
import CompanionSession
import CompanionUI
import Foundation
import os

/// Composition root: builds the objects and wires callbacks. Behaviour lives in CompanionSession.
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
    private let bridge: BridgeServer
    private let cache: PDFSessionCache
    private let logger = Logger(subsystem: "dev.local.Companion", category: "app")

    init() {
        let secrets = KeychainSecretStore()
        let settings = UserDefaultsSettingsStore()
        let mirror = SettingsMirror(store: settings)
        let permissions = PermissionsService()
        let trace = LatencyTrace()
        let providers = ProviderRegistry(secrets: secrets, openAICompatibleBaseURL: { mirror.openAICompatibleBaseURL })
        let viewModel = BubbleViewModel()
        let bubble = BubbleController(viewModel: viewModel)   // panel built at launch (spec §5.1)
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let bridge = BridgeServer(secrets: secrets, blocklist: settings.settings.blocklist, appVersion: appVersion)
        let settingsWindow = SettingsWindowController(
            settings: settings, secrets: secrets,
            bridgeStatus: { await bridge.status() },
            pairingToken: { (try? BridgePairing.token(in: secrets)) ?? "" },
            regenerateToken: { (try? BridgePairing.regenerate(in: secrets)) ?? "" },
            permissions: { permissions.status }, openPermission: { permissions.open($0) })
        let coordinator = SummonCoordinator(viewModel: viewModel, bubble: bubble, providers: providers,
                                            settings: settings, permissions: permissions, trace: trace,
                                            openSettings: { settingsWindow.show(tab: .models) })   // the app-Settings banners are all about keys
        viewModel.actions = coordinator
        coordinator.attach(gatherer: ContextGatherer.live(browser: bridge.browserContext, blocklist: { mirror.blocklist },
                                                          ownBundleID: "dev.local.Companion"))
        let cache = PDFSessionCache()
        coordinator.attach(pageFinder: PageFinder(fetcher: bridge.documentFetcher, viewer: bridge.viewerDriver, cache: cache),
                           browser: bridge.browserContext)

        self.secrets = secrets
        self.settings = settings
        self.mirror = mirror
        self.permissions = permissions
        self.trace = trace
        self.viewModel = viewModel
        self.bubble = bubble
        self.settingsWindow = settingsWindow
        self.coordinator = coordinator
        self.bridge = bridge
        self.cache = cache
        orb = OrbController(settings: settings, onSummon: { coordinator.summon() })
        hotkeys = HotkeyManager(onSummon: { coordinator.summon() }, onRegion: { coordinator.summonRegion() })
    }

    func launch() {
        orb.setVisible(settings.settings.orbEnabled)
        settings.addObserver { [orb] in orb.setVisible($0.orbEnabled) }
        syncBlocklistToBridge()
        Task { [cache, bridge, logger] in
            await cache.clearAll()   // leftovers from a crash or force-quit
            do {
                _ = try await bridge.start()
            } catch {
                // The app stays usable without the extension; Settings simply shows no port.
                logger.error("Bridge failed to start: \(String(describing: error), privacy: .public)")
            }
        }
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

    /// One stream with a single consumer: a task per change could apply updates out of order.
    private func syncBlocklistToBridge() {
        let (updates, continuation) = AsyncStream.makeStream(of: BlocklistConfig.self)
        var last = settings.settings.blocklist
        settings.addObserver { current in
            guard current.blocklist != last else { return }
            last = current.blocklist
            continuation.yield(current.blocklist)
        }
        Task { [bridge] in
            for await config in updates { await bridge.updateBlocklist(config) }
        }
    }

    /// Bounded, so a transfer stuck in `bridge.stop()` can't hold up quit or the cache clear.
    func shutdown() async {
        coordinator.cancelAll()
        _ = await Shutdown.run(perStepTimeout: .seconds(1), [
            { [bridge] in await bridge.stop() },
            { [cache] in await cache.clearAll() },
        ])
    }
}
