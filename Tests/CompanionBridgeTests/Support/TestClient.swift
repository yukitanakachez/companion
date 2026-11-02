import CompanionCore
import CompanionTestSupport
import Foundation
@testable import CompanionBridge

private actor Mailbox {
    private var messages: [AppToExtension] = []
    private(set) var closed = false
    private(set) var closeCode: Int?
    private(set) var opened = false

    func push(_ message: AppToExtension) { messages.append(message) }
    func popFirst() -> AppToExtension? { messages.isEmpty ? nil : messages.removeFirst() }
    func markOpened() { opened = true }
    func markClosed(code: Int?) {
        if let code, closeCode == nil { closeCode = code }
        closed = true
    }
}

private final class Delegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    let mailbox = Mailbox()

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { [mailbox] in await mailbox.markOpened() }
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { [mailbox] in await mailbox.markClosed(code: closeCode.rawValue) }
    }
}

/// A real WebSocket client over loopback. One background loop pumps `receive()` into a mailbox,
/// so a timed-out `next` never swallows a later message.
final class TestClient: Sendable {
    private let mailbox: Mailbox
    private let task: URLSessionWebSocketTask
    private let session: URLSession

    private init(port: UInt16) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let delegate = Delegate()
        mailbox = delegate.mailbox
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.maximumMessageSize = 16_777_216
    }

    static func connect(port: UInt16) async throws -> TestClient {
        let client = TestClient(port: port)
        client.task.resume()
        client.startPump()
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await client.mailbox.opened { return client }
            if await client.mailbox.closed { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw BridgeError(code: .notConnected, message: "TestClient couldn't open port \(port)")
    }

    private func startPump() {
        Task { [task, mailbox] in
            while true {
                do {
                    let message = try await task.receive()
                    if case .string(let text) = message,
                       let decoded = try? JSONDecoder().decode(AppToExtension.self, from: Data(text.utf8)) {
                        await mailbox.push(decoded)
                    }
                } catch {
                    let raw = task.closeCode.rawValue
                    await mailbox.markClosed(code: raw == 0 ? nil : raw)
                    return
                }
            }
        }
    }

    func send(text: String) async throws { try await task.send(.string(text)) }
    func send(fixture name: String) async throws {
        try await send(text: String(decoding: try Fixtures.bridgeFixture(name), as: UTF8.self))
    }
    func send(binary: Data) async throws { try await task.send(.data(binary)) }
    func hello(token: String, browserName: String = "Dia") async throws {
        try await send(text: try jsonString(ExtensionToApp.hello(HelloMessage(token: token, extensionVersion: "1.0", browserName: browserName))))
    }

    /// nil at the deadline or after close.
    func next(timeout: Duration = .seconds(2)) async -> AppToExtension? {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let message = await mailbox.popFirst() { return message }
            if await mailbox.closed || ContinuousClock.now >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The server's close code; nil if still open at the deadline.
    func closeCode(timeout: Duration = .seconds(2)) async -> Int? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await mailbox.closed { return await mailbox.closeCode }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    /// True when the server answers a WebSocket ping with a pong within 2 s.
    func ping() async -> Bool {
        let answered = AsyncStream<Bool>.makeStream()
        task.sendPing { error in
            answered.continuation.yield(error == nil)
            answered.continuation.finish()
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            answered.continuation.yield(false)
            answered.continuation.finish()
        }
        return await answered.stream.first { _ in true } ?? false
    }

    func isClosed(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await mailbox.closed { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func disconnect() {
        task.cancel(with: .goingAway, reason: nil)
        session.finishTasksAndInvalidate()
    }
}
