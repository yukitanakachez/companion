public enum SettingsTab: Sendable, CaseIterable {
    case general, models, privacy, browserExtension, permissions

    var title: String {
        switch self {
        case .general: "General"
        case .models: "Models"
        case .privacy: "Privacy"
        case .browserExtension: "Browser Extension"
        case .permissions: "Permissions"
        }
    }
}
