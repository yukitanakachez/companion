import os

/// The operation's value, or nil once `limit` elapses or the caller is cancelled. Never waits for a late
/// operation: it is cancelled and abandoned, so a callee that ignores cancellation cannot stall the caller.
/// Not built on a task group, because a group waits for its cancelled children.
func withTimeLimit<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async -> T?) async -> T? {
    let race = TimeLimitRace<T>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            guard race.install(continuation) else { return }
            race.add(Task { race.finish(await operation()) })
            race.add(Task {
                try? await Task.sleep(for: limit)
                race.finish(nil)
            })
        }
    } onCancel: {
        race.finish(nil)
    }
}

/// Resumes one continuation exactly once; whoever finishes first wins and cancels the others.
private final class TimeLimitRace<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T?, Never>?
        var finished = false
        var tasks: [Task<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// False when the caller was already cancelled: the continuation has been resumed with nil.
    func install(_ continuation: CheckedContinuation<T?, Never>) -> Bool {
        let alreadyFinished = state.withLock { state in
            if state.finished { return true }
            state.continuation = continuation
            return false
        }
        if alreadyFinished { continuation.resume(returning: nil) }
        return !alreadyFinished
    }

    func add(_ task: Task<Void, Never>) {
        let alreadyFinished = state.withLock { state in
            if !state.finished { state.tasks.append(task) }
            return state.finished
        }
        if alreadyFinished { task.cancel() }
    }

    func finish(_ value: T?) {
        let (continuation, tasks) = state.withLock { state -> (CheckedContinuation<T?, Never>?, [Task<Void, Never>]) in
            if state.finished { return (nil, []) }
            state.finished = true
            defer { state.continuation = nil; state.tasks = [] }
            return (state.continuation, state.tasks)
        }
        continuation?.resume(returning: value)
        tasks.forEach { $0.cancel() }
    }
}
