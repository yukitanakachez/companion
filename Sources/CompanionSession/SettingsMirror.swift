import CompanionCore
import Foundation
import os

/// Lock-protected copy of the settings that background services read (gatherer blocklist, provider base URL).
public final class SettingsMirror: Sendable {
    private static let fallbackBaseURL = URL(string: "https://api.openai.com/v1")!
    private let state: OSAllocatedUnfairLock<AppSettings>

    @MainActor public init(store: any SettingsStoring) {
        let state = OSAllocatedUnfairLock(initialState: store.settings)
        self.state = state
        store.addObserver { settings in
            state.withLock { $0 = settings }
        }
    }

    public var blocklist: BlocklistConfig {
        state.withLock { $0.blocklist }
    }

    public var openAICompatibleBaseURL: URL {
        let raw = state.withLock { $0.openAICompatibleBaseURL }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else {
            return Self.fallbackBaseURL
        }
        return url
    }
}
