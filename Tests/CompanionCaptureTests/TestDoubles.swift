import CoreGraphics
import Foundation
import CompanionCore
import CompanionTestSupport
@testable import CompanionCapture

/// Ignores cancellation on purpose.
func nonCooperativeSleep(_ seconds: Double) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
    }
}

actor FakeWindowCapturer: WindowCapturing {
    private let result: Result<ImageAttachment, CaptureError>
    private let delay: Duration
    private(set) var calls = 0
    private(set) var lastFocusedFrame: CGRect?

    init(result: Result<ImageAttachment, CaptureError> = .success(Fixtures.samplePNG()), delay: Duration = .zero) {
        self.result = result
        self.delay = delay
    }

    func captureFrontWindow(pid: Int32, focusedFrame: CGRect?) async throws -> ImageAttachment {
        try? await Task.sleep(for: delay)
        calls += 1
        lastFocusedFrame = focusedFrame
        return try result.get()
    }
}

actor FakeRegionCapturer: RegionCapturing {
    private let result: Result<ImageAttachment, CaptureError>
    private let delay: Duration
    private(set) var calls = 0
    private(set) var lastSelection: RegionSelection?

    init(result: Result<ImageAttachment, CaptureError> = .success(Fixtures.samplePNG()), delay: Duration = .zero) {
        self.result = result
        self.delay = delay
    }

    func capture(_ selection: RegionSelection) async throws -> ImageAttachment {
        try? await Task.sleep(for: delay)
        calls += 1
        lastSelection = selection
        return try result.get()
    }
}

actor FakeAccessibilityReader: AccessibilityReading {
    private let front: FrontAppInfo?
    private let window: FocusedWindowInfo?
    private let selected: String?
    private let focused: String?
    private let url: URL?
    private(set) var windowCalls = 0
    private(set) var textCalls = 0
    private(set) var urlCalls = 0

    init(front: FrontAppInfo?, window: FocusedWindowInfo? = FocusedWindowInfo(title: "Doc", frame: R(100, 100, 800, 600)),
         selected: String? = nil, focused: String? = nil, url: URL? = nil) {
        self.front = front
        self.window = window
        self.selected = selected
        self.focused = focused
        self.url = url
    }

    func frontApp() async -> FrontAppInfo? { front }
    func focusedWindow(pid: Int32) async -> FocusedWindowInfo? { windowCalls += 1; return window }
    func selectedText(pid: Int32) async -> String? { textCalls += 1; return selected }
    func focusedText(pid: Int32) async -> String? { textCalls += 1; return focused }
    func browserURL(pid: Int32) async -> URL? { urlCalls += 1; return url }
}

/// Connected, no cache; `requestActiveTabContext` ignores both its timeout and cancellation.
final class StubbornBrowserProvider: BrowserContextProviding {
    private let fresh: TabContext?
    private let seconds: Double

    init(fresh: TabContext?, after seconds: Double = 1) {
        self.fresh = fresh
        self.seconds = seconds
    }

    func cachedActiveTabContext() async -> TabContext? { nil }
    func requestActiveTabContext(timeout: Duration) async -> TabContext? {
        await nonCooperativeSleep(seconds)
        return fresh
    }
    func isConnected() async -> Bool { true }
}

struct Collected {
    var emissions: [CapturedContext]
    var firstAt: Duration
    var finalAt: Duration
    var final: CapturedContext
}

func collect(_ stream: AsyncStream<CapturedContext>, since start: ContinuousClock.Instant) async -> Collected {
    var emissions: [CapturedContext] = []
    var firstAt = Duration.zero, finalAt = Duration.zero
    for await context in stream {
        let at = ContinuousClock.now - start
        if emissions.isEmpty { firstAt = at }
        finalAt = at
        emissions.append(context)
    }
    return Collected(emissions: emissions, firstAt: firstAt, finalAt: finalAt, final: emissions.last!)
}
