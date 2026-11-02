@testable import CompanionLLM
import CompanionCore
import Testing

private func adapter(_ s: StubServer) -> AnthropicAdapter {
    AnthropicAdapter(apiKey: "sk-ant-test", session: s.session, baseURL: s.baseURL)
}
private let hello = LLMRequest(model: ModelCatalog.haiku45, system: "", messages: [.init(role: .user, content: [.text("hi")])])

struct AnthropicAdapterTests {
    @Test func adapterStreamsFixtureInSmallChunks() async throws {
        let s = StubServer()
        s.respond(chunks: chunked(try LLMFixture.data("anthropic-text.sse"), size: 7))
        let r = await collect(adapter(s).stream(hello))
        #expect(r.events == [.textDelta("The roots are "), .textDelta("$x=2$ and $x=3$."), .finished(stopReason: "end_turn")] && r.error == nil)
        let request = try #require(s.requests.first)
        #expect(request.method == "POST" && request.url.path == "/v1/messages" && request.headers["x-api-key"] == "sk-ant-test")
    }

    @Test(arguments: [(401, "anthropic-error-401.json", "invalid x-api-key"),
                      (429, "anthropic-error-429.json", "Number of request tokens has exceeded your per-minute rate limit"),
                      (529, "anthropic-error-529.json", "Overloaded")])
    func httpStatusErrorsUseAPIMessage(_ status: Int, _ file: String, _ message: String) async throws {
        let s = StubServer()
        s.respond(status: status, headers: ["Content-Type": "application/json"], chunks: [try LLMFixture.data(file)])
        let r = await collect(adapter(s).stream(hello))
        #expect(r.events == [])
        #expect(r.error as? LLMError == .http(status: status, message: message))
    }

    @Test func encodingFailureSurfacesThroughStream() async {
        let s = StubServer()
        let request = LLMRequest(model: ModelCatalog.haiku45, system: "", messages: [
            .init(role: .assistant, content: [.toolUse(id: "t", name: "get_weather", inputJSON: "{nope")])])
        let r = await collect(adapter(s).stream(request))
        #expect(r.error as? LLMError == .decoding("Invalid tool JSON: get_weather"))
        #expect(s.requests.isEmpty)
    }

    @Test func prewarmSendsHEADToOrigin() async {
        let s = StubServer()
        await adapter(s).prewarm()
        #expect(s.requests.count == 1)
        #expect(s.requests.first?.method == "HEAD" && s.requests.first?.url.absoluteString == "https://\(s.host)/")
    }
}
