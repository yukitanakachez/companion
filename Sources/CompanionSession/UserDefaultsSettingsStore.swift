import CompanionCore
import Foundation

@MainActor public final class UserDefaultsSettingsStore: SettingsStoring {
    public static let key = "settings.v1"

    public private(set) var settings: AppSettings
    private let defaults: UserDefaults
    private var observers: [@MainActor (AppSettings) -> Void] = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? .default
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        var next = settings
        mutate(&next)
        guard next != settings else { return }
        settings = next
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.key)
        }
        for observer in observers { observer(next) }
    }

    public func addObserver(_ onChange: @escaping @MainActor (AppSettings) -> Void) {
        observers.append(onChange)
    }
}
