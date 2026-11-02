import CoreGraphics
import Foundation
import Testing
import CompanionCore

@Test func standardRouting() {
    let r = RoutingDefaults.standard
    for kind in [ContextKind.youtube, .webPage, .genericWindow] { #expect(r.model(for: kind) == ModelCatalog.haiku45) }
    for kind in [ContextKind.mathPage, .pdfPages, .region] { #expect(r.model(for: kind) == ModelCatalog.sonnet55) }
}

@Test func routingReadsTheFieldForEachKind() {
    func ref(_ id: String) -> ModelRef { ModelRef(providerID: "p", modelID: id, displayName: id) }
    let r = RoutingDefaults(youtube: ref("a"), mathPage: ref("b"), webPage: ref("c"), pdfPages: ref("d"), genericWindow: ref("e"), region: ref("f"))
    let ids = ContextKind.allCases.map { r.model(for: $0).modelID }
    #expect(ids == ["a", "b", "c", "d", "e", "f"])
}

@Test func modelCatalogValues() {
    #expect(ModelCatalog.haiku45 == ModelRef(providerID: "anthropic", modelID: "claude-haiku-4-5-20251001", displayName: "Haiku 4.5"))
    #expect(ModelCatalog.sonnet55 == ModelRef(providerID: "anthropic", modelID: "claude-sonnet-5-5", displayName: "Sonnet 5.5"))
    #expect(ModelCatalog.defaultCycle == [ModelCatalog.haiku45, ModelCatalog.sonnet55])
    #expect(ModelRef.anthropicProviderID == "anthropic")
    #expect(ModelRef.openAICompatibleProviderID == "openai-compatible")
}

@Test func defaultSettingsRoundTrip() throws {
    let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings.default))
    #expect(again == AppSettings.default)
}

@Test func settingsRoundTripWithOrbPosition() throws {
    var s = AppSettings.default
    s.orbPosition = CGPoint(x: 10, y: 20)
    #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s)) == s)
}

@Test func defaultSettingsValues() {
    let d = AppSettings.default
    #expect(d.openAICompatibleBaseURL == "https://api.openai.com/v1")
    #expect(d.orbEnabled)
    #expect(d.orbPosition == nil)
    #expect(d.blocklist == .starter)
    #expect(d.routing == .standard)
    #expect(d.modelCycle == ModelCatalog.defaultCycle)
}

@Test func starterBlocklistIsExact() {
    #expect(BlocklistConfig.starter.bundleIDs == [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.lastpass.LastPass",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.MobileSMS", "com.hnc.Discord",
        "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "org.whispersystems.signal-desktop"])
    #expect(BlocklistConfig.starter.domains == [
        "1password.com", "bitwarden.com", "lastpass.com", "dashlane.com", "chase.com", "bankofamerica.com",
        "wellsfargo.com", "citi.com", "capitalone.com", "usbank.com", "pnc.com", "schwab.com", "fidelity.com",
        "paypal.com", "venmo.com", "discord.com", "web.whatsapp.com", "messages.google.com"])
}

@Test func llmRequestDefaults() {
    let r = LLMRequest(model: ModelCatalog.haiku45, system: "s", messages: [LLMMessage(role: .user, content: [.text("q")])])
    #expect(r.maxTokens == 4096)
    #expect(r.tools.isEmpty)
}

@Test func secretKeys() {
    #expect(SecretKey.anthropicAPIKey == "anthropic.apiKey")
    #expect(SecretKey.openAICompatibleAPIKey == "openai-compatible.apiKey")
    #expect(SecretKey.bridgeToken == "bridge.pairingToken")
}

@Test func publicInitializersAreCallableFromOtherModules() {
    let file = DriveFileRef(fileId: "f", title: "t", mimeType: nil)
    #expect(DocumentChoice(current: file, alternatives: []).current == file)
    #expect(BridgeStatus(port: 47823, connectedBrowsers: ["Dia"]).port == 47823)
    #expect(PermissionStatus(screenRecording: true, accessibility: false).accessibility == false)
    #expect(ViewerInfo(pageCount: 2, currentIndex: 1).pageCount == 2)
    #expect(LLMToolSpec(name: "n", description: "d", inputSchemaJSON: "{}").name == "n")
    let settings = AppSettings(routing: .standard, modelCycle: [], openAICompatibleBaseURL: "u", orbEnabled: false, orbPosition: nil, blocklist: BlocklistConfig(bundleIDs: [], domains: []))
    #expect(settings.modelCycle.isEmpty)
}
