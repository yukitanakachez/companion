import CompanionCore
import Foundation
@testable import CompanionBridge

/// Plays the extension's side of the protocol over a real socket.
final class ScriptedExtension: Sendable {
    private let client: TestClient

    private init(client: TestClient) { self.client = client }

    /// Sends `hello`; requires `helloAck` then `config`.
    static func connect(port: UInt16, token: String, browserName: String = "Dia") async throws -> ScriptedExtension {
        let client = try await TestClient.connect(port: port)
        try await client.hello(token: token, browserName: browserName)
        guard case .helloAck = await client.next(), case .config = await client.next() else {
            throw BridgeError(code: .unauthorized, message: "Handshake failed")
        }
        return ScriptedExtension(client: client)
    }

    func push(fixture name: String) async throws { try await client.send(fixture: name) }
    func push(_ message: ExtensionToApp) async throws { try await client.send(text: try jsonString(message)) }

    /// Skips `ping` and `config`.
    func nextRequest(timeout: Duration = .seconds(2)) async -> BridgeRequest? {
        let deadline = ContinuousClock.now + timeout
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero, let message = await client.next(timeout: remaining) else { return nil }
            if case .request(let request) = message { return request }
        }
    }

    func respond(id: String, resultJSON: String) async throws {
        try await client.send(text: #"{"v":1,"type":"response","id":"\#(id)","ok":true,"result":\#(resultJSON)}"#)
    }

    func respondError(id: String, code: String, message: String) async throws {
        try await client.send(text: #"{"v":1,"type":"response","id":"\#(id)","ok":false,"error":{"code":"\#(code)","message":"\#(message)"}}"#)
    }

    /// 1 MiB slices via `BinaryFrame.encode`; `order` = the slice indices to send, in that order.
    func sendChunks(id: String, data: Data, order: [Int]? = nil) async throws {
        let size = BridgeConstants.maxChunkBytes
        let starts = Array(stride(from: 0, to: data.count, by: size))
        for index in order ?? Array(starts.indices) {
            let start = data.startIndex + starts[index]
            let payload = Data(data[start..<min(start + size, data.endIndex)])
            let header = BinaryFrameHeader(id: id, seq: index, last: index == starts.count - 1)
            try await client.send(binary: try BinaryFrame.encode(header: header, payload: payload))
        }
    }

    func disconnect() { client.disconnect() }
}
