@testable import CompanionSession
import Testing

private actor Log {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
}

@Test func stepsRunInOrder() async {
    let log = Log()
    let timedOut = await Shutdown.run(perStepTimeout: .seconds(1), [
        { await log.append("cancel") }, { await log.append("stop") }, { await log.append("clear") },
    ])
    #expect(await log.entries == ["cancel", "stop", "clear"])
    #expect(timedOut == [])
}

@Test func hangingStepDoesNotBlockLaterSteps() async {
    let log = Log()
    let start = ContinuousClock.now
    let timedOut = await Shutdown.run(perStepTimeout: .milliseconds(100), [
        { try? await Task.sleep(for: .seconds(30)) },        // bridge.stop() stuck mid-PDF-transfer
        { await log.append("clear") },
    ])
    #expect(timedOut == [0])
    #expect(await log.entries == ["clear"])
    #expect(ContinuousClock.now - start < .seconds(1))
}

/// A step that ignores cancellation, unlike `Task.sleep`, is the real hung-transfer case.
@Test func stepIgnoringCancellationIsAbandoned() async {
    let log = Log()
    let timedOut = await Shutdown.run(perStepTimeout: .milliseconds(50), [
        { await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } },
        { await log.append("clear") },
    ])
    #expect(timedOut == [0])
    #expect(await log.entries == ["clear"])
}
