import AppKit
import CompanionCore
@testable import CompanionSession
import CompanionTestSupport
import CompanionUI
import Foundation
import Testing

@MainActor final class FakePresenter: BubblePresenting {
    private(set) var isVisible = false
    private(set) var showCalls: [(cursor: NSPoint, avoiding: CGRect?)] = []
    private(set) var focusCount = 0
    private(set) var hideCount = 0

    func show(cursor: NSPoint, avoiding: CGRect?) {
        showCalls.append((cursor, avoiding))
        isVisible = true
    }
    func focusInput() { focusCount += 1 }
    func hide() {
        hideCount += 1
        isVisible = false
    }
}

@MainActor final class FakePermissions: PermissionChecking {
    var screenRecordingGranted: Bool
    var accessibilityGranted: Bool
    private(set) var opened: [PermissionKind] = []

    init(screenRecording: Bool = true, accessibility: Bool = true) {
        screenRecordingGranted = screenRecording
        accessibilityGranted = accessibility
    }

    func openSettings(for permission: PermissionKind) { opened.append(permission) }
}

final class FakeProviders: ProviderResolving, @unchecked Sendable {
    private let lock = NSLock()
    private let byModelID: [String: FakeLLMProvider]
    let fallback: FakeLLMProvider
    private var missing: Set<String> = []
    private var resolvedModels: [ModelRef] = []

    init(_ byModelID: [String: FakeLLMProvider] = [:], fallback: FakeLLMProvider = FakeLLMProvider()) {
        self.byModelID = byModelID
        self.fallback = fallback
    }

    var missingKeyProviders: Set<String> {
        get { lock.withLock { missing } }
        set { lock.withLock { missing = newValue } }
    }
    var resolved: [ModelRef] { lock.withLock { resolvedModels } }

    func provider(for model: ModelRef) throws -> any LLMProvider {
        try lock.withLock {
            resolvedModels.append(model)
            if missing.contains(model.providerID) { throw LLMError.missingAPIKey(providerID: model.providerID) }
            return byModelID[model.modelID] ?? fallback
        }
    }
}

@MainActor final class Harness {
    let vm = BubbleViewModel()
    let presenter = FakePresenter()
    let providers: FakeProviders
    let permissions: FakePermissions
    let settings = FakeSettingsStore()
    let trace = LatencyTrace()
    let clock = TestClock()
    private(set) var openSettingsCount = 0
    private(set) var coordinator: SummonCoordinator!

    var provider: FakeLLMProvider { providers.fallback }

    init(providers: FakeProviders = FakeProviders(), permissions: FakePermissions = FakePermissions()) {
        self.providers = providers
        self.permissions = permissions
        coordinator = SummonCoordinator(viewModel: vm, presenter: presenter, providers: providers,
                                        settings: settings, permissions: permissions, trace: trace,
                                        now: clock.read, cursor: { NSPoint(x: 500, y: 400) },
                                        openSettings: { [unowned self] in openSettingsCount += 1 })
    }

    func submit(_ question: String) async {
        coordinator.bubbleDidSubmit(question)
        await coordinator.settle()
    }
}

@MainActor func waitUntil(_ timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline {
            Issue.record("waitUntil timed out")
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}
