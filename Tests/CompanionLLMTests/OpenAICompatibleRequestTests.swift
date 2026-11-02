@testable import CompanionLLM
import CompanionCore
import CompanionTestSupport
import Foundation
import Testing

private let gptTest = ModelRef(providerID: "openai-compatible", modelID: "gpt-test", displayName: "GPT")
private let weatherTool = LLMToolSpec(name: "get_weather", description: "Get weather",
                                      inputSchemaJSON: #"{"type":"object","properties":{"location":{"type":"string"}}}"#)

private func encode(base: String = "https://openrouter.ai/api/v1", system: String = "", _ messages: [LLMMessage], tools: [LLMToolSpec] = []) throws -> URLRequest {
    try OpenAICompatibleRequestEncoder.urlRequest(for: LLMRequest(model: gptTest, system: system, messages: messages, tools: tools),
                                                  apiKey: "sk-test", baseURL: URL(string: base)!)
}

private let hi = [LLMMessage(role: .user, content: [.text("hi")])]

struct OpenAICompatibleRequestTests {
    @Test(arguments: ["https://api.openai.com/v1", "https://api.openai.com/v1/"])
    func endpointJoinsBaseURL(_ base: String) throws {
        let r = try encode(base: base, hi)
        #expect(r.url?.absoluteString == "https://api.openai.com/v1/chat/completions" && r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(r.value(forHTTPHeaderField: "accept") == "text/event-stream")
        #expect(r.value(forHTTPHeaderField: "content-type") == "application/json")
    }

    @Test func localServerEndpoint() throws {
        #expect(try encode(base: "http://localhost:11434/v1", hi).url?.absoluteString == "http://localhost:11434/v1/chat/completions")
    }

    @Test func bodyShape() throws {
        let img = Fixtures.samplePNG()
        let r = try encode(system: "SYS", [.init(role: .user, content: [.image(img), .text("q")]), .init(role: .assistant, content: [.text("a1")])], tools: [weatherTool])
        #expect(try bodyJSON(r) == json(#"{"model":"gpt-test","stream":true,"max_tokens":4096,"messages":[{"role":"system","content":"SYS"},{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,\#(img.png.base64EncodedString())"}},{"type":"text","text":"q"}]},{"role":"assistant","content":"a1"}],"tools":[{"type":"function","function":{"name":"get_weather","description":"Get weather","parameters":{"type":"object","properties":{"location":{"type":"string"}}}}}]}"#))
    }

    @Test func openAIHostUsesMaxCompletionTokens() throws {
        #expect(try bodyJSON(encode(base: "https://api.openai.com/v1", hi)) == json(#"{"model":"gpt-test","stream":true,"max_completion_tokens":4096,"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}"#))
    }

    @Test func emptySystemOmitted() throws {
        #expect(try bodyJSON(encode(hi)) == json(#"{"model":"gpt-test","stream":true,"max_tokens":4096,"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}"#))
    }

    @Test func toolHistoryEncoding() throws {
        let r = try encode([
            .init(role: .assistant, content: [.toolUse(id: "call_1", name: "get_weather", inputJSON: #"{"location":"Paris"}"#)]),
            .init(role: .user, content: [.toolResult(toolUseID: "call_1", content: "72°F", isError: false)]),
        ])
        #expect(try bodyJSON(r) == json(#"{"model":"gpt-test","stream":true,"max_tokens":4096,"messages":[{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"location\":\"Paris\"}"}}]},{"role":"tool","tool_call_id":"call_1","content":"72°F"}]}"#))
    }

    @Test func invalidToolSchemaThrowsDecoding() {
        #expect(throws: LLMError.decoding("Invalid tool JSON: bad")) {
            try encode(hi, tools: [LLMToolSpec(name: "bad", description: "", inputSchemaJSON: "{nope")])
        }
    }
}
