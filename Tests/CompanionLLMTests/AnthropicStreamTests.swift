@testable import CompanionLLM
import CompanionCore
import Testing

private func decodeAll(_ fixture: String) throws -> (events: [LLMStreamEvent], error: (any Error)?) {
    try CompanionLLMTests.decodeAll(fixture, with: AnthropicStreamDecoder())
}

struct AnthropicStreamTests {
    @Test func decodesTextStream() throws {
        #expect(try decodeAll("anthropic-text.sse").events == [.textDelta("The roots are "), .textDelta("$x=2$ and $x=3$."), .finished(stopReason: "end_turn")])
    }
    @Test func ignoresThinkingBlocksAndPings() throws {
        let r = try decodeAll("anthropic-thinking-text.sse")
        #expect(r.events == [.textDelta("Here is a hint."), .finished(stopReason: "end_turn")] && r.error == nil)
    }
    @Test func accumulatesToolUseJSON() throws {
        #expect(try decodeAll("anthropic-tool-use.sse").events == [.textDelta("Let me check."),
            .toolUse(id: "toolu_01A", name: "get_weather", inputJSON: #"{"location": "Paris"}"#), .finished(stopReason: "tool_use")])
    }
    @Test func toolUseWithoutInputGetsEmptyObject() throws {
        var d = AnthropicStreamDecoder()
        _ = try d.decode(SSEEvent(event: "content_block_start", data: #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"n","input":{}}}"#))
        #expect(try d.decode(SSEEvent(event: "content_block_stop", data: #"{"type":"content_block_stop","index":0}"#)) == [.toolUse(id: "t", name: "n", inputJSON: "{}")])
    }
    @Test func ignoresUnknownEventAndBlockTypes() throws {
        var d = AnthropicStreamDecoder()
        #expect(try d.decode(SSEEvent(event: "content_block_start", data: #"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"x","name":"web_search","input":{}}}"#)) == [])
        #expect(try d.decode(SSEEvent(event: "brand_new", data: #"{"type":"brand_new"}"#)) == [])
    }
    @Test func overloadedMidStreamKeepsPartialTextThenThrows() throws {
        let r = try decodeAll("anthropic-overloaded-midstream.sse")
        #expect(r.events == [.textDelta("The roots")])
        #expect(r.error as? LLMError == .http(status: 529, message: "Overloaded"))
    }
    @Test(arguments: [("invalid_request_error", 400), ("authentication_error", 401), ("billing_error", 402), ("permission_error", 403),
                      ("not_found_error", 404), ("request_too_large", 413), ("rate_limit_error", 429), ("api_error", 500),
                      ("overloaded_error", 529), ("something_new", 500)])
    func errorTypeStatus(_ type: String, _ status: Int) {
        #expect(AnthropicStreamDecoder.status(forErrorType: type) == status)
    }
    @Test func malformedJSONThrowsDecoding() {
        var d = AnthropicStreamDecoder()
        do {
            _ = try d.decode(SSEEvent(event: "content_block_delta", data: "{not json"))
            Issue.record("expected a throw")
        } catch LLMError.decoding(let m) {
            #expect(m.hasPrefix("content_block_delta: "))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
    @Test func eofBeforeMessageStopThrows() {
        var d = AnthropicStreamDecoder()
        #expect(throws: LLMError.network("Stream ended before the response finished")) { try d.finish() }
    }
}
