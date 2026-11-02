import CompanionCore
import Foundation

struct OpenAICompatibleStreamDecoder: StreamDecoding {
    private struct PendingCall: Sendable {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private(set) var isDone = false
    private var calls: [Int: PendingCall] = [:]
    private var finishReason: String?

    init() {}

    /// `error.message` of `{"error":{"message":…}}`.
    static func errorMessage(from body: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        return (object?["error"] as? [String: Any])?["message"] as? String
    }

    mutating func decode(_ event: SSEEvent) throws -> [LLMStreamEvent] {
        if event.data.trimmingCharacters(in: .whitespaces) == "[DONE]" { return complete() }

        let object = try Self.parse(event)
        if let error = object["error"], !(error is NSNull) {
            let details = error as? [String: Any]
            throw LLMError.http(status: details?["code"] as? Int ?? 500,
                                message: details?["message"] as? String ?? error as? String ?? "Unknown error")
        }
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return [] }

        var events: [LLMStreamEvent] = []
        let delta = choice["delta"] as? [String: Any]
        if let text = delta?["content"] as? String, !text.isEmpty { events.append(.textDelta(text)) }
        for call in delta?["tool_calls"] as? [[String: Any]] ?? [] {
            let index = call["index"] as? Int ?? 0
            let function = call["function"] as? [String: Any]
            var pending = calls[index] ?? PendingCall()
            if let id = call["id"] as? String { pending.id = id }
            if let name = function?["name"] as? String { pending.name = name }
            pending.arguments += function?["arguments"] as? String ?? ""
            calls[index] = pending
        }
        if let reason = choice["finish_reason"] as? String {
            finishReason = reason
            events += drainCalls()
        }
        return events
    }

    mutating func finish() throws -> [LLMStreamEvent] {
        guard finishReason != nil else { throw LLMError.network(SSETransport.streamEndedEarly) }
        return complete()
    }

    private mutating func complete() -> [LLMStreamEvent] {
        isDone = true
        return drainCalls() + [.finished(stopReason: finishReason)]
    }

    private mutating func drainCalls() -> [LLMStreamEvent] {
        defer { calls.removeAll() }
        return calls.sorted { $0.key < $1.key }.map { _, call in
            .toolUse(id: call.id, name: call.name, inputJSON: call.arguments.isEmpty ? "{}" : call.arguments)
        }
    }

    private static func parse(_ event: SSEEvent) throws -> [String: Any] {
        let name = event.event ?? "message"
        do {
            guard let object = try JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else {
                throw LLMError.decoding("\(name): expected a JSON object")
            }
            return object
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.decoding("\(name): \(error.localizedDescription)")
        }
    }
}
