import os

/// A value delivered at most once, by whichever side gets there first.
final class OneShot<T: Sendable>: Sendable {
    private struct State: Sendable {
        var waiter: CheckedContinuation<T, Never>?
        var value: T?
        var delivered = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait() async -> T {
        await withCheckedContinuation { continuation in
            let ready: T? = state.withLock { state in
                guard state.delivered else {
                    state.waiter = continuation
                    return nil
                }
                return state.value
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func deliver(_ value: T) {
        let waiter: CheckedContinuation<T, Never>? = state.withLock { state in
            guard !state.delivered else { return nil }
            state.delivered = true
            state.value = value
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: value)
    }
}

/// Runs `work` in its own task and returns its result, or nil as soon as the caller is cancelled,
/// even if `work` ignores cancellation. A task group couldn't do this: it waits for its children.
func abandonOnCancel<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T? {
    let result = OneShot<T?>()
    let task = Task { result.deliver(await work()) }
    return await withTaskCancellationHandler {
        await result.wait()
    } onCancel: {
        task.cancel()
        result.deliver(nil)
    }
}
