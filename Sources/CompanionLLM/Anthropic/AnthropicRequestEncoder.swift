import CompanionCore
import Foundation

enum AnthropicRequestEncoder {
    static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    static let apiVersion = "2023-06-01"

    /// POST <baseURL>/v1/messages. Throws LLMError.decoding("Invalid tool JSON: <name>") for unparsable tool JSON.
    static func urlRequest(for request: LLMRequest, apiKey: String, baseURL: URL = defaultBaseURL) throws -> URLRequest {
        var body: [String: Any] = [
            "model": request.model.modelID,
            "max_tokens": request.maxTokens,
            "stream": true,
            "messages": try request.messages.map(encode),
        ]
        if !request.system.isEmpty { body["system"] = request.system }
        if !request.tools.isEmpty { body["tools"] = try request.tools.map(encode) }

        var urlRequest = URLRequest(url: baseURL.appending(path: "v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: .withoutEscapingSlashes)
        return urlRequest
    }

    private static func encode(_ message: LLMMessage) throws -> [String: Any] {
        ["role": message.role.rawValue, "content": try message.content.map(encode)]
    }

    private static func encode(_ content: LLMContent) throws -> [String: Any] {
        switch content {
        case .text(let text):
            return ["type": "text", "text": text]
        case .image(let image):
            return ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": image.png.base64EncodedString()]]
        case .toolUse(let id, let name, let inputJSON):
            return ["type": "tool_use", "id": id, "name": name, "input": try parseToolJSON(inputJSON, name: name)]
        case .toolResult(let toolUseID, let content, let isError):
            var block: [String: Any] = ["type": "tool_result", "tool_use_id": toolUseID, "content": content]
            if isError { block["is_error"] = true }
            return block
        }
    }

    private static func encode(_ tool: LLMToolSpec) throws -> [String: Any] {
        ["name": tool.name, "description": tool.description, "input_schema": try parseToolJSON(tool.inputSchemaJSON, name: tool.name)]
    }
}

/// Parses raw tool JSON for embedding in a request body.
func parseToolJSON(_ json: String, name: String) throws -> Any {
    do {
        return try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
    } catch {
        throw LLMError.decoding("Invalid tool JSON: \(name)")
    }
}
