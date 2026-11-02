@testable import CompanionLLM
import CompanionCore
import CompanionTestSupport
import Foundation
import Testing

private let weatherTool = LLMToolSpec(name: "get_weather", description: "Get weather",
                                      inputSchemaJSON: #"{"type":"object","properties":{"location":{"type":"string"}}}"#)

private func encode(system: String = "SYS", _ messages: [LLMMessage], tools: [LLMToolSpec] = []) throws -> URLRequest {
    try AnthropicRequestEncoder.urlRequest(for: LLMRequest(model: ModelCatalog.haiku45, system: system, messages: messages, tools: tools),
                                           apiKey: "sk-ant-test")
}

private func messages(of r: URLRequest) throws -> [JSONValue] {
    guard case .object(let body) = try bodyJSON(r), case .array(let messages)? = body["messages"] else { return [] }
    return messages
}

struct AnthropicRequestTests {
    @Test func endpointAndHeaders() throws {
        let r = try AnthropicRequestEncoder.urlRequest(for: LLMRequest(model: ModelCatalog.haiku45, system: "S", messages: [.init(role: .user, content: [.text("hi")])]), apiKey: "sk-ant-test")
        #expect(r.url?.absoluteString == "https://api.anthropic.com/v1/messages" && r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(r.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(r.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(r.value(forHTTPHeaderField: "accept") == "text/event-stream")
    }

    @Test func bodyForTextConversation() throws {
        let r = try encode([.init(role: .user, content: [.text("hi")]), .init(role: .assistant, content: [.text("hello")]), .init(role: .user, content: [.text("more")])])
        #expect(try bodyJSON(r) == json(#"{"model":"claude-haiku-4-5-20251001","max_tokens":4096,"system":"SYS","stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]},{"role":"assistant","content":[{"type":"text","text":"hello"}]},{"role":"user","content":[{"type":"text","text":"more"}]}]}"#))
    }

    @Test func emptySystemAndNoToolsAreOmitted() throws {
        let r = try encode(system: "", [.init(role: .user, content: [.text("hi")])])
        #expect(try bodyJSON(r) == json(#"{"model":"claude-haiku-4-5-20251001","max_tokens":4096,"stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}"#))
    }

    @Test func imageBlockIsBase64PNG() throws {
        let image = Fixtures.samplePNG()
        let r = try encode([.init(role: .user, content: [.image(image)])])
        #expect(try messages(of: r) == [json(#"{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(image.png.base64EncodedString())"}}]}"#)])
    }

    @Test func largeImageEncodesWithoutLineBreaks() throws {
        let png = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let r = try encode([.init(role: .user, content: [.image(ImageAttachment(png: png, pixelWidth: 1500, pixelHeight: 1000))])])
        guard case .object(let message)? = try messages(of: r).first, case .array(let content)? = message["content"],
              case .object(let block)? = content.first, case .object(let source)? = block["source"],
              case .string(let data)? = source["data"] else {
            Issue.record("no image data in the body")
            return
        }
        #expect(data == png.base64EncodedString())
        #expect(!data.contains("\n") && !data.contains("\r"))
        #expect(Data(base64Encoded: data) == png)
    }

    @Test func toolBlocksAndToolsEncoded() throws {
        let r = try encode([
            .init(role: .assistant, content: [.toolUse(id: "toolu_01A", name: "get_weather", inputJSON: #"{"location":"Paris"}"#)]),
            .init(role: .user, content: [.toolResult(toolUseID: "toolu_01A", content: "72°F", isError: false),
                                         .toolResult(toolUseID: "toolu_01B", content: "boom", isError: true)]),
        ], tools: [weatherTool])
        #expect(try bodyJSON(r) == json(#"{"model":"claude-haiku-4-5-20251001","max_tokens":4096,"system":"SYS","stream":true,"messages":[{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01A","name":"get_weather","input":{"location":"Paris"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01A","content":"72°F"},{"type":"tool_result","tool_use_id":"toolu_01B","content":"boom","is_error":true}]}],"tools":[{"name":"get_weather","description":"Get weather","input_schema":{"type":"object","properties":{"location":{"type":"string"}}}}]}"#))
    }

    @Test func invalidToolJSONThrowsDecoding() {
        #expect(throws: LLMError.decoding("Invalid tool JSON: get_weather")) {
            try encode([.init(role: .assistant, content: [.toolUse(id: "t", name: "get_weather", inputJSON: "{nope")])])
        }
    }
}
