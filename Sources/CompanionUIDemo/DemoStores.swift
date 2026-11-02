import CompanionCore

@MainActor final class DemoSettingsStore: SettingsStoring {
    private(set) var settings = AppSettings.default
    private var observers: [@MainActor (AppSettings) -> Void] = []

    func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        for observer in observers { observer(settings) }
    }

    func addObserver(_ onChange: @escaping @MainActor (AppSettings) -> Void) {
        observers.append(onChange)
    }
}

final class DemoSecretStore: SecretStoring, @unchecked Sendable {
    private var values: [String: String] = [:]
    func secret(for key: String) -> String? { values[key] }
    func setSecret(_ value: String?, for key: String) throws { values[key] = value }
}
