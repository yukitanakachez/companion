import CompanionCore
import Foundation

enum PrivacyGate {
    static let siteBlockedReason = "This site is on your blocklist"

    /// Rules are checked in order and the first match wins.
    static func evaluate(front: FrontAppInfo?, isBrowser: Bool, tab: TabContext?,
                         browserURL: URL?, config: BlocklistConfig) -> PrivacyDecision {
        if let front {
            let bundleID = front.bundleID.lowercased()
            if config.bundleIDs.contains(where: { $0.lowercased() == bundleID }) {
                return .blocked(reason: "\(front.appName) is on your blocklist")
            }
        }
        if isBrowser, tab?.blocked == true {
            return .blocked(reason: siteBlockedReason)
        }
        let hosts = [tab.flatMap { URL(string: $0.url)?.host }, browserURL?.host].compactMap { $0 }
        if hosts.contains(where: { host in config.domains.contains { hostMatches(host, domain: $0) } }) {
            return .blocked(reason: siteBlockedReason)
        }
        if isBrowser, hosts.isEmpty {
            return .siteUnchecked
        }
        return .allowed
    }

    static func hostMatches(_ host: String, domain: String) -> Bool {
        let host = normalized(host), domain = normalized(domain)
        guard !host.isEmpty, !domain.isEmpty else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }

    private static func normalized(_ name: String) -> String {
        let lowered = name.lowercased()
        return lowered.hasSuffix(".") ? String(lowered.dropLast()) : lowered
    }
}
