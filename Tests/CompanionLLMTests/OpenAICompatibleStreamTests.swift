@testable import CompanionLLM
import CompanionCore
import Foundation
import Testing

private let textEvents: [LLMStreamEvent] = [.textDelta("The roots"), .textDelta(" are 2 and 3."), .finished(stopReason: "stop")]
private let gptTest = ModelRef(providerID: "openai-compatible", modelID: "gpt-test", displayName: "GPT")
private let hello = LLMRequest(model: gptTest, system: "", messages: [.init(role: .user, content: [.text("hi")])])

private func data(_ text: String) -> SSEEvent { SSEEvent(event: nil, data: text) }

struct OpenAICompatibleStreamTests {
    @Test func decodesTextStream() throws {
        #expect(try decodeAll("openai-text.sse", with: OpenAICompatibleStreamDecoder()).events == textEvents)
    }
    @Test func accumulatesToolCallsByIndex() throws {
        #expect(try decodeAll("openai-tool-calls.sse", with: OpenAICompatibleStreamDecoder()).events == [
            .toolUse(id: "call_1", name: "get_weather", inputJSON: #"{"location":"Paris"}"#),
            .toolUse(id: "call_2", name: "get_time", inputJSON: #"{"tz":"CET"}"#),
            .finished(stopReason: "tool_calls")])
    }
    @Test func toleratesEmptyChoicesAndNullContent() throws {
        var d = OpenAICompatibleStreamDecoder()
        #expect(try d.decode(data(#"{"choices":[]}"#)) == [])
        #expect(try d.decode(data(#"{"choices":[{"index":0,"delta":{"content":null},"finish_reason":null}]}"#)) == [])
    }
    @Test func missingDoneAfterFinishReasonStillFinishes() throws {
        var d = OpenAICompatibleStreamDecoder()
        #expect(try d.decode(data(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#)) == [])
        #expect(try d.finish() == [.finished(stopReason: "stop")])
    }
    @Test func eofWithoutFinishThrows() {
        var d = OpenAICompatibleStreamDecoder()
        #expect(throws: LLMError.network("Stream ended before the response finished")) { try d.finish() }
    }
    @Test func inStreamErrorObjectThrows() {
        var d = OpenAICompatibleStreamDecoder()
        #expect(throws: LLMError.http(status: 502, message: "Upstream error")) {
            try d.decode(data(#"{"error":{"message":"Upstream error","code":502}}"#))
        }
        #expect(throws: LLMError.http(status: 500, message: "Slow down")) {
            try d.decode(data(#"{"error":{"message":"Slow down","code":"rate_limit"}}"#))
        }
    }
    @Test func http401UsesErrorMessage() async throws {
        let s = StubServer()
        s.respond(status: 401, headers: ["Content-Type": "application/json"], chunks: [try LLMFixture.data("openai-error-401.json")])
        let r = await collect(OpenAICompatibleAdapter(apiKey: "sk-test", baseURL: s.baseURL, session: s.session).stream(hello))
        #expect(r.events == [])
        #expect(r.error as? LLMError == .http(status: 401, message: "Incorrect API key provided: sk-test."))
    }
    @Test func adapterStreamsOverHTTP() async throws {
        let s = StubServer()
        s.respond(chunks: chunked(try LLMFixture.data("openai-text.sse"), size: 5))
        let r = await collect(OpenAICompatibleAdapter(apiKey: "sk-test", baseURL: s.baseURL, session: s.session).stream(hello))
        #expect(r.events == textEvents && r.error == nil)
    }
}
