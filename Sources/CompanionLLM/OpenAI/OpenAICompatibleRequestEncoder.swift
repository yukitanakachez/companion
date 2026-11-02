import CompanionCore
import Foundation

enum OpenAICompatibleRequestEncoder {
    static func urlRequest(for request: LLMRequest, apiKey: String, baseURL: URL) throws -> URLRequest {
        var messages: [[String: Any]] = []
        if !request.system.isEmpty { messages.append(["role": "system", "content": request.system]) }
        for message in request.messages {
            switch message.role {
            case .user: messages += encodeUser(message)
            case .assistant: messages.append(encodeAssistant(message))
            }
        }

        // Current OpenAI models reject `max_tokens`.
        let tokenLimitKey = baseURL.host == "api.openai.com" ? "max_completion_tokens" : "max_tokens"
        var body: [String: Any] = [
            "model": request.model.modelID,
            "stream": true,
            "messages": messages,
            tokenLimitKey: request.maxTokens,
        ]
        if !request.tools.isEmpty { body["tools"] = try request.tools.map(encode) }

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: .withoutEscapingSlashes)
        return urlRequest
    }

    /// Each tool result becomes its own `tool` message; the remaining blocks form one `user` message.
    private static func encodeUser(_ message: LLMMessage) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        var parts: [[String: Any]] = []
        for block in message.content {
            switch block {
            case .toolResult(let id, let content, _):
                messages.append(["role": "tool", "tool_call_id": id, "content": content])
            case .text(let text):
                parts.append(["type": "text", "text": text])
            case .image(let image):
                parts.append(["type": "image_url", "image_url": ["url": "data:image/png;base64,\(image.png.base64EncodedString())"]])
            case .toolUse:
                break
            }
        }
        if !parts.isEmpty { messages.append(["role": "user", "content": parts]) }
        return messages
    }

    private static func encodeAssistant(_ message: LLMMessage) -> [String: Any] {
        var text: [String] = []
        var toolCalls: [[String: Any]] = []
        for block in message.content {
            switch block {
            case .text(let value):
                text.append(value)
            case .toolUse(let id, let name, let inputJSON):
                toolCalls.append(["id": id, "type": "function", "function": ["name": name, "arguments": inputJSON]])
            case .image, .toolResult:
                break
            }
        }
        var encoded: [String: Any] = ["role": "assistant"]
        encoded["content"] = text.isEmpty && !toolCalls.isEmpty ? NSNull() : text.joined()
        if !toolCalls.isEmpty { encoded["tool_calls"] = toolCalls }
        return encoded
    }

    private static func encode(_ tool: LLMToolSpec) throws -> [String: Any] {
        ["type": "function",
         "function": ["name": tool.name, "description": tool.description, "parameters": try parseToolJSON(tool.inputSchemaJSON, name: tool.name)]]
    }
}
