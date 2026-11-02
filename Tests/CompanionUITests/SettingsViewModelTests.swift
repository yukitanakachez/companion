import AppKit
import CompanionCore
import CompanionTestSupport
import Testing
@testable import CompanionUI

@MainActor struct SettingsViewModelTests {
    let haiku = ModelCatalog.haiku45, sonnet = ModelCatalog.sonnet55
    let store: FakeSettingsStore
    let secrets: FakeSecretStore
    let vm: SettingsViewModel
    let counter = Counter()
    @MainActor final class Counter { var calls = 0 }

    init() { self.init(settings: .default) }
    init(settings: AppSettings, pollInterval: Duration = .milliseconds(20)) {
        let store = FakeSettingsStore(settings), secrets = FakeSecretStore([SecretKey.anthropicAPIKey: "old"]), counter = counter
        var token = "aaa"
        self.store = store; self.secrets = secrets
        vm = SettingsViewModel(settings: store, secrets: secrets,
                               bridgeStatus: { counter.calls += 1; return nil },
                               pairingToken: { token },
                               regenerateToken: { token = "bbb"; return token },
                               permissions: { PermissionStatus(screenRecording: true, accessibility: false) },
                               openPermission: { _ in },
                               pollInterval: pollInterval)
    }

    @Test func keysAreTrimmedAndEmptyDeletes() {
        #expect(vm.anthropicKeyDraft == "old")
        vm.anthropicKeyDraft = "  sk-ant-123 \n"; vm.openAIKeyDraft = "\tsk-oa\n"; vm.commitAll()
        #expect(secrets.secret(for: SecretKey.anthropicAPIKey) == "sk-ant-123" && secrets.secret(for: SecretKey.openAICompatibleAPIKey) == "sk-oa")
        vm.anthropicKeyDraft = "   "; vm.commitAnthropicKey(); #expect(secrets.secret(for: SecretKey.anthropicAPIKey) == nil)
    }
    @Test func baseURLValidation() {
        vm.baseURLDraft = "  https://openrouter.ai/api/v1 "; vm.commitBaseURL(); #expect(vm.baseURLError == nil)
        vm.baseURLDraft = "not a url"; vm.commitBaseURL()
        #expect(store.settings.openAICompatibleBaseURL == "https://openrouter.ai/api/v1" && vm.baseURLError != nil)
    }
    @Test func removingADefaultReassignsItToTheFirst() {
        #expect(vm.removeModel(sonnet)); let r = store.settings.routing
        #expect(store.settings.modelCycle == [haiku] && r.mathPage == haiku && r.pdfPages == haiku && r.region == haiku)
    }
    @Test func removingTheFirstReassignsToTheNewFirst() {
        vm.removeModel(haiku); let r = store.settings.routing; #expect(r.youtube == sonnet && r.webPage == sonnet && r.genericWindow == sonnet)
    }
    @Test func cycleCannotBecomeEmpty() {
        var one = AppSettings.default; one.modelCycle = [haiku]
        let t = SettingsViewModelTests(settings: one)
        #expect(t.vm.removeModel(haiku) == false && t.store.settings.modelCycle == [haiku])
    }
    @Test func addModelTrimsDefaultsNameAndDedupes() {
        #expect(vm.addModel(providerID: ModelRef.openAICompatibleProviderID, modelID: " gpt-5 ", displayName: ""))
        #expect(store.settings.modelCycle.last == ModelRef(providerID: "openai-compatible", modelID: "gpt-5", displayName: "gpt-5"))
        #expect(!vm.addModel(providerID: "openai-compatible", modelID: "gpt-5", displayName: "x") && !vm.addModel(providerID: "anthropic", modelID: " ", displayName: ""))
        vm.setDefault(sonnet, for: .youtube); #expect(store.settings.routing.youtube == sonnet)
    }
    @Test func blocklistEditing() {
        vm.addBlockedDomain("  HTTPS://Www.Example.com/login "); vm.addBlockedDomain("www.example.com"); vm.addBlockedApp(" com.foo.bar ")
        #expect(store.settings.blocklist.domains.filter { $0 == "www.example.com" }.count == 1 && store.settings.blocklist.bundleIDs.contains("com.foo.bar"))
        vm.removeBlockedDomain("www.example.com"); vm.removeBlockedApp("com.foo.bar")
        #expect(!store.settings.blocklist.domains.contains("www.example.com") && !store.settings.blocklist.bundleIDs.contains("com.foo.bar"))
        vm.setOrbEnabled(false); #expect(store.settings.orbEnabled == false)
    }
    @Test func bridgeAndToken() {
        #expect(SettingsViewModel.bridgeStatusText(nil) == "Bridge not running")
        #expect(SettingsViewModel.bridgeStatusText(BridgeStatus(port: 47823, connectedBrowsers: [])) == "Listening on port 47823 · no browser connected")
        #expect(SettingsViewModel.bridgeStatusText(BridgeStatus(port: 47823, connectedBrowsers: ["Dia"])) == "Connected: Dia (port 47823)")
        #expect(vm.pairingToken == "aaa"); vm.regenerateToken(); #expect(vm.pairingToken == "bbb")
    }
    @Test func labels() {
        #expect(ContextKind.allCases.map(SettingsViewModel.label(for:)) == ["YouTube", "Math on a web page", "Web page", "Textbook pages", "Any other window", "Region capture"])
    }
    @Test func pollingRefreshesUntilStopped() async throws {
        vm.startPolling()
        // Deadline, not a fixed sleep: parallel suites share the main actor and can stall this one.
        let deadline = ContinuousClock.now + .seconds(5)
        while counter.calls < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let n = counter.calls; #expect(n >= 3)
        vm.stopPolling(); try await Task.sleep(for: .milliseconds(60)); #expect(counter.calls <= n + 1)
    }
}

extension WindowTests { @MainActor @Suite struct SettingsWindowTests {
    // An accessory app has no Edit menu: without this an API key can't be pasted into Settings.
    @Test func windowHandlesEditShortcuts() {
        TestApp.ensure()
        let window = EditShortcutWindow(contentRect: CGRect(x: -3000, y: -3000, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 100)); text.string = "abc"
        window.contentView?.addSubview(text); window.makeFirstResponder(text)
        #expect(window.performKeyEquivalent(with: keyEvent(0, "a", [.command])))
        #expect(text.selectedRange() == NSRange(location: 0, length: 3))
    }
    @Test func showCreatesOneWindowAndCommitsOnClose() {
        TestApp.ensure()
        let store = FakeSettingsStore(), secrets = FakeSecretStore()
        let c = SettingsWindowController(settings: store, secrets: secrets, bridgeStatus: { nil }, pairingToken: { "t" }, regenerateToken: { "t" },
                                         permissions: { PermissionStatus(screenRecording: false, accessibility: false) }, openPermission: { _ in })
        c.show(tab: .models); let w = c.window
        #expect(w?.isVisible == true && w?.title == "Companion Settings" && w?.contentRect(forFrameRect: w!.frame).size == CGSize(width: 560, height: 480))
        #expect(w?.styleMask.contains(.resizable) == false)
        c.viewModel.anthropicKeyDraft = "k"
        c.show(); #expect(c.window === w && c.viewModel.selectedTab == .models)
        w?.close(); #expect(secrets.secret(for: SecretKey.anthropicAPIKey) == "k")
    }
}}
