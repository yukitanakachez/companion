import CompanionCore
import Foundation

public final class FakeSecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    public init(_ initial: [String: String] = [:]) {
        values = initial
    }

    public func secret(for key: String) -> String? {
        lock.withLock { values[key] }
    }

    public func setSecret(_ value: String?, for key: String) throws {
        lock.withLock { values[key] = value }
    }
}

@MainActor public final class FakeSettingsStore: SettingsStoring {
    public private(set) var settings: AppSettings
    private var observers: [@MainActor (AppSettings) -> Void] = []

    public init(_ settings: AppSettings = .default) {
        self.settings = settings
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        for observer in observers { observer(settings) }
    }

    public func addObserver(_ onChange: @escaping @MainActor (AppSettings) -> Void) {
        observers.append(onChange)
    }
}

public final class FakeLLMProvider: LLMProvider, @unchecked Sendable {
    public let providerID: String
    private let events: [LLMStreamEvent]
    private let failure: (any Error)?
    private let delayPerEvent: Duration
    private let lock = NSLock()
    private var recordedRequests: [LLMRequest] = []
    private var recordedPrewarms = 0

    public init(providerID: String = "fake",
                events: [LLMStreamEvent] = [.textDelta("Hello"), .finished(stopReason: "end_turn")],
                failure: (any Error)? = nil, delayPerEvent: Duration = .zero) {
        self.providerID = providerID
        self.events = events
        self.failure = failure
        self.delayPerEvent = delayPerEvent
    }

    /// Every request received, in order.
    public var requests: [LLMRequest] { lock.withLock { recordedRequests } }
    public var prewarmCount: Int { lock.withLock { recordedPrewarms } }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        lock.withLock { recordedRequests.append(request) }
        let (events, failure, delay) = (events, failure, delayPerEvent)
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let failure {
                    continuation.finish(throwing: failure)
                    return
                }
                do {
                    for (index, event) in events.enumerated() {
                        if index > 0, delay > .zero { try await Task.sleep(for: delay) }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func prewarm() async {
        lock.withLock { recordedPrewarms += 1 }
    }
}

public actor FakeBrowserContextProvider: BrowserContextProviding {
    private var cached: TabContext?
    private let fresh: TabContext?
    private let freshDelay: Duration
    private let connected: Bool
    public private(set) var requestCount = 0

    public init(cached: TabContext? = nil, fresh: TabContext? = nil, freshDelay: Duration = .zero, connected: Bool = true) {
        self.cached = cached
        self.fresh = fresh
        self.freshDelay = freshDelay
        self.connected = connected
    }

    public func setCached(_ context: TabContext?) {
        cached = context
    }

    public func cachedActiveTabContext() async -> TabContext? {
        cached
    }

    /// Sleeps `freshDelay`, then returns `fresh` if that was within `timeout`, otherwise nil.
    public func requestActiveTabContext(timeout: Duration) async -> TabContext? {
        requestCount += 1
        try? await Task.sleep(for: freshDelay)
        return freshDelay < timeout ? fresh : nil
    }

    public func isConnected() async -> Bool {
        connected
    }
}

public actor FakeDocumentFetcher: DocumentFetching {
    private let files: [String: (data: Data, title: String)]
    private let failure: BridgeError?
    public private(set) var requestedFileIDs: [String] = []

    public init(files: [String: (data: Data, title: String)] = [:], failure: BridgeError? = nil) {
        self.files = files
        self.failure = failure
    }

    public func fetchDrivePDF(fileId: String) async throws -> (data: Data, title: String) {
        requestedFileIDs.append(fileId)
        if let failure { throw failure }
        guard let file = files[fileId] else {
            throw BridgeError(code: .notFound, message: "No fake file \(fileId)")
        }
        return file
    }
}

public actor FakeViewerDriver: ViewerDriving {
    private let info: ViewerInfo
    private let page: @Sendable (Int) -> ImageAttachment
    public private(set) var capturedIndices: [Int] = []
    public private(set) var restoredIndex: Int?

    public init(info: ViewerInfo, page: @escaping @Sendable (Int) -> ImageAttachment) {
        self.info = info
        self.page = page
    }

    public func viewerInfo(tabId: Int) async throws -> ViewerInfo {
        info
    }

    public func capturePage(tabId: Int, pageIndex: Int) async throws -> ImageAttachment {
        capturedIndices.append(pageIndex)
        return page(pageIndex)
    }

    public func restore(tabId: Int, pageIndex: Int) async throws {
        restoredIndex = pageIndex
    }
}
