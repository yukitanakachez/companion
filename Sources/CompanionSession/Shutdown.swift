public enum Shutdown {
    /// Runs steps in order, each bounded by `perStepTimeout`; an overrunning step is abandoned (not awaited)
    /// and the next one runs. Returns the indices of the steps that timed out.
    public static func run(perStepTimeout: Duration, _ steps: [@Sendable () async -> Void]) async -> [Int] {
        var timedOut: [Int] = []
        for (index, step) in steps.enumerated() {
            // Not a task group: it would wait for a child that ignores cancellation.
            let finished = OneShot<Bool>()
            let work = Task {
                await step()
                finished.deliver(true)
            }
            let timer = Task {
                try? await Task.sleep(for: perStepTimeout)
                finished.deliver(false)
            }
            if await finished.wait() {
                timer.cancel()
            } else {
                work.cancel()
                timedOut.append(index)
            }
        }
        return timedOut
    }
}
