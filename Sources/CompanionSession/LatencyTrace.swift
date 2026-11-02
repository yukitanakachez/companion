import Foundation
import os

public enum LatencyMark: String, CaseIterable, Sendable {
    case hotkey, panelVisible, inputReady, contextFirst, contextComplete, submit, firstToken, finished
}

public struct SummonTiming: Sendable, Equatable {
    /// Relative to `.hotkey`, which is `.zero`.
    public var offsets: [LatencyMark: Duration]

    public init(offsets: [LatencyMark: Duration]) {
        self.offsets = offsets
    }
}

/// Ring buffer of the last 20 summons, with signposts for Instruments (spec §5.1).
@MainActor public final class LatencyTrace {
    public static let capacity = 20

    public private(set) var records: [SummonTiming] = []
    private let now: @MainActor () -> ContinuousClock.Instant
    private var startedAt: ContinuousClock.Instant?
    private var openInterval: OSSignpostIntervalState?
    private let signposter = OSSignposter(subsystem: "dev.local.Companion", category: "summon")
    private let logger = Logger(subsystem: "dev.local.Companion", category: "latency")

    public init(now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    public func begin() {
        endOpenInterval()
        openInterval = signposter.beginInterval("summon")
        startedAt = now()
        records.append(SummonTiming(offsets: [.hotkey: .zero]))
        if records.count > Self.capacity {
            records.removeFirst(records.count - Self.capacity)
        }
    }

    public func mark(_ mark: LatencyMark) {
        guard let startedAt, let last = records.indices.last,
              records[last].offsets[mark] == nil else { return }
        let offset = now() - startedAt
        records[last].offsets[mark] = offset
        signposter.emitEvent("mark", "\(mark.rawValue, privacy: .public)")
        if mark == .finished {
            endOpenInterval()
            let typing = records[last].offsets[.inputReady].map(Self.format) ?? "—"
            let token = Self.firstTokenLatency(records[last]).map(Self.format) ?? "—"
            logger.info("hotkey→typing \(typing, privacy: .public), submit→first token \(token, privacy: .public)")
        }
    }

    public var summaryText: String {
        guard !records.isEmpty else { return "No summons recorded yet." }
        let noun = records.count == 1 ? "summon" : "summons"
        let typing = records.compactMap { $0.offsets[.inputReady] }
        let tokens = records.compactMap(Self.firstTokenLatency)
        let typingText = typing.isEmpty ? "hotkey→typing —"
            : "hotkey→typing median \(Self.format(Self.percentile(typing, 50))), p95 \(Self.format(Self.percentile(typing, 95)))"
        let tokenText = tokens.isEmpty ? "submit→first token —"
            : "submit→first token median \(Self.format(Self.percentile(tokens, 50)))"
        return "Last \(records.count) \(noun) — \(typingText) · \(tokenText)"
    }

    private func endOpenInterval() {
        if let openInterval { signposter.endInterval("summon", openInterval) }
        openInterval = nil
    }

    private static func firstTokenLatency(_ record: SummonTiming) -> Duration? {
        guard let submit = record.offsets[.submit], let token = record.offsets[.firstToken] else { return nil }
        return token - submit
    }

    /// Nearest rank with integer maths, avoiding `0.95 * 20` floating-point drift.
    private static func percentile(_ samples: [Duration], _ pct: Int) -> Duration {
        let sorted = samples.sorted()
        return sorted[max(0, (sorted.count * pct + 99) / 100 - 1)]
    }

    private static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        return String(format: "%.1f s", seconds)
    }
}
