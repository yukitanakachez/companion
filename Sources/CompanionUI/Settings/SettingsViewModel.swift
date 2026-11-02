import AppKit
import CompanionCore
import Observation

extension RoutingDefaults {
    mutating func set(_ model: ModelRef, for kind: ContextKind) {
        switch kind {
        case .youtube: youtube = model
        case .mathPage: mathPage = model
        case .webPage: webPage = model
        case .pdfPages: pdfPages = model
        case .genericWindow: genericWindow = model
        case .region: region = model
        }
    }
}

@MainActor @Observable final class SettingsViewModel {
    private(set) var settings: AppSettings
    var anthropicKeyDraft: String
    var openAIKeyDraft: String
    var baseURLDraft: String
    private(set) var keyError: String?
    private(set) var baseURLError: String?
    private(set) var pairingToken: String
    private(set) var bridgeStatus: BridgeStatus?
    private(set) var permissionStatus: PermissionStatus
    var selectedTab = SettingsTab.general

    @ObservationIgnored private let store: any SettingsStoring
    @ObservationIgnored private let secrets: any SecretStoring
    @ObservationIgnored private let bridgeStatusClosure: @MainActor () async -> BridgeStatus?
    @ObservationIgnored private let regenerateTokenClosure: @MainActor () -> String
    @ObservationIgnored private let permissions: @MainActor () -> PermissionStatus
    @ObservationIgnored private let openPermissionClosure: @MainActor (PermissionKind) -> Void
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(settings store: any SettingsStoring, secrets: any SecretStoring,
         bridgeStatus: @escaping @MainActor () async -> BridgeStatus?,
         pairingToken: @escaping @MainActor () -> String,
         regenerateToken: @escaping @MainActor () -> String,
         permissions: @escaping @MainActor () -> PermissionStatus,
         openPermission: @escaping @MainActor (PermissionKind) -> Void,
         pollInterval: Duration = .seconds(2)) {
        self.store = store
        self.secrets = secrets
        bridgeStatusClosure = bridgeStatus
        regenerateTokenClosure = regenerateToken
        self.permissions = permissions
        openPermissionClosure = openPermission
        self.pollInterval = pollInterval
        settings = store.settings
        anthropicKeyDraft = secrets.secret(for: SecretKey.anthropicAPIKey) ?? ""
        openAIKeyDraft = secrets.secret(for: SecretKey.openAICompatibleAPIKey) ?? ""
        baseURLDraft = store.settings.openAICompatibleBaseURL
        self.pairingToken = pairingToken()
        permissionStatus = permissions()
        store.addObserver { [weak self] in self?.settings = $0 }
    }

    // MARK: Keys and base URL

    func commitAnthropicKey() { commitKey(anthropicKeyDraft, for: SecretKey.anthropicAPIKey) }
    func commitOpenAIKey() { commitKey(openAIKeyDraft, for: SecretKey.openAICompatibleAPIKey) }

    func commitBaseURL() {
        let trimmed = baseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            baseURLError = "Enter a URL starting with http:// or https://"
            return
        }
        baseURLError = nil
        baseURLDraft = trimmed
        store.update { $0.openAICompatibleBaseURL = trimmed }
    }

    func commitAll() {
        commitAnthropicKey()
        commitOpenAIKey()
        commitBaseURL()
    }

    private func commitKey(_ draft: String, for key: String) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try secrets.setSecret(trimmed.isEmpty ? nil : trimmed, for: key)
            keyError = nil
        } catch {
            keyError = "Couldn't save the key: \(error.localizedDescription)"
        }
    }

    // MARK: Settings

    func setOrbEnabled(_ on: Bool) { store.update { $0.orbEnabled = on } }

    @discardableResult func addModel(providerID: String, modelID: String, displayName: String) -> Bool {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty,
              !settings.modelCycle.contains(where: { $0.providerID == providerID && $0.modelID == id }) else { return false }
        let model = ModelRef(providerID: providerID, modelID: id, displayName: name.isEmpty ? id : name)
        store.update { $0.modelCycle.append(model) }
        return true
    }

    /// False when it is the last one. Routing defaults that used it move to the new first model.
    @discardableResult func removeModel(_ model: ModelRef) -> Bool {
        guard settings.modelCycle.count > 1, settings.modelCycle.contains(model) else { return false }
        store.update { settings in
            settings.modelCycle.removeAll { $0 == model }
            let first = settings.modelCycle[0]
            for kind in ContextKind.allCases where settings.routing.model(for: kind) == model {
                settings.routing.set(first, for: kind)
            }
        }
        return true
    }

    func setDefault(_ model: ModelRef, for kind: ContextKind) { store.update { $0.routing.set(model, for: kind) } }

    func addBlockedApp(_ bundleID: String) {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !settings.blocklist.bundleIDs.contains(id) else { return }
        store.update { $0.blocklist.bundleIDs.append(id) }
    }

    func removeBlockedApp(_ bundleID: String) { store.update { $0.blocklist.bundleIDs.removeAll { $0 == bundleID } } }

    func addBlockedDomain(_ domain: String) {
        let host = Self.normalizedDomain(domain)
        guard !host.isEmpty, !settings.blocklist.domains.contains(host) else { return }
        store.update { $0.blocklist.domains.append(host) }
    }

    func removeBlockedDomain(_ domain: String) { store.update { $0.blocklist.domains.removeAll { $0 == domain } } }

    private static func normalizedDomain(_ input: String) -> String {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
        if let end = host.firstIndex(where: { "/?#".contains($0) }) { host = String(host[..<end]) }
        return host
    }

    // MARK: Bridge and permissions

    func copyToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingToken, forType: .string)
    }

    func regenerateToken() { pairingToken = regenerateTokenClosure() }

    /// Refreshes bridge status and permissions now, then every `pollInterval`.
    func startPolling() {
        pollTask?.cancel()
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let status = await self.bridgeStatusClosure()
                guard !Task.isCancelled else { return }
                self.bridgeStatus = status
                self.permissionStatus = self.permissions()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func openPermission(_ kind: PermissionKind) { openPermissionClosure(kind) }

    static func bridgeStatusText(_ status: BridgeStatus?) -> String {
        guard let status, let port = status.port else { return "Bridge not running" }
        if status.connectedBrowsers.isEmpty { return "Listening on port \(port) · no browser connected" }
        return "Connected: \(status.connectedBrowsers.joined(separator: ", ")) (port \(port))"
    }

    static func label(for kind: ContextKind) -> String {
        switch kind {
        case .youtube: "YouTube"
        case .mathPage: "Math on a web page"
        case .webPage: "Web page"
        case .pdfPages: "Textbook pages"
        case .genericWindow: "Any other window"
        case .region: "Region capture"
        }
    }
}
