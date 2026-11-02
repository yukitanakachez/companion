@testable import CompanionSession
import Testing

@MainActor final class ManualClock {
    private let base = ContinuousClock.now
    private var elapsed = Duration.zero

    func advance(_ duration: Duration) { elapsed += duration }

    var read: @MainActor () -> ContinuousClock.Instant {
        { [self] in base + elapsed }
    }
}

@MainActor @Test func summaryTextFormat() {
    let clock = ManualClock()
    let trace = LatencyTrace(now: clock.read)
    let typingMs = Array(repeating: 5000, count: 5)              // evicted by the 20-slot ring
        + Array(repeating: 30, count: 9) + [42] + Array(repeating: 50, count: 8) + [70, 90]
    for ms in typingMs {
        trace.begin()
        clock.advance(.milliseconds(ms))
        trace.mark(.inputReady)
        trace.mark(.submit)
        clock.advance(.milliseconds(1200))
        trace.mark(.firstToken)
    }
    #expect(trace.records.count == 20)
    #expect(trace.summaryText == "Last 20 summons — hotkey→typing median 42 ms, p95 70 ms · submit→first token median 1.2 s")
}

@MainActor @Test func firstMarkWinsAndOffsetsAreRelative() {
    let clock = ManualClock()
    let trace = LatencyTrace(now: clock.read)
    trace.begin()
    clock.advance(.milliseconds(10))
    trace.mark(.panelVisible)
    clock.advance(.milliseconds(5))
    trace.mark(.panelVisible)
    #expect(trace.records[0].offsets[.panelVisible] == .milliseconds(10))
    #expect(trace.records[0].offsets[.hotkey] == .zero)
}

@MainActor @Test func markBeforeBeginIsIgnored() {
    let trace = LatencyTrace()
    trace.mark(.submit)
    #expect(trace.records.isEmpty)
}

@MainActor @Test func summaryWithMissingData() {
    let clock = ManualClock()
    let trace = LatencyTrace(now: clock.read)
    #expect(trace.summaryText == "No summons recorded yet.")
    trace.begin()
    clock.advance(.milliseconds(40))
    trace.mark(.inputReady)
    #expect(trace.summaryText == "Last 1 summon — hotkey→typing median 40 ms, p95 40 ms · submit→first token —")
}
