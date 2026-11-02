public struct BlocklistConfig: Codable, Sendable, Equatable {
    public var bundleIDs: [String]
    /// Matched as the host or a dot-suffix of it (WS5/WS3 implement matching).
    public var domains: [String]

    public init(bundleIDs: [String], domains: [String]) {
        self.bundleIDs = bundleIDs
        self.domains = domains
    }

    public static let starter = BlocklistConfig(
        bundleIDs: [
            "com.1password.1password",
            "com.agilebits.onepassword7",
            "com.bitwarden.desktop",
            "com.lastpass.LastPass",
            "com.apple.keychainaccess",
            "com.apple.Passwords",
            "com.apple.MobileSMS",
            "com.hnc.Discord",
            "net.whatsapp.WhatsApp",
            "ru.keepcoder.Telegram",
            "org.whispersystems.signal-desktop",
        ],
        domains: [
            "1password.com",
            "bitwarden.com",
            "lastpass.com",
            "dashlane.com",
            "chase.com",
            "bankofamerica.com",
            "wellsfargo.com",
            "citi.com",
            "capitalone.com",
            "usbank.com",
            "pnc.com",
            "schwab.com",
            "fidelity.com",
            "paypal.com",
            "venmo.com",
            "discord.com",
            "web.whatsapp.com",
            "messages.google.com",
        ]
    )
}
