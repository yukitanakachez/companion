import AppKit
import CompanionCapture
import CompanionCore
import CompanionPageFinder
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

actor FakeGatherer: ContextGathering {
    private let emissions: [CapturedContext]
    private let gap: Duration
    private(set) var requests: [GatherRequest] = []

    init(emissions: [CapturedContext], gap: Duration = .zero) {
        self.emissions = emissions
        self.gap = gap
    }

    func gather(_ request: GatherRequest) async -> AsyncStream<CapturedContext> {
        requests.append(request)
        let (emissions, gap) = (emissions, gap)
        return AsyncStream { continuation in
            let task = Task {
                for (index, emission) in emissions.enumerated() {
                    if index > 0, gap > .zero { try? await Task.sleep(for: gap) }
                    continuation.yield(emission)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor final class FakeRegionSelector: RegionSelecting {
    private(set) var selectCount = 0
    private var pending: CheckedContinuation<RegionSelection?, Never>?

    func select() async -> RegionSelection? {
        selectCount += 1
        return await withCheckedContinuation { pending = $0 }
    }

    func finish(_ selection: RegionSelection?) {
        pending?.resume(returning: selection)
        pending = nil
    }
}

@MainActor final class FakeGlow: GlowFlashing {
    private(set) var flashed: [CGRect] = []
    func flash(_ rect: CGRect) { flashed.append(rect) }
}

func ctx(kind: ContextKind = .genericWindow, frame: CGRect? = CGRect(x: 100, y: 100, width: 800, height: 600),
         items: [ContextItem] = [], complete: Bool, privacy: PrivacyDecision = .allowed,
         bundleID: String = "com.apple.Notes") -> CapturedContext {
    CapturedContext(front: FrontAppInfo(bundleID: bundleID, appName: "App", pid: 1, windowTitle: "Window", windowFrame: frame),
                    privacy: privacy, kind: kind, items: items, isComplete: complete)
}

actor FakePageFinder: PageFinding {
    private let outcome: PageFinderOutcome
    private let steps: [PageFinderStep]
    private let hangFirstCall: Bool
    private var hanging: CheckedContinuation<Void, Never>?
    private(set) var calls: [(reference: PageReference, tab: TabContext?, lastUsed: DriveFileRef?, preferred: DriveFileRef?)] = []

    /// `hangFirstCall` ignores cancellation, like a `fetchDrivePDF` pending for up to 120 s.
    init(outcome: PageFinderOutcome, steps: [PageFinderStep] = [], hangFirstCall: Bool = false) {
        self.outcome = outcome
        self.steps = steps
        self.hangFirstCall = hangFirstCall
    }

    func find(_ reference: PageReference, question: String, tab: TabContext?, lastUsed: DriveFileRef?,
              preferred: DriveFileRef?, progress: @escaping @Sendable (PageFinderStep) -> Void) async -> PageFinderOutcome {
        calls.append((reference, tab, lastUsed, preferred))
        for step in steps { progress(step) }
        if hangFirstCall, calls.count == 1 {
            await withCheckedContinuation { hanging = $0 }
        }
        return outcome
    }

    func release() {
        hanging?.resume()
        hanging = nil
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

    let gatherer: FakeGatherer
    let selector = FakeRegionSelector()
    let glow = FakeGlow()

    init(providers: FakeProviders = FakeProviders(), permissions: FakePermissions = FakePermissions(),
         gatherer: FakeGatherer = FakeGatherer(emissions: []),
         pageFinder: FakePageFinder? = nil, browser: FakeBrowserContextProvider? = nil) {
        self.providers = providers
        self.permissions = permissions
        self.gatherer = gatherer
        coordinator = SummonCoordinator(viewModel: vm, presenter: presenter, providers: providers,
                                        settings: settings, permissions: permissions, trace: trace,
                                        now: clock.read, cursor: { NSPoint(x: 500, y: 400) },
                                        openSettings: { [unowned self] in openSettingsCount += 1 })
        coordinator.gatherer = gatherer
        coordinator.regionSelector = selector
        coordinator.glow = glow
        if let pageFinder { coordinator.pageFinder = pageFinder }
        if let browser { coordinator.browser = browser }
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
