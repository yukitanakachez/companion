import Foundation

public enum FirstRunPolicy {
    public static let shownKey = "onboarding.settingsShown.v1"

    /// True — and records it — the first time anything required is missing; false afterwards or when nothing is missing.
    public static func shouldOpenSettings(screenRecording: Bool, accessibility: Bool, hasAnyAPIKey: Bool,
                                          defaults: UserDefaults) -> Bool {
        guard !(screenRecording && accessibility && hasAnyAPIKey), !defaults.bool(forKey: shownKey) else { return false }
        defaults.set(true, forKey: shownKey)
        return true
    }
}
