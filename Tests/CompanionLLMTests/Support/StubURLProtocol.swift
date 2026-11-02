@testable import CompanionLLM
import CompanionCore
import Foundation
import os

struct CapturedRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data
}

private struct HostState: Sendable {
    var status = 200
    var headers = ["Content-Type": "text/event-stream"]
    var chunks: [Data] = []
    var holdOpen = false
    var failure: URLError.Code?
    var requests: [CapturedRequest] = []
    var stopLoadingCount = 0
}

/// Per-host state lives in a static lock so that suites can run in parallel.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    fileprivate static let hosts = OSAllocatedUnfairLock<[String: HostState]>(initialState: [:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let host = url.host ?? ""
        let captured = CapturedRequest(method: request.httpMethod ?? "GET", url: url,
                                       headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request))
        let state: HostState? = Self.hosts.withLock { hosts in
            hosts[host]?.requests.append(captured)
            return hosts[host]
        }
        guard let state else {
            finish(status: 404, headers: [:], chunks: [], holdOpen: false, url: url)
            return
        }
        if let failure = state.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        finish(status: state.status, headers: state.headers, chunks: state.chunks, holdOpen: state.holdOpen, url: url)
    }

    override func stopLoading() {
        let host = request.url?.host ?? ""
        Self.hosts.withLock { $0[host]?.stopLoadingCount += 1 }
    }

    private func finish(status: Int, headers: [String: String], chunks: [Data], holdOpen: Bool, url: URL) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        if !holdOpen { client?.urlProtocolDidFinishLoading(self) }
    }

    /// URLSession moves request bodies into `httpBodyStream`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { return data }
            data.append(contentsOf: buffer[..<count])
        }
    }
}

final class StubServer: Sendable {
    let host: String
    let baseURL: URL
    let session: URLSession

    init() {
        host = "\(UUID().uuidString.lowercased()).stub.test"
        baseURL = URL(string: "https://\(host)")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        let host = host
        StubURLProtocol.hosts.withLock { $0[host] = HostState() }
    }

    func respond(status: Int = 200, headers: [String: String] = ["Content-Type": "text/event-stream"],
                 chunks: [Data] = [], holdOpen: Bool = false) {
        StubURLProtocol.hosts.withLock { hosts in
            hosts[host]?.status = status
            hosts[host]?.headers = headers
            hosts[host]?.chunks = chunks
            hosts[host]?.holdOpen = holdOpen
            hosts[host]?.failure = nil
        }
    }

    func fail(_ code: URLError.Code) {
        StubURLProtocol.hosts.withLock { $0[host]?.failure = code }
    }

    var requests: [CapturedRequest] {
        StubURLProtocol.hosts.withLock { $0[host]?.requests ?? [] }
    }

    var stopLoadingCount: Int {
        StubURLProtocol.hosts.withLock { $0[host]?.stopLoadingCount ?? 0 }
    }
}

func collect(_ s: AsyncThrowingStream<LLMStreamEvent, any Error>) async -> (events: [LLMStreamEvent], error: (any Error)?) {
    var events: [LLMStreamEvent] = []
    do {
        for try await event in s { events.append(event) }
        return (events, nil)
    } catch {
        return (events, error)
    }
}

func chunked(_ data: Data, size: Int) -> [Data] {
    stride(from: 0, to: data.count, by: size).map { start in
        Data(data[data.startIndex.advanced(by: start)..<data.startIndex.advanced(by: min(start + size, data.count))])
    }
}
