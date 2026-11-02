import CompanionCore

public struct ModelRouter: Sendable {
    private let defaults: RoutingDefaults
    private let cycle: [ModelRef]

    public init(defaults: RoutingDefaults, cycle: [ModelRef]) {
        self.defaults = defaults
        self.cycle = cycle
    }

    public func model(for kind: ContextKind) -> ModelRef {
        defaults.model(for: kind)
    }

    /// Wraps. `current` not in the cycle → the first model; empty cycle → `current`.
    /// Membership compares providerID and modelID only: a user-edited displayName must not break Tab cycling.
    public func next(after current: ModelRef) -> ModelRef {
        guard let first = cycle.first else { return current }
        guard let index = cycle.firstIndex(where: { $0.providerID == current.providerID && $0.modelID == current.modelID }) else {
            return first
        }
        return cycle[(index + 1) % cycle.count]
    }
}
