import CompanionCore
import Foundation
import Testing
@testable import CompanionBridge

private let c1 = ConnectionID(raw: 1)
private let c2 = ConnectionID(raw: 2)

@Suite struct RequestMultiplexerTests {
    private struct Harness {
        let mux = RequestMultiplexer()
        let sent = AsyncStream.makeStream(of: BridgeRequest.self)

        func start(on connection: ConnectionID = c1, timeout: Duration = .seconds(10)) -> Task<RequestOutcome, any Error> {
            let continuation = sent.continuation
            return Task { [mux] in
                try await mux.perform(on: connection, timeout: timeout, { .viewerInfo(id: $0, tabId: 34) },
                                      send: { continuation.yield($0) })
            }
        }
        func nextSent() async -> BridgeRequest? {
            var iterator = sent.stream.makeAsyncIterator()
            return await iterator.next()
        }
    }

    private func okResponse(_ id: String, _ result: String = #"{"pageCount":412,"currentIndex":87}"#) throws -> BridgeResponse {
        guard case .response(let response) = try ext(#"{"v":1,"type":"response","id":"\#(id)","ok":true,"result":\#(result)}"#) else {
            throw BridgeError(code: .internal, message: "not a response")
        }
        return response
    }
    private func expectCode(_ task: Task<RequestOutcome, any Error>, _ code: BridgeErrorCode,
                            sourceLocation: SourceLocation = #_sourceLocation) async {
        await expectBridgeError(code, sourceLocation: sourceLocation) { _ = try await task.value }
    }

    @Test func idsAreSequentialAndResponseResolves() async throws {
        let h = Harness()
        let first = h.start()
        let request = try #require(await h.nextSent())
        #expect(request.id == "r-1" && request.method == "viewerInfo")
        await h.mux.handleResponse(try okResponse("r-1"), from: c1)
        let outcome = try await first.value
        #expect(try outcome.response.decodeResult(ViewerInfo.self) == ViewerInfo(pageCount: 412, currentIndex: 87))
        let second = h.start()
        #expect(await h.nextSent()?.id == "r-2")
        await h.mux.handleResponse(try okResponse("r-2"), from: c1)
        _ = try await second.value
    }
    @Test func errorPayloadIsThrown() async throws {
        let h = Harness()
        let task = h.start()
        _ = await h.nextSent()
        let message = "The owner has disabled downloads for this file."
        await h.mux.handleResponse(BridgeResponse(id: "r-1", ok: false, result: nil,
                                                  error: BridgeError(code: .downloadBlocked, message: message)), from: c1)
        do {
            _ = try await task.value
            Issue.record("expected throw")
        } catch {
            #expect(error as? BridgeError == BridgeError(code: .downloadBlocked, message: message))
        }
    }
    @Test func errorResponseWithoutPayloadIsInternal() async throws {
        let h = Harness()
        let task = h.start()
        _ = await h.nextSent()
        await h.mux.handleResponse(BridgeResponse(id: "r-1", ok: false, result: nil, error: nil), from: c1)
        await expectCode(task, .internal)
    }
    @Test func timeoutThrowsAndForgetsRequest() async throws {
        let h = Harness()
        let task = h.start(timeout: .milliseconds(100))
        _ = await h.nextSent()
        await expectCode(task, .timeout)
        #expect(await h.mux.pendingCount == 0)
        await h.mux.handleResponse(try okResponse("r-1"), from: c1)
        #expect(await h.mux.pendingCount == 0)
    }
    @Test func disconnectFailsOnlyThatConnectionsRequests() async throws {
        let h = Harness()
        let a = h.start(on: c1), b = h.start(on: c1), other = h.start(on: c2)
        var ids: [String] = []
        var iterator = h.sent.stream.makeAsyncIterator()
        for _ in 0..<3 { if let r = await iterator.next() { ids.append(r.id) } }
        let started = ContinuousClock.now
        await h.mux.connectionClosed(c1)
        await expectCode(a, .notConnected)
        await expectCode(b, .notConnected)
        #expect(ContinuousClock.now - started < .milliseconds(500))
        #expect(await h.mux.pendingCount == 1)
        for id in ids { await h.mux.handleResponse(try okResponse(id), from: c2) }
        _ = try await other.value
    }
    @Test func failAllFailsEveryConnection() async throws {
        let h = Harness()
        let a = h.start(on: c1), b = h.start(on: c2)
        var iterator = h.sent.stream.makeAsyncIterator()
        _ = await iterator.next(); _ = await iterator.next()
        await h.mux.failAll()
        await expectCode(a, .notConnected)
        await expectCode(b, .notConnected)
        #expect(await h.mux.pendingCount == 0)
    }
    @Test func responseFromAnotherConnectionIsIgnored() async throws {
        let h = Harness()
        let task = h.start(on: c1)
        _ = await h.nextSent()
        await h.mux.handleResponse(try okResponse("r-1"), from: c2)
        #expect(await h.mux.pendingCount == 1)
        await h.mux.handleResponse(try okResponse("r-1"), from: c1)
        _ = try await task.value
    }
    @Test func sendFailureThrowsNotConnected() async throws {
        let mux = RequestMultiplexer()
        await expectBridgeError(.notConnected) {
            _ = try await mux.perform(on: c1, timeout: .seconds(10), { .viewerInfo(id: $0, tabId: 34) },
                                      send: { _ in throw BridgeError(code: .notConnected, message: "gone") })
        }
        #expect(await mux.pendingCount == 0)
    }
    @Test func binaryFramesAreCollectedForTheRequest() async throws {
        let h = Harness()
        let task = h.start()
        _ = await h.nextSent()
        await h.mux.handleBinary(BinaryFrameHeader(id: "r-1", seq: 2, last: true), Data([5]), from: c1)
        await h.mux.handleBinary(BinaryFrameHeader(id: "r-1", seq: 0, last: false), Data([1, 2]), from: c1)
        await h.mux.handleBinary(BinaryFrameHeader(id: "r-1", seq: 1, last: false), Data([3, 4]), from: c1)
        await h.mux.handleResponse(try okResponse("r-1", "{}"), from: c1)
        #expect(try await task.value.chunks?.assemble() == Data([1, 2, 3, 4, 5]))
    }
    @Test func binaryFromAnotherConnectionIsIgnored() async throws {
        let h = Harness()
        let task = h.start()
        _ = await h.nextSent()
        await h.mux.handleBinary(BinaryFrameHeader(id: "r-1", seq: 0, last: true), Data([9]), from: c2)
        await h.mux.handleResponse(try okResponse("r-1", "{}"), from: c1)
        #expect(try await task.value.chunks == nil)
    }
    @Test func duplicateChunkFailsRequestImmediately() async throws {
        let h = Harness()
        let task = h.start()
        _ = await h.nextSent()
        await h.mux.handleBinary(BinaryFrameHeader(id: "r-1", seq: 0, last: false), Data([1]), from: c1)
        await h.mux.handleBinary(BinaryFrameHeader(id: "r-1", seq: 0, last: false), Data([1]), from: c1)
        await expectCode(task, .internal)
    }
}
