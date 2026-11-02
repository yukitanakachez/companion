import CompanionCore
import Foundation

struct AnthropicStreamDecoder: StreamDecoding {
    private struct PendingTool: Sendable {
        var id: String
        var name: String
        var json = ""
    }

    private(set) var isDone = false
    private var tools: [Int: PendingTool] = [:]
    private var stopReason: String?

    init() {}

    static func status(forErrorType type: String) -> Int {
        switch type {
        case "invalid_request_error": 400
        case "authentication_error": 401
        case "billing_error": 402
        case "permission_error": 403
        case "not_found_error": 404
        case "request_too_large": 413
        case "rate_limit_error": 429
        case "api_error": 500
        case "overloaded_error": 529
        default: 500
        }
    }

    /// `error.message` of `{"type":"error","error":{…}}`.
    static func errorMessage(from body: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        return (object?["error"] as? [String: Any])?["message"] as? String
    }

    mutating func decode(_ event: SSEEvent) throws -> [LLMStreamEvent] {
        let object = try Self.parse(event)
        let index = object["index"] as? Int ?? 0
        switch object["type"] as? String {
        case "content_block_start":
            if let block = object["content_block"] as? [String: Any], block["type"] as? String == "tool_use" {
                tools[index] = PendingTool(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "")
            }
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta":
                if let text = delta["text"] as? String, !text.isEmpty { return [.textDelta(text)] }
            case "input_json_delta":
                tools[index]?.json += delta["partial_json"] as? String ?? ""
            default:
                break
            }
        case "content_block_stop":
            if let tool = tools.removeValue(forKey: index) {
                return [.toolUse(id: tool.id, name: tool.name, inputJSON: tool.json.isEmpty ? "{}" : tool.json)]
            }
        case "message_delta":
            if let reason = (object["delta"] as? [String: Any])?["stop_reason"] as? String { stopReason = reason }
        case "message_stop":
            isDone = true
            return [.finished(stopReason: stopReason)]
        case "error":
            let error = object["error"] as? [String: Any]
            throw LLMError.http(status: Self.status(forErrorType: error?["type"] as? String ?? ""),
                                message: error?["message"] as? String ?? "Unknown error")
        default:
            break   // message_start, ping and anything new
        }
        return []
    }

    func finish() throws -> [LLMStreamEvent] {
        throw LLMError.network(SSETransport.streamEndedEarly)
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
