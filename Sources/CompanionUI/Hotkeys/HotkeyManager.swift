import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    public static let summon = Self("summon", default: .init(.space, modifiers: [.option]))
    public static let regionCapture = Self("regionCapture", default: .init(.space, modifiers: [.option, .shift]))
}

/// Registers the global hotkeys for as long as the app runs.
@MainActor public final class HotkeyManager {
    private let onSummon: @MainActor () -> Void
    private let onRegion: @MainActor () -> Void

    public init(onSummon: @escaping @MainActor () -> Void, onRegion: @escaping @MainActor () -> Void) {
        self.onSummon = onSummon
        self.onRegion = onRegion
        for name in [KeyboardShortcuts.Name.summon, .regionCapture] {
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                MainActor.assumeIsolated { self?.handle(name) }
            }
        }
    }

    func handle(_ name: KeyboardShortcuts.Name) {
        if name == .summon {
            onSummon()
        } else if name == .regionCapture {
            onRegion()
        }
    }
}
