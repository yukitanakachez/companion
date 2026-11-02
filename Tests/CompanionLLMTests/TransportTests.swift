@testable import CompanionLLM
import CompanionCore
import Foundation
import os
import Testing

private struct EchoDecoder: StreamDecoding {
    var isDone = false
    mutating func decode(_ event: SSEEvent) throws -> [LLMStreamEvent] {
        if event.data == "end" {
            isDone = true
            return [.finished(stopReason: "end")]
        }
        return [.textDelta(event.data)]
    }
    mutating func finish() throws -> [LLMStreamEvent] {
        throw LLMError.network(SSETransport.streamEndedEarly)
    }
}

private func run(_ s: StubServer, errorMessage: @escaping @Sendable (Data) -> String? = { _ in nil }) async -> (events: [LLMStreamEvent], error: (any Error)?) {
    await collect(SSETransport(session: s.session).stream(URLRequest(url: s.baseURL), decoder: EchoDecoder(), errorMessage: errorMessage))
}

struct TransportTests {
    @Test func makeSessionConfiguration() {
        let c = ProviderRegistry.makeSession().configuration
        #expect(c.httpMaximumConnectionsPerHost == 4 && c.timeoutIntervalForRequest == 60 && c.waitsForConnectivity == false)
    }

    @Test func streamsDecodedEventsAcrossChunks() async {
        let s = StubServer()
        s.respond(chunks: chunked(Data("data: a\n\ndata: b\n\ndata: end\n\n".utf8), size: 3))
        let r = await run(s)
        #expect(r.events == [.textDelta("a"), .textDelta("b"), .finished(stopReason: "end")] && r.error == nil)
    }

    @Test func eofBeforeDoneSurfacesDecoderFinish() async {
        let s = StubServer()
        s.respond(chunks: [Data("data: a\n\n".utf8)])
        let r = await run(s)
        #expect(r.events == [.textDelta("a")])
        #expect(r.error as? LLMError == .network(SSETransport.streamEndedEarly))
    }

    @Test func non2xxUsesParsedMessage() async {
        let s = StubServer()
        s.respond(status: 401, chunks: [Data(#"{"m":"bad key"}"#.utf8)])
        let r = await run(s, errorMessage: { body in
            (try? JSONSerialization.jsonObject(with: body) as? [String: String])?["m"]
        })
        #expect(r.events == [])
        #expect(r.error as? LLMError == .http(status: 401, message: "bad key"))
    }

    @Test func non2xxFallsBackToBodyThenStatusText() async {
        let html = StubServer()
        html.respond(status: 502, chunks: [Data("<html>Bad Gateway</html>".utf8)])
        #expect(await run(html).error as? LLMError == .http(status: 502, message: "<html>Bad Gateway</html>"))

        let empty = StubServer()
        empty.respond(status: 503)
        #expect(await run(empty).error as? LLMError == .http(status: 503, message: HTTPURLResponse.localizedString(forStatusCode: 503)))
    }

    @Test func transportFailureMapsToNetwork() async {
        let s = StubServer()
        s.fail(.notConnectedToInternet)
        let error = await run(s).error as? LLMError
        guard case .network = error else {
            Issue.record("expected .network, got \(String(describing: error))")
            return
        }
    }

    @Test func cancellingConsumerCancelsURLSessionTask() async throws {
        let s = StubServer()
        s.respond(chunks: [Data("data: a\n\n".utf8)], holdOpen: true)
        let first = OSAllocatedUnfairLock<LLMStreamEvent?>(initialState: nil)
        let consumer = Task {
            let stream = SSETransport(session: s.session).stream(URLRequest(url: s.baseURL), decoder: EchoDecoder(), errorMessage: { _ in nil })
            for try await event in stream { first.withLock { $0 = event } }
        }
        try await poll { first.withLock { $0 } != nil }
        #expect(first.withLock { $0 } == .textDelta("a"))
        consumer.cancel()
        try await poll { s.stopLoadingCount > 0 }
        #expect(s.stopLoadingCount == 1)
    }

    @Test func prewarmSendsOneHEADPerHostPerInterval() async {
        let s = StubServer()
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000))
        let gate = PrewarmGate(now: { clock.withLock { $0 } })
        let transport = SSETransport(session: s.session)
        let url = s.baseURL.appending(path: "v1/messages")

        await transport.prewarm(url, gate: gate)
        await transport.prewarm(url, gate: gate)
        #expect(s.requests.count == 1)
        #expect(s.requests.first?.method == "HEAD")
        #expect(s.requests.first?.url.absoluteString == "https://\(s.host)/")

        clock.withLock { $0 = $0.addingTimeInterval(61) }
        await transport.prewarm(url, gate: gate)
        #expect(s.requests.count == 2)
    }

    @Test func originDropsPathAndQuery() {
        #expect(SSETransport.origin(of: URL(string: "http://localhost:11434/v1?x=1")!).absoluteString == "http://localhost:11434/")
        #expect(SSETransport.origin(of: URL(string: "https://api.anthropic.com/v1/messages")!).absoluteString == "https://api.anthropic.com/")
    }

    private func poll(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }
}
