import CompanionCore
import Foundation

/// Maps one provider's SSE events to `LLMStreamEvent`s.
protocol StreamDecoding: Sendable {
    /// The transport stops reading once true.
    var isDone: Bool { get }
    mutating func decode(_ event: SSEEvent) throws -> [LLMStreamEvent]
    /// Called at EOF while `!isDone`.
    mutating func finish() throws -> [LLMStreamEvent]
}

struct SSETransport: Sendable {
    static let streamEndedEarly = "Stream ended before the response finished"
    private static let maxErrorBodyBytes = 65_536

    let session: URLSession

    func stream<D: StreamDecoding>(_ request: URLRequest, decoder: D,
                                   errorMessage: @escaping @Sendable (Data) -> String?) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, decoder: decoder, errorMessage: errorMessage) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Sends one `HEAD` to the origin of `url` if the gate allows it. The outcome is ignored.
    func prewarm(_ url: URL, gate: PrewarmGate) async {
        let origin = Self.origin(of: url)
        guard await gate.shouldPrewarm(host: origin.host ?? "") else { return }
        var request = URLRequest(url: origin)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        _ = try? await session.data(for: request)
    }

    /// `scheme://host[:port]/`
    static func origin(of url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        components.user = nil
        components.password = nil
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    static func fallbackMessage(body: Data, status: Int) -> String {
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : String(text.prefix(300))
    }

    private func run<D: StreamDecoding>(_ request: URLRequest, decoder initial: D,
                                        errorMessage: (Data) -> String?,
                                        yield: (LLMStreamEvent) -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw LLMError.network("Invalid response") }

        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= Self.maxErrorBodyBytes { break }
            }
            let message = errorMessage(body) ?? Self.fallbackMessage(body: body, status: http.statusCode)
            throw LLMError.http(status: http.statusCode, message: message)
        }

        var decoder = initial
        var parser = SSEParser()
        // Raw bytes, never `.lines`: that drops the blank lines which dispatch SSE events.
        for try await byte in bytes {
            for event in parser.feed(CollectionOfOne(byte)) {
                try decoder.decode(event).forEach(yield)
                if decoder.isDone { return }
            }
        }
        for event in parser.finish() {
            try decoder.decode(event).forEach(yield)
            if decoder.isDone { return }
        }
        try decoder.finish().forEach(yield)
    }

    /// nil means a cancellation, which finishes the stream without an error.
    private static func mapError(_ error: any Error) -> (any Error)? {
        switch error {
        case let error as LLMError: error
        case is CancellationError: nil
        case let error as URLError where error.code == .cancelled: nil
        default: LLMError.network(error.localizedDescription)
        }
    }
}

/// Allows at most one prewarm per interval per host.
actor PrewarmGate {
    private let interval: TimeInterval
    private let now: @Sendable () -> Date
    private var lastPrewarm: [String: Date] = [:]

    init(interval: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.interval = interval
        self.now = now
    }

    /// True at most once per interval per host; records the time.
    func shouldPrewarm(host: String) -> Bool {
        let current = now()
        if let last = lastPrewarm[host], current.timeIntervalSince(last) < interval { return false }
        lastPrewarm[host] = current
        return true
    }
}
