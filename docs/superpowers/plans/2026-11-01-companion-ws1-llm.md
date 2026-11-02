# WS1 — LLM Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read `2026-11-01-companion-00-overview.md` (rules, global constraints, cross-workstream APIs) and `2026-11-01-companion-ws0-foundation.md` (frozen `CompanionCore` contracts and `CompanionTestSupport` fakes) first.

**Goal:** The provider-agnostic model layer: streaming Anthropic Messages and OpenAI-compatible chat-completions adapters behind `LLMProvider`, a `ProviderRegistry` with Keychain-backed keys and connection prewarm, the per-context `ModelRouter`, and the `PromptBuilder` that turns question + captured context + history into a request.

**Architecture:** One byte-level SSE parser and one `URLSession` streaming transport (`SSETransport`) feed provider-specific pure decoders that map wire events to `LLMStreamEvent`; request encoders are pure functions tested on their JSON. `ProviderRegistry` reads keys from `SecretStoring` on every call and hands out adapters that share one `URLSession` and one prewarm throttle. `PromptBuilder` and `ModelRouter` are pure value types.

**Tech Stack:** Swift 6.4 (language mode 6), Foundation `URLSession.bytes(for:)`, Security (`SecItem*`), `os.OSAllocatedUnfairLock` (tests), Swift Testing. Consumes `CompanionCore` and `CompanionTestSupport` (WS0). No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-01-screen-companion-design.md` — §2 speed budgets, §5.1 step 2 (prewarm), §5.4 model layer, §7 error handling, §8 testing.

## Global Constraints

All of the overview's Global Constraints apply. This workstream additionally relies on these exact values:

- Owned paths only: `Sources/CompanionLLM/`, `Tests/CompanionLLMTests/` (incl. `Fixtures/`). Task 1 deletes `Sources/CompanionLLM/CompanionLLM.swift` and `Tests/CompanionLLMTests/PlaceholderTests.swift`; keep `Fixtures/README.md`.
- Consume `CompanionCore` verbatim (`LLMProvider`, `LLMRequest`, `LLMMessage`, `LLMContent`, `LLMToolSpec`, `LLMStreamEvent`, `LLMError`, `ModelRef`, `ModelCatalog`, `RoutingDefaults`, `ContextKind`, `CapturedContext`, `ContextItem`, `ContextPiece`, `ImageAttachment`, `SecretStoring`, `SecretKey`, `JSONValue`, `formatTimestamp`). Never redeclare; if a contract can't express something, stop and tell the human.
- Models come only from `ModelCatalog`: fast `claude-haiku-4-5-20251001` (Haiku 4.5), strong `claude-sonnet-5-5` (Sonnet 5.5). No model-ID literals in `Sources/`.
- Anthropic: `POST https://api.anthropic.com/v1/messages`; headers `x-api-key: <key>`, `anthropic-version: 2023-06-01`, `content-type: application/json`, `accept: text/event-stream`. Body keys only `model`, `max_tokens`, `system` (omitted when empty), `stream: true`, `messages`, `tools` (omitted when empty). Never send `thinking`, `output_config`, `temperature`/`top_p`/`top_k`, `fallbacks` or `anthropic-beta`. Sonnet 5.5 returns a 400 for non-default sampling params, and its adaptive thinking is on by default, so it needs no extra field.
- OpenAI-compatible: `POST <baseURL>/chat/completions`, `Authorization: Bearer <key>`; base URL from the registry closure (app default `https://api.openai.com/v1`).
- `ProviderRegistry.makeSession()`: `URLSessionConfiguration.ephemeral`, `httpMaximumConnectionsPerHost = 4`, `timeoutIntervalForRequest = 60`, `waitsForConnectivity = false`. Anthropic sends `ping` events during long thinking, so the 60 s idle timeout does not cut slow answers.
- Prewarm: one `HEAD` to the provider origin (`scheme://host[:port]/`), at most once per **60 s** per host, request `timeoutInterval = 10`, result ignored.
- Keychain: service `dev.local.Companion`, `kSecClassGenericPassword`, account = the `SecretKey` string, login (file-based) keychain — no `kSecUseDataProtectionKeychain`, which fails without entitlements under `swift test`.
- Images are PNG only: media type `image/png`, `Data.base64EncodedString()` with no options (no line breaks).
- Error copy (exact): unknown provider → `LLMError.http(status: 0, message: "Unknown provider: <id>")`; stream cut before completion → `LLMError.network("Stream ended before the response finished")`.
- `LLMRequest.maxTokens` (default 4096) is sent as-is; adapters never pick a model or a token limit.
- Tests: Swift Testing only (`import Testing`, `@testable import CompanionLLM`, `import CompanionCore`, `import CompanionTestSupport`). Each test file wraps its `@Test`s in `struct <FileName>` (e.g. `struct SSEParserTests`), so that `--filter CompanionLLMTests.<FileName>` selects it. Run `swift test --filter CompanionLLMTests`. No test touches the real network except Task 10's opt-in smoke test.

## Review Focus

1. **529 overloaded, before the stream or mid-answer.** A 529 status, or an SSE `error` event after some text, yields the text already streamed and then throws `LLMError.http(status: 529, message: "Overloaded")`. That lets the UI show "Anthropic API error 529 — retry / switch model" (spec §7) under the partial answer. *(Task 4: `overloadedMidStreamKeepsPartialTextThenThrows`, `httpStatusErrorsUseAPIMessage`)*
2. **Arbitrary chunk boundaries.** Events can split mid-line, mid-UTF-8 character or between `\r` and `\n`, or arrive one byte at a time, and they must still parse identically. The transport must feed raw bytes, never `AsyncBytes.lines`, which silently drops the blank lines that dispatch SSE events. *(Task 1: `byteAtATimeMatchesWholeFeed`, `crlfSplitAcrossChunks`, `multibyteUTF8SplitAcrossChunks`; Task 4: `adapterStreamsFixtureInSmallChunks`)*
3. **Empty, whitespace-only or newline-padded API key in the Keychain.** An empty or whitespace-only key throws `missingAPIKey` (the bubble shows "add your key" instead of a 401). A pasted key with a trailing newline is trimmed before use. *(Task 6: `blankKeysThrowMissingAPIKey`, `keyIsTrimmed`)*
4. **Sonnet 5.5 thinking blocks and unknown stream shapes.** A Sonnet 5.5 stream opens with a `thinking` block (empty text, `signature_delta`) and pings, possibly for seconds. The decoder must ignore it, plus unknown event and block types, without failing. The same goes for OpenAI-compatible usage chunks with empty `choices`. *(Task 4: `ignoresThinkingBlocksAndPings`, `ignoresUnknownEventAndBlockTypes`; Task 5: `toleratesEmptyChoicesAndNullContent`)*
5. **History after a failed or cancelled turn.** An empty assistant reply or two user turns in a row would make Anthropic return a 400 on the next question. `PromptBuilder` drops empty text, drops empty messages and merges consecutive same-role turns. *(Task 9: `normalizesHistoryAfterFailedTurn`)*

## File Structure

`Sources/CompanionLLM/` contains:
- `SSEParser.swift` (T1)
- `SSETransport.swift` (T2)
- `ProviderRegistry.swift` (T2 `makeSession`, T6 the rest)
- `Anthropic/{AnthropicRequestEncoder, AnthropicStreamDecoder, AnthropicAdapter}.swift` (T3–T4)
- `OpenAI/{OpenAICompatibleRequestEncoder, OpenAICompatibleStreamDecoder, OpenAICompatibleAdapter}.swift` (T5)
- `KeychainSecretStore.swift` (T7), `ModelRouter.swift` (T8), `PromptBuilder.swift` (T9)

`Tests/CompanionLLMTests/` contains `Support/` (stub transport, JSON and fixture helpers), `Fixtures/*.sse|*.json`, and one `*Tests.swift` per task.

Tasks 7, 8 and 9 do not depend on Tasks 1–6 and may run in parallel with them.

---

### Task 1: SSE parser

**Files:**
- Create: `Sources/CompanionLLM/SSEParser.swift`
- Test: `Tests/CompanionLLMTests/SSEParserTests.swift`
- Delete: `Sources/CompanionLLM/CompanionLLM.swift`, `Tests/CompanionLLMTests/PlaceholderTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
```swift
struct SSEEvent: Equatable, Sendable { var event: String?; var data: String }   // event nil = unnamed
struct SSEParser: Sendable {
    init()
    mutating func feed<S: Sequence>(_ bytes: S) -> [SSEEvent] where S.Element == UInt8
    mutating func finish() -> [SSEEvent]
}
```

- [ ] **Step 1: Write the failing tests** (`func parse(_ chunks: [String]) -> [SSEEvent]` is a file-private helper that feeds each chunk's UTF-8 bytes and then calls `finish()`)

```swift
@Test func namedEvent() {
    #expect(parse(["event: message_start\ndata: {\"a\":1}\n\n"]) == [SSEEvent(event: "message_start", data: "{\"a\":1}")])
}
@Test func multiLineDataJoinedWithNewline() { #expect(parse(["data: one\ndata: two\n\n"]) == [SSEEvent(event: nil, data: "one\ntwo")]) }
@Test(arguments: ["\r\n", "\r", "\n"]) func anyLineTerminator(_ t: String) {
    #expect(parse(["event: e\(t)data: x\(t)\(t)"]) == [SSEEvent(event: "e", data: "x")])
}
@Test func crlfSplitAcrossChunks() { #expect(parse(["data: a\r", "\n\r", "\n"]) == [SSEEvent(event: nil, data: "a")]) }
@Test func commentsAndUnknownFieldsIgnored() {
    #expect(parse([": keep-alive\nretry: 100\nid: 7\nfoo\ndata: x\n\n"]) == [SSEEvent(event: nil, data: "x")])
}
@Test func onlyOneLeadingSpaceStripped() {
    #expect(parse(["data:  two\n\ndata:x\n\n"]) == [SSEEvent(event: nil, data: " two"), SSEEvent(event: nil, data: "x")])
}
@Test func blankLineWithoutDataDispatchesNothingAndResetsName() {
    #expect(parse(["event: ping\n\ndata: y\n\n"]) == [SSEEvent(event: nil, data: "y")])
}
@Test func multibyteUTF8SplitAcrossChunks() {
    let bytes = Array("data: café ∑\n\n".utf8); var p = SSEParser()
    let split = bytes.firstIndex(of: 0xC3)! + 1                 // inside "é"
    let events = p.feed(bytes[..<split]) + p.feed(bytes[split...]) + p.finish()
    #expect(events == [SSEEvent(event: nil, data: "café ∑")])
}
@Test func byteAtATimeMatchesWholeFeed() {
    let stream = "event: a\ndata: 1\n\n: c\r\nevent: b\r\ndata: 2\r\ndata: 3\r\n\r\ndata: [DONE]\n\n"
    var p = SSEParser(); var oneByOne: [SSEEvent] = []
    for b in stream.utf8 { oneByOne += p.feed(CollectionOfOne(b)) }
    #expect(oneByOne + p.finish() == parse([stream]))
    #expect(parse([stream]).count == 3)
}
@Test func finishDispatchesPendingCompleteLinesAndDropsPartialLine() {
    #expect(parse(["data: [DONE]\n"]) == [SSEEvent(event: nil, data: "[DONE]")])
    #expect(parse(["data: {\"type\":\"content_bl"]) == [])
}
```

- [ ] **Step 2: Run** `swift test --filter CompanionLLMTests.SSEParserTests` → FAIL (`SSEParser` not defined).

- [ ] **Step 3: Implement `SSEParser` in `SSEParser.swift`.** Follow the WHATWG SSE rules:
  - Buffer bytes until a line terminator (LF, CRLF or CR). A CR at the end of one `feed` followed by LF at the start of the next counts as one terminator.
  - Decode each complete line as UTF-8. Lines starting with `:` are comments.
  - `field:value` splits on the first colon and strips one leading space from the value. A line without a colon is a field with an empty value.
  - `data` appends value + `"\n"`. `event` sets the event name. Other fields are ignored.
  - A blank line dispatches only if the data buffer is non-empty (dropping the trailing `"\n"`), then resets data and event name.
  - `finish()` discards an unterminated last line, then dispatches any pending event that has data.

- [ ] **Step 4: Run** `swift test --filter CompanionLLMTests.SSEParserTests` → PASS.

- [ ] **Step 5: Commit**
```bash
git add -A Sources/CompanionLLM Tests/CompanionLLMTests
git commit -m "feat(llm): incremental SSE parser"
```

---

### Task 2: Streaming transport, session factory, prewarm

**Files:**
- Create: `Sources/CompanionLLM/SSETransport.swift`, `Sources/CompanionLLM/ProviderRegistry.swift` (only `makeSession()` in this task)
- Create test support: `Tests/CompanionLLMTests/Support/StubURLProtocol.swift`
- Test: `Tests/CompanionLLMTests/TransportTests.swift`

**Interfaces:**
- Consumes: `SSEParser`, `SSEEvent` (Task 1); `LLMStreamEvent`, `LLMError` (Core).
- Produces:
```swift
protocol StreamDecoding: Sendable {
    var isDone: Bool { get }                                     // transport stops reading once true
    mutating func decode(_ event: SSEEvent) throws -> [LLMStreamEvent]
    mutating func finish() throws -> [LLMStreamEvent]            // called at EOF while !isDone
}
struct SSETransport: Sendable {
    static let streamEndedEarly = "Stream ended before the response finished"
    let session: URLSession
    func stream<D: StreamDecoding>(_ request: URLRequest, decoder: D,
                                   errorMessage: @escaping @Sendable (Data) -> String?) -> AsyncThrowingStream<LLMStreamEvent, any Error>
    func prewarm(_ url: URL, gate: PrewarmGate) async             // HEAD origin(of: url) if gate allows
    static func origin(of url: URL) -> URL                         // scheme://host[:port]/
    static func fallbackMessage(body: Data, status: Int) -> String
}
actor PrewarmGate {
    init(interval: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() })
    func shouldPrewarm(host: String) -> Bool                      // true at most once per interval per host; records the time
}
public final class ProviderRegistry: Sendable { public static func makeSession() -> URLSession }   // rest in Task 6
```
- Produces (test support, used by Tasks 4–6):
```swift
struct CapturedRequest: Sendable { var method: String; var url: URL; var headers: [String: String]; var body: Data }
final class StubServer: Sendable {
    init()                                           // unique host "<uuid>.stub.test"; session uses StubURLProtocol
    let host: String; let baseURL: URL; let session: URLSession       // baseURL = https://<host>
    func respond(status: Int = 200, headers: [String: String] = ["Content-Type": "text/event-stream"],
                 chunks: [Data] = [], holdOpen: Bool = false)
    func fail(_ code: URLError.Code)
    var requests: [CapturedRequest] { get }
    var stopLoadingCount: Int { get }
}
func collect(_ s: AsyncThrowingStream<LLMStreamEvent, any Error>) async -> (events: [LLMStreamEvent], error: (any Error)?)
func chunked(_ data: Data, size: Int) -> [Data]
```
`StubURLProtocol` keeps per-host state in a static `OSAllocatedUnfairLock<[String: HostState]>` (macOS 14 has no `Mutex`), so suites can run in parallel. It reads the request body from `httpBodyStream` when `httpBody` is nil, because URLSession moves bodies there. It serves the response chunks one `didLoad` at a time. It skips `urlProtocolDidFinishLoading` when `holdOpen` is set, and counts `stopLoading()` calls. An unregistered host gets a 404 with an empty body.

- [ ] **Step 1: Write the failing tests** (`EchoDecoder` is test-local: data `"end"` → sets `isDone`, returns `[.finished(stopReason: "end")]`; any other data → `[.textDelta(data)]`; `finish()` throws `LLMError.network(SSETransport.streamEndedEarly)`)

```swift
@Test func makeSessionConfiguration() {
    let c = ProviderRegistry.makeSession().configuration
    #expect(c.httpMaximumConnectionsPerHost == 4 && c.timeoutIntervalForRequest == 60 && c.waitsForConnectivity == false)
}
@Test func streamsDecodedEventsAcrossChunks() async {
    let s = StubServer(); s.respond(chunks: chunked(Data("data: a\n\ndata: b\n\ndata: end\n\n".utf8), size: 3))
    let r = await collect(SSETransport(session: s.session).stream(URLRequest(url: s.baseURL), decoder: EchoDecoder(), errorMessage: { _ in nil }))
    #expect(r.events == [.textDelta("a"), .textDelta("b"), .finished(stopReason: "end")] && r.error == nil)
}
@Test func eofBeforeDoneSurfacesDecoderFinish()    // "data: a\n\n" → events [.textDelta("a")], error == LLMError.network(streamEndedEarly)
@Test func non2xxUsesParsedMessage()               // 401 body {"m":"bad key"}, closure reads "m" → events [], error == .http(status: 401, message: "bad key")
@Test func non2xxFallsBackToBodyThenStatusText()   // 502 "<html>Bad Gateway</html>" → that string; 503 empty → HTTPURLResponse.localizedString(forStatusCode: 503)
@Test func transportFailureMapsToNetwork()         // s.fail(.notConnectedToInternet) → error matches `case .network` (any message)
@Test func cancellingConsumerCancelsURLSessionTask() async throws {
    // respond(chunks: ["data: a\n\n"], holdOpen: true); a Task consumes and records the first event; cancel it;
    // poll up to 2 s → #expect(s.stopLoadingCount == 1)
}
@Test func prewarmSendsOneHEADPerHostPerInterval() async {
    // gate = PrewarmGate(now: { clock.value }) with a lock-protected test clock; prewarm(s.baseURL/v1/messages) twice
    // → requests == 1, method "HEAD", url "https://<host>/"; advance clock 61 s; prewarm → 2 requests
}
@Test func originDropsPathAndQuery() {
    #expect(SSETransport.origin(of: URL(string: "http://localhost:11434/v1?x=1")!).absoluteString == "http://localhost:11434/")
    #expect(SSETransport.origin(of: URL(string: "https://api.anthropic.com/v1/messages")!).absoluteString == "https://api.anthropic.com/")
}
```

- [ ] **Step 2: Run** `swift test --filter CompanionLLMTests.TransportTests` → FAIL (symbols not defined).

- [ ] **Step 3: Implement** `SSETransport.swift` and `ProviderRegistry.makeSession()`.
  - `stream` runs a `Task` and wires `continuation.onTermination` to cancel it. Cancelling `session.bytes(for:)` cancels the URLSession task.
  - On a non-2xx status it reads up to 65,536 body bytes and throws `.http(status:message: errorMessage(body) ?? fallbackMessage(...))`.
  - On 2xx it feeds raw bytes into `SSEParser`, never `.lines`. It yields decoded events and stops once `decoder.isDone`. At EOF it calls `parser.finish()` and then `decoder.finish()`.
  - Error mapping: `LLMError` passes through. `CancellationError` and `URLError.cancelled` finish without error. Any other `URLError` → `.network(error.localizedDescription)`. A non-HTTP response → `.network("Invalid response")`.
  - `fallbackMessage`: the trimmed UTF-8 body's first 300 characters, or `HTTPURLResponse.localizedString(forStatusCode:)` when the body is empty.
  - `prewarm` sends `HEAD` to `origin(of:)` with `timeoutInterval = 10` and ignores the outcome.

- [ ] **Step 4: Run** `swift test --filter CompanionLLMTests.TransportTests` → PASS.

- [ ] **Step 5: Commit** — `git add -A Sources/CompanionLLM Tests/CompanionLLMTests && git commit -m "feat(llm): SSE streaming transport, session factory, prewarm throttle"`

---

### Task 3: Anthropic request encoding

**Files:**
- Create: `Sources/CompanionLLM/Anthropic/AnthropicRequestEncoder.swift`
- Create test support: `Tests/CompanionLLMTests/Support/JSONHelpers.swift` — `func json(_ literal: String) throws -> JSONValue` and `func bodyJSON(_ r: URLRequest) throws -> JSONValue` (decode with Core's `JSONValue`; compare whole bodies with `==`)
- Test: `Tests/CompanionLLMTests/AnthropicRequestTests.swift`

**Interfaces:**
- Consumes: `LLMRequest`, `LLMMessage`, `LLMContent`, `LLMToolSpec`, `JSONValue`, `ModelCatalog` (Core); `Fixtures.samplePNG` (TestSupport).
- Produces:
```swift
enum AnthropicRequestEncoder {
    static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    static let apiVersion = "2023-06-01"
    /// POST <baseURL>/v1/messages. Throws LLMError.decoding("Invalid tool JSON: <name>") for unparsable tool JSON.
    static func urlRequest(for request: LLMRequest, apiKey: String, baseURL: URL = defaultBaseURL) throws -> URLRequest
}
```
Block mapping (content is always an array):

| `LLMContent` | JSON block |
|---|---|
| `.text(s)` | `{"type":"text","text":s}` |
| `.image(a)` | `{"type":"image","source":{"type":"base64","media_type":"image/png","data":a.png.base64EncodedString()}}` |
| `.toolUse(id,name,inputJSON)` | `{"type":"tool_use","id":id,"name":name,"input":<parsed inputJSON>}` |
| `.toolResult(id,content,isError)` | `{"type":"tool_result","tool_use_id":id,"content":content}` plus `"is_error":true` only when `isError` |
| `LLMToolSpec` | `{"name":…,"description":…,"input_schema":<parsed inputSchemaJSON>}` |

- [ ] **Step 1: Write the failing tests**

```swift
@Test func endpointAndHeaders() throws {
    let r = try AnthropicRequestEncoder.urlRequest(for: LLMRequest(model: ModelCatalog.haiku45, system: "S", messages: [.init(role: .user, content: [.text("hi")])]), apiKey: "sk-ant-test")
    #expect(r.url?.absoluteString == "https://api.anthropic.com/v1/messages" && r.httpMethod == "POST")
    #expect(r.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
    #expect(r.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    #expect(r.value(forHTTPHeaderField: "content-type") == "application/json")
    #expect(r.value(forHTTPHeaderField: "accept") == "text/event-stream")
}
@Test func bodyForTextConversation() throws {
    // messages: user "hi", assistant "hello", user "more"; system "SYS"
    #expect(try bodyJSON(r) == json(#"{"model":"claude-haiku-4-5-20251001","max_tokens":4096,"system":"SYS","stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]},{"role":"assistant","content":[{"type":"text","text":"hello"}]},{"role":"user","content":[{"type":"text","text":"more"}]}]}"#))
}
@Test func emptySystemAndNoToolsAreOmitted()   // system "" → body has no "system" and no "tools" key
@Test func imageBlockIsBase64PNG()             // Fixtures.samplePNG() → block equals the table row, data == png.base64EncodedString()
@Test func largeImageEncodesWithoutLineBreaks() throws {
    let png = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    // encode one user message with .image(ImageAttachment(png: png, pixelWidth: 1500, pixelHeight: 1000));
    // the "data" string == png.base64EncodedString(), contains neither "\n" nor "\r", and Data(base64Encoded:) == png
}
@Test func toolBlocksAndToolsEncoded() throws {
    // assistant [.toolUse(id: "toolu_01A", name: "get_weather", inputJSON: #"{"location":"Paris"}"#)],
    // user [.toolResult(toolUseID: "toolu_01A", content: "72°F", isError: false), .toolResult(toolUseID: "toolu_01B", content: "boom", isError: true)],
    // tools [LLMToolSpec(name: "get_weather", description: "Get weather", inputSchemaJSON: #"{"type":"object","properties":{"location":{"type":"string"}}}"#)]
    // → "input" is the object {"location":"Paris"}; first result has no "is_error"; second has "is_error":true;
    //   "tools":[{"name":"get_weather","description":"Get weather","input_schema":{"type":"object","properties":{"location":{"type":"string"}}}}]
}
@Test func invalidToolJSONThrowsDecoding()     // inputJSON "{nope" → throws LLMError.decoding("Invalid tool JSON: get_weather")
```

- [ ] **Step 2: Run** `swift test --filter CompanionLLMTests.AnthropicRequestTests` → FAIL.
- [ ] **Step 3: Implement `AnthropicRequestEncoder.urlRequest(for:apiKey:baseURL:)`.** Build `[String: Any]` and serialize with `JSONSerialization` using `.withoutEscapingSlashes`. Parse raw tool JSON with `JSONSerialization.jsonObject(with:options: .fragmentsAllowed)`.
- [ ] **Step 4: Run** `swift test --filter CompanionLLMTests.AnthropicRequestTests` → PASS.
- [ ] **Step 5: Commit** — `git add -A Sources/CompanionLLM Tests/CompanionLLMTests && git commit -m "feat(llm): Anthropic Messages request encoding"`

---

### Task 4: Anthropic stream decoding and adapter

**Files:**
- Create: `Sources/CompanionLLM/Anthropic/AnthropicStreamDecoder.swift`, `Sources/CompanionLLM/Anthropic/AnthropicAdapter.swift`
- Create test support: `Tests/CompanionLLMTests/Support/LLMFixtures.swift`
- Create fixtures: `Tests/CompanionLLMTests/Fixtures/anthropic-text.sse`, `anthropic-thinking-text.sse`, `anthropic-tool-use.sse`, `anthropic-overloaded-midstream.sse`, `anthropic-error-401.json`, `anthropic-error-429.json`, `anthropic-error-529.json`
- Test: `Tests/CompanionLLMTests/AnthropicStreamTests.swift`, `Tests/CompanionLLMTests/AnthropicAdapterTests.swift`

**Interfaces:**
- Consumes: `SSEEvent`, `SSEParser` (Task 1); `StreamDecoding`, `SSETransport`, `PrewarmGate`, `StubServer`, `collect`, `chunked` (Task 2); `AnthropicRequestEncoder` (Task 3).
- Produces:
```swift
struct AnthropicStreamDecoder: StreamDecoding {
    init()
    static func status(forErrorType type: String) -> Int
    static func errorMessage(from body: Data) -> String?      // error.message of {"type":"error","error":{…}}
}
final class AnthropicAdapter: LLMProvider {
    init(apiKey: String, session: URLSession, baseURL: URL = AnthropicRequestEncoder.defaultBaseURL,
         prewarmGate: PrewarmGate = PrewarmGate())
    let apiKey: String; let baseURL: URL
    var providerID: String { get }                              // ModelRef.anthropicProviderID
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error>
    func prewarm() async                                        // transport.prewarm(baseURL, gate:)
}
enum LLMFixture {
    static func data(_ name: String) throws -> Data            // Bundle.module, subdirectory "Fixtures"
    static func events(_ name: String) throws -> [SSEEvent]    // SSEParser over the whole file + finish()
}
```
Decoding rules (dispatch on the data's JSON `type`):

| Wire | Output |
|---|---|
| `message_start`, `ping`, unknown `type` | nothing |
| `content_block_start` with `tool_use` | start accumulating `{id, name, json: ""}` at `index`; other block types (`text`, `thinking`, `redacted_thinking`, anything new) → nothing |
| `content_block_delta` `text_delta` | `.textDelta(text)` (skip empty) |
| `content_block_delta` `input_json_delta` | append `partial_json` to that index |
| `content_block_delta` `thinking_delta` / `signature_delta` / other | nothing |
| `content_block_stop` for a tool index | `.toolUse(id:name:inputJSON:)` with `"{}"` when nothing accumulated |
| `message_delta` | remember `delta.stop_reason` |
| `message_stop` | `.finished(stopReason: remembered)`, `isDone = true` |
| `error` | throw `.http(status: status(forErrorType: error.type), message: error.message)` |
| unparsable data | throw `.decoding("<event name ?? \"message\">: <parser error description>")` |
| `finish()` (EOF before `message_stop`) | throw `.network(SSETransport.streamEndedEarly)` |

`status(forErrorType:)`: `invalid_request_error` 400, `authentication_error` 401, `billing_error` 402, `permission_error` 403, `not_found_error` 404, `request_too_large` 413, `rate_limit_error` 429, `api_error` 500, `overloaded_error` 529, anything else 500. Stop reasons pass through raw (`end_turn`, `max_tokens`, `tool_use`, `refusal`, …).

**Fixtures (exact).** Every `.sse` file ends with one blank line. Each Anthropic `.sse` starts with this event; only `id` and `model` change (text: `msg_01`/haiku; thinking: `msg_02`/`claude-sonnet-5-5`; tool: `msg_03`/haiku; overloaded: `msg_04`/haiku):
```
event: message_start
data: {"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","model":"claude-haiku-4-5-20251001","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":25,"output_tokens":1}}}
```
The rest of each file, as `event: <type>` + `data: <json>` pairs separated by blank lines (`event:` equals the JSON `type`):
- `anthropic-text.sse`: `{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}` · `{"type":"ping"}` · `{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"The roots are "}}` · `{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"$x=2$ and $x=3$."}}` · `{"type":"content_block_stop","index":0}` · `{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":14}}` · `{"type":"message_stop"}`
- `anthropic-thinking-text.sse`: `{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}` · `{"type":"ping"}` · `{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}` · `{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQBCkYIARgCIkB0ZXN0"}}` · `{"type":"content_block_stop","index":0}` · `{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}` · `{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Here is a hint."}}` · `{"type":"content_block_stop","index":1}` · `{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":30}}` · `{"type":"message_stop"}`
- `anthropic-tool-use.sse`: text block 0 with one delta `"Let me check."` (start/delta/stop as above) · `{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01A","name":"get_weather","input":{}}}` · `{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":""}}` · `{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"location\": \"Pa"}}` · `{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"ris\"}"}}` · `{"type":"content_block_stop","index":1}` · `{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":40}}` · `{"type":"message_stop"}`
- `anthropic-overloaded-midstream.sse`: text block start · one `text_delta` `"The roots"` · then `event: error` / `data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}` (no stop, no `message_stop`)
- `anthropic-error-401.json`: `{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"},"request_id":"req_011CTest401"}`
- `anthropic-error-429.json`: `{"type":"error","error":{"type":"rate_limit_error","message":"Number of request tokens has exceeded your per-minute rate limit"},"request_id":"req_011CTest429"}`
- `anthropic-error-529.json`: `{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"},"request_id":"req_011CTest529"}`

- [ ] **Step 1: Write the failing tests.** `decodeAll(_ fixture:) -> (events, error)` is a file-private helper. It runs `AnthropicStreamDecoder` over `LLMFixture.events(...)`, stopping at the first throw, and calls `finish()` if the decoder is not done.

```swift
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
func errorTypeStatus(_ type: String, _ status: Int) { #expect(AnthropicStreamDecoder.status(forErrorType: type) == status) }
@Test func malformedJSONThrowsDecoding()       // decode(SSEEvent(event: "content_block_delta", data: "{not json")) throws .decoding(m) with m.hasPrefix("content_block_delta: ")
@Test func eofBeforeMessageStopThrows()       // fresh decoder: finish() throws .network("Stream ended before the response finished")
```
`AnthropicAdapterTests.swift` (all use `StubServer`; adapter built with `baseURL: s.baseURL`):
```swift
@Test func adapterStreamsFixtureInSmallChunks()     // respond(chunks: chunked(LLMFixture.data("anthropic-text.sse"), size: 7)) → same events as decodesTextStream;
                                                    // s.requests[0]: POST, url path "/v1/messages", header "x-api-key" == "sk-ant-test"
@Test(arguments: [(401, "anthropic-error-401.json", "invalid x-api-key"),
                  (429, "anthropic-error-429.json", "Number of request tokens has exceeded your per-minute rate limit"),
                  (529, "anthropic-error-529.json", "Overloaded")])
func httpStatusErrorsUseAPIMessage(_ status: Int, _ file: String, _ message: String)   // events [] and error == .http(status:, message:)
@Test func encodingFailureSurfacesThroughStream()  // tool inputJSON "{nope" → error == .decoding("Invalid tool JSON: get_weather"), no request sent
@Test func prewarmSendsHEADToOrigin()              // await adapter.prewarm() → one request, method "HEAD", url "https://<host>/"
```

- [ ] **Step 2: Run** `swift test --filter "CompanionLLMTests.Anthropic"` → FAIL.
- [ ] **Step 3: Implement** `AnthropicStreamDecoder` per the rules table, and `AnthropicAdapter`. `stream` encodes with `AnthropicRequestEncoder`; an encoding error comes back as a stream that immediately finishes throwing it. Otherwise it returns `SSETransport.stream(_, decoder: AnthropicStreamDecoder(), errorMessage: AnthropicStreamDecoder.errorMessage(from:))`.
- [ ] **Step 4: Run** `swift test --filter "CompanionLLMTests.Anthropic"` → PASS.
- [ ] **Step 5: Commit** — `git add -A Sources/CompanionLLM Tests/CompanionLLMTests && git commit -m "feat(llm): Anthropic stream decoding, error mapping and adapter"`

---

### Task 5: OpenAI-compatible adapter

**Files:**
- Create: `Sources/CompanionLLM/OpenAI/OpenAICompatibleRequestEncoder.swift`, `OpenAICompatibleStreamDecoder.swift`, `OpenAICompatibleAdapter.swift`
- Create fixtures: `Tests/CompanionLLMTests/Fixtures/openai-text.sse`, `openai-tool-calls.sse`, `openai-error-401.json`
- Test: `Tests/CompanionLLMTests/OpenAICompatibleRequestTests.swift`, `Tests/CompanionLLMTests/OpenAICompatibleStreamTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2 (parser, transport, stub), `JSONHelpers`, `LLMFixture` (Task 4).
- Produces:
```swift
enum OpenAICompatibleRequestEncoder {
    static func urlRequest(for request: LLMRequest, apiKey: String, baseURL: URL) throws -> URLRequest
}
struct OpenAICompatibleStreamDecoder: StreamDecoding {
    init()
    static func errorMessage(from body: Data) -> String?        // error.message of {"error":{"message":…}}
}
final class OpenAICompatibleAdapter: LLMProvider {
    init(apiKey: String, baseURL: URL, session: URLSession, prewarmGate: PrewarmGate = PrewarmGate())
    let apiKey: String; let baseURL: URL
    var providerID: String { get }                               // ModelRef.openAICompatibleProviderID
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error>
    func prewarm() async
}
```
Encoding rules:
- URL: `baseURL.appendingPathComponent("chat/completions")`. Headers: `Authorization: Bearer <key>`, `content-type: application/json`, `accept: text/event-stream`.
- Body: `model`, `stream: true`, `messages`, `tools` (only when non-empty). The token limit is sent as `max_tokens`, except when `baseURL.host == "api.openai.com"`, which gets `max_completion_tokens` (current OpenAI models reject `max_tokens`).
- `system`: when non-empty, the first message is `{"role":"system","content":system}`.
- User message: each `.toolResult` becomes its own `{"role":"tool","tool_call_id":id,"content":content}` message, in order. The remaining blocks, if any, become `{"role":"user","content":[parts]}`, with `.text` → `{"type":"text","text":…}` and `.image` → `{"type":"image_url","image_url":{"url":"data:image/png;base64,<b64>"}}`, in content order.
- Assistant message: `"content"` is the text blocks joined with `""`, or `null` when there is no text but there are tool calls. `.toolUse` → `"tool_calls":[{"id":…,"type":"function","function":{"name":…,"arguments":inputJSON}}]`.
- Tool spec → `{"type":"function","function":{"name":…,"description":…,"parameters":<parsed>}}`. Invalid JSON throws `.decoding("Invalid tool JSON: <name>")`.

Decoding rules:
- `data: [DONE]` → emit pending tool calls, then `.finished(stopReason: finishReason)` and set `isDone`.
- An object with a top-level `"error"` → throw `.http(status: (error.code as Int) ?? 500, message: error.message ?? "Unknown error")`.
- Empty `choices` → nothing.
- A non-empty `choices[0].delta.content` string → `.textDelta`.
- `delta.tool_calls[]` accumulate by `index`: `id` and `function.name` are set when present, `function.arguments` is appended.
- A non-null `finish_reason` is remembered, and the accumulated calls are emitted once, in ascending index order, as `.toolUse` (empty arguments → `"{}"`).
- Other delta fields (`role`, `reasoning`, `refusal`, …) are ignored. Unparsable data → `.decoding`.
- `finish()`: if a `finish_reason` was seen → [pending tools…, `.finished(stopReason:)`]; otherwise throw `.network(SSETransport.streamEndedEarly)`.

Fixtures (exact, `data:` lines separated by blank lines, ending with a blank line):
- `openai-text.sse`: `{"id":"c1","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}` · `{"id":"c1","choices":[{"index":0,"delta":{"content":"The roots"},"finish_reason":null}]}` · `{"id":"c1","choices":[{"index":0,"delta":{"content":" are 2 and 3."},"finish_reason":null}]}` · `{"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}` · `{"id":"c1","choices":[],"usage":{"prompt_tokens":20,"completion_tokens":6,"total_tokens":26}}` · `[DONE]`
- `openai-tool-calls.sse`: `{"id":"c2","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_weather","arguments":""}}]},"finish_reason":null}]}` · `{"id":"c2","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"location\":"}}]},"finish_reason":null}]}` · `{"id":"c2","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_2","type":"function","function":{"name":"get_time","arguments":"{\"tz\":\"CET\"}"}}]},"finish_reason":null}]}` · `{"id":"c2","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Paris\"}"}}]},"finish_reason":null}]}` · `{"id":"c2","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}` · `[DONE]`
- `openai-error-401.json`: `{"error":{"message":"Incorrect API key provided: sk-test.","type":"invalid_request_error","param":null,"code":"invalid_api_key"}}`

- [ ] **Step 1: Write the failing tests**

```swift
@Test(arguments: ["https://api.openai.com/v1", "https://api.openai.com/v1/"])
func endpointJoinsBaseURL(_ base: String)   // url == "https://api.openai.com/v1/chat/completions"; "Authorization" == "Bearer sk-test"; accept/content-type set
@Test func localServerEndpoint()            // "http://localhost:11434/v1" → "http://localhost:11434/v1/chat/completions"
@Test func bodyShape() throws {
    // base "https://openrouter.ai/api/v1", model ModelRef(providerID: "openai-compatible", modelID: "gpt-test", displayName: "GPT"),
    // img = Fixtures.samplePNG(); system "SYS", messages [user [.image(img), .text("q")], assistant [.text("a1")]], tools [get_weather spec from Task 3]
    #expect(try bodyJSON(r) == json(#"{"model":"gpt-test","stream":true,"max_tokens":4096,"messages":[{"role":"system","content":"SYS"},{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,\#(img.png.base64EncodedString())"}},{"type":"text","text":"q"}]},{"role":"assistant","content":"a1"}],"tools":[{"type":"function","function":{"name":"get_weather","description":"Get weather","parameters":{"type":"object","properties":{"location":{"type":"string"}}}}}]}"#))
}
@Test func openAIHostUsesMaxCompletionTokens() // base api.openai.com → "max_completion_tokens":4096 and no "max_tokens"
@Test func emptySystemOmitted()                // no system message when system == ""
@Test func toolHistoryEncoding()               // assistant toolUse → {"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"location\":\"Paris\"}"}}]};
                                               // user toolResult → {"role":"tool","tool_call_id":"call_1","content":"72°F"}
@Test func decodesTextStream()                 // openai-text.sse → [.textDelta("The roots"), .textDelta(" are 2 and 3."), .finished(stopReason: "stop")]
@Test func accumulatesToolCallsByIndex()       // openai-tool-calls.sse → [.toolUse(id: "call_1", name: "get_weather", inputJSON: #"{"location":"Paris"}"#),
                                               //   .toolUse(id: "call_2", name: "get_time", inputJSON: #"{"tz":"CET"}"#), .finished(stopReason: "tool_calls")]
@Test func toleratesEmptyChoicesAndNullContent() // {"choices":[]} and {"choices":[{"index":0,"delta":{"content":null},"finish_reason":null}]} → [] each, no throw
@Test func missingDoneAfterFinishReasonStillFinishes() // decode a finish_reason "stop" chunk, then finish() → [.finished(stopReason: "stop")]
@Test func eofWithoutFinishThrows()            // fresh decoder finish() throws .network("Stream ended before the response finished")
@Test func inStreamErrorObjectThrows()         // {"error":{"message":"Upstream error","code":502}} → .http(status: 502, message: "Upstream error"); code "rate_limit" → status 500
@Test func http401UsesErrorMessage() async     // StubServer 401 + openai-error-401.json → .http(status: 401, message: "Incorrect API key provided: sk-test.")
@Test func adapterStreamsOverHTTP() async      // StubServer 200 + openai-text.sse in 5-byte chunks → same events as decodesTextStream
```

- [ ] **Step 2: Run** `swift test --filter CompanionLLMTests.OpenAICompatible` → FAIL.
- [ ] **Step 3: Implement** the encoder and decoder per the rules above, and the adapter with the same wiring as `AnthropicAdapter` (Task 4). `prewarm()` calls `transport.prewarm(baseURL, gate:)`.
- [ ] **Step 4: Run** `swift test --filter CompanionLLMTests.OpenAICompatible` → PASS.
- [ ] **Step 5: Commit** — `git add -A Sources/CompanionLLM Tests/CompanionLLMTests && git commit -m "feat(llm): OpenAI-compatible chat-completions adapter"`

---

### Task 6: ProviderRegistry

**Files:**
- Modify: `Sources/CompanionLLM/ProviderRegistry.swift`
- Test: `Tests/CompanionLLMTests/ProviderRegistryTests.swift`

**Interfaces:**
- Consumes: `AnthropicAdapter` (Task 4), `OpenAICompatibleAdapter` (Task 5), `PrewarmGate` (Task 2); `SecretStoring`, `SecretKey`, `ModelRef`, `ModelCatalog`, `LLMError` (Core); `FakeSecretStore` (TestSupport).
- Produces (overview contract, verbatim):
```swift
public final class ProviderRegistry: Sendable {
    public init(secrets: SecretStoring, openAICompatibleBaseURL: @escaping @Sendable () -> URL,
                session: URLSession = ProviderRegistry.makeSession())
    public static func makeSession() -> URLSession
    public func provider(for model: ModelRef) throws -> any LLMProvider
}
```
`provider(for:)` reads the key on every call (no caching) and trims whitespace and newlines; an empty result throws `LLMError.missingAPIKey(providerID: model.providerID)`. `"anthropic"` → `AnthropicAdapter(apiKey:, session:, prewarmGate:)` with key `SecretKey.anthropicAPIKey`. `"openai-compatible"` → `OpenAICompatibleAdapter(apiKey:, baseURL: openAICompatibleBaseURL(), session:, prewarmGate:)` with key `SecretKey.openAICompatibleAPIKey`. Any other ID → `LLMError.http(status: 0, message: "Unknown provider: <id>")`. One `PrewarmGate` instance per registry is shared by every adapter it creates.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func anthropicModelGetsAnthropicAdapter() throws {
    let reg = ProviderRegistry(secrets: FakeSecretStore([SecretKey.anthropicAPIKey: "sk-ant-test"]), openAICompatibleBaseURL: { URL(string: "https://api.openai.com/v1")! })
    let p = try reg.provider(for: ModelCatalog.sonnet55)
    #expect((p as? AnthropicAdapter)?.apiKey == "sk-ant-test" && p.providerID == "anthropic")
}
@Test func keyIsTrimmed()                        // stored " sk-ant-test\n" → adapter apiKey == "sk-ant-test"
@Test(arguments: [nil, "", "   \n"]) func blankKeysThrowMissingAPIKey(_ key: String?) {
    // FakeSecretStore with key (or empty) → #expect(throws: LLMError.missingAPIKey(providerID: "anthropic")) { try reg.provider(for: ModelCatalog.haiku45) }
}
@Test func openAICompatibleUsesBaseURLClosureAtCallTime() // closure reads a lock-protected box: first call baseURL A, change box, second call baseURL B
@Test func openAICompatibleMissingKeyThrows()   // → .missingAPIKey(providerID: "openai-compatible")
@Test func unknownProviderThrows()              // ModelRef(providerID: "gemini-native", modelID: "x", displayName: "x") → .http(status: 0, message: "Unknown provider: gemini-native")
@Test func prewarmIsSharedAcrossProviders() async throws {
    // StubServer s; registry(session: s.session, base: { s.baseURL.appending(path: "v1") }); openai-compatible model;
    // try await reg.provider(for: m).prewarm(); try await reg.provider(for: m).prewarm() → s.requests.count == 1 (HEAD)
}
```

- [ ] **Step 2: Run** `swift test --filter CompanionLLMTests.ProviderRegistryTests` → FAIL.
- [ ] **Step 3: Implement** `init` and `provider(for:)` in `ProviderRegistry.swift`. The stored properties are `let`: `secrets`, `baseURL` closure, `session`, `prewarmGate`.
- [ ] **Step 4: Run** `swift test --filter CompanionLLMTests.ProviderRegistryTests` → PASS.
- [ ] **Step 5: Commit** — `git add -A Sources/CompanionLLM Tests/CompanionLLMTests && git commit -m "feat(llm): provider registry with key lookup and shared prewarm"`

---

### Task 7: KeychainSecretStore

**Files:**
- Create: `Sources/CompanionLLM/KeychainSecretStore.swift`
- Test: `Tests/CompanionLLMTests/KeychainSecretStoreTests.swift`

**Interfaces:**
- Consumes: `SecretStoring`, `SecretKey` (Core).
- Produces:
```swift
public final class KeychainSecretStore: SecretStoring {
    public init(service: String = "dev.local.Companion")
    public func secret(for key: String) -> String?                 // nil when absent or on any Keychain error
    public func setSecret(_ value: String?, for key: String) throws // nil deletes; deleting a missing item is not an error
}
public struct KeychainError: Error, Equatable, Sendable { public let status: OSStatus }
```

- [ ] **Step 1: Write the failing tests** (each test uses `let service = "dev.local.Companion.tests.\(UUID().uuidString)"` and `defer` deletes every item for that service with `SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service])`)

```swift
@Test func setGetOverwriteDelete() throws {
    let store = KeychainSecretStore(service: service)
    #expect(store.secret(for: SecretKey.anthropicAPIKey) == nil)
    try store.setSecret("sk-ant-1", for: SecretKey.anthropicAPIKey); #expect(store.secret(for: SecretKey.anthropicAPIKey) == "sk-ant-1")
    try store.setSecret("sk-ant-2", for: SecretKey.anthropicAPIKey); #expect(store.secret(for: SecretKey.anthropicAPIKey) == "sk-ant-2")
    try store.setSecret(nil, for: SecretKey.anthropicAPIKey);        #expect(store.secret(for: SecretKey.anthropicAPIKey) == nil)
}
@Test func deletingMissingKeyDoesNotThrow()  // try store.setSecret(nil, for: "never-set")
@Test func keysAndServicesAreIsolated()      // two accounts under one service, and a second service, never see each other's values
@Test func unicodeRoundTrips()               // "pässwörd-🔑" round-trips exactly
```

- [ ] **Step 2: Run** `swift test --filter CompanionLLMTests.KeychainSecretStoreTests` → FAIL.
- [ ] **Step 3: Implement.** Queries use `kSecClass: kSecClassGenericPassword`, `kSecAttrService: service` and `kSecAttrAccount: key`.
  - Read: `SecItemCopyMatching` with `kSecReturnData` and `kSecMatchLimitOne`, decoding the data as UTF-8.
  - Set: `SecItemUpdate` with `kSecValueData`. On `errSecItemNotFound`, fall back to `SecItemAdd` with `kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock`.
  - Delete: `SecItemDelete`, where `errSecItemNotFound` counts as success. Any other failing status throws `KeychainError(status:)`.
- [ ] **Step 4: Run** `swift test --filter CompanionLLMTests.KeychainSecretStoreTests` → PASS. (If it fails with `-25308 errSecInteractionNotAllowed`, the login keychain is locked; unlock it and rerun, and don't change the code.)
- [ ] **Step 5: Commit** — `git add -A Sources/CompanionLLM Tests/CompanionLLMTests && git commit -m "feat(llm): Keychain-backed secret store"`

---

### Task 8: ModelRouter

**Files:**
- Create: `Sources/CompanionLLM/ModelRouter.swift`
- Test: `Tests/CompanionLLMTests/ModelRouterTests.swift`

**Interfaces:**
- Consumes: `RoutingDefaults`, `ModelRef`, `ModelCatalog`, `ContextKind` (Core).
- Produces:
```swift
public struct ModelRouter: Sendable {
    public init(defaults: RoutingDefaults, cycle: [ModelRef])
    public func model(for kind: ContextKind) -> ModelRef        // defaults.model(for:)
    public func next(after current: ModelRef) -> ModelRef       // wraps; current ∉ cycle → cycle[0]; empty cycle → current
}
```
Cycle membership compares `providerID` and `modelID` only, because a user-edited `displayName` must not break Tab cycling.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func modelForKindUsesDefaults() {
    let r = ModelRouter(defaults: .standard, cycle: ModelCatalog.defaultCycle)
    for k in [ContextKind.youtube, .webPage, .genericWindow] { #expect(r.model(for: k) == ModelCatalog.haiku45) }
    for k in [ContextKind.mathPage, .pdfPages, .region] { #expect(r.model(for: k) == ModelCatalog.sonnet55) }
}
@Test func nextWraps()                     // next(after: haiku45) == sonnet55; next(after: sonnet55) == haiku45
@Test func nextFromUnknownReturnsFirst()   // ModelRef(providerID: "openai-compatible", modelID: "gpt-test", displayName: "GPT") → haiku45
@Test func nextMatchesByIDsNotDisplayName()// haiku45 with displayName "Fast" → sonnet55
@Test func nextOnEmptyCycleReturnsCurrent()// ModelRouter(defaults: .standard, cycle: []).next(after: sonnet55) == sonnet55
```

- [ ] **Step 2: Run** `swift test --filter CompanionLLMTests.ModelRouterTests` → FAIL.
- [ ] **Step 3: Implement** `ModelRouter`.
- [ ] **Step 4: Run** `swift test --filter CompanionLLMTests.ModelRouterTests` → PASS.
- [ ] **Step 5: Commit** — `git add -A Sources/CompanionLLM Tests/CompanionLLMTests && git commit -m "feat(llm): model router with per-context defaults and Tab cycle"`

---

### Task 9: PromptBuilder

**Files:**
- Create: `Sources/CompanionLLM/PromptBuilder.swift`
- Test: `Tests/CompanionLLMTests/PromptBuilderTests.swift`

**Interfaces:**
- Consumes: `CapturedContext`, `ContextItem`, `ContextPiece`, `FrontAppInfo`, `YouTubeContext`, `WebPageContext`, `MathSnippet`, `RenderedPage`, `ContextNotice.label`, `LLMMessage`, `LLMContent`, `formatTimestamp` (Core); `Fixtures.samplePNG` (TestSupport).
- Produces:
```swift
public struct PromptBuilder: Sendable {
    public init()
    /// Returns the system prompt and `history + [new user message]` (history normalized; see rules).
    public func build(question: String, context: CapturedContext?, history: [LLMMessage],
                      hintMode: Bool) -> (system: String, messages: [LLMMessage])
    static let baseInstructions: String
    static let hintModeInstructions: String
    static let readingLineInstruction: String
    static let omittedImagePlaceholder = "[image from an earlier turn omitted]"
}
```

**System prompt.** `system` = `baseInstructions`, then `hintModeInstructions` only when `hintMode`, then `readingLineInstruction` only when the context contains a `.windowImage` or `.regionImage` item **and** `!context.hasExtractedMath`. Parts are joined with `"\n\n"`. Exact copy:

```swift
static let baseInstructions = """
You are Companion, a study helper the student summons with a hotkey while looking at something on their Mac. Each question arrives with the context the app captured at that moment: screenshots, page text and math, a video's title and recent transcript, or textbook pages.

- Answer exactly what the student asked. If they ask for a hint, give a hint. If they ask you to check their work, check it and point to the first mistake. If they ask you to solve, solve it.
- Be concise: lead with the answer, then only the steps that matter.
- Format in Markdown. Write all math in LaTeX, with $...$ for inline math and $$...$$ for display math.
- Use only the supplied context and the conversation so far for what the student is looking at. If that is not enough to answer, say exactly what is missing instead of guessing.
"""
static let hintModeInstructions = """
Hint mode is on. Teach Socratically:
- Give only the next hint: one step or one guiding question that moves the student forward.
- Never give the full solution or the final answer unless the student explicitly asks for it.
- If the student shares their work, say whether it is right so far, then hint at the next step.
"""
static let readingLineInstruction = "Begin with one line `Reading: <the problem in LaTeX>` when you are solving or checking a problem you read from the image."
```

**New user message.**
- Content is one `.image` per image-bearing item, in item order (`.windowImage`, `.regionImage`, each page of `.pdfPages`), followed by exactly **one** `.text`.
- That text is `"<context>\n" + sections.joined("\n\n") + "\n</context>\n\n" + question`. When there are no sections (or `context == nil`), it is just `question`.
- Images are numbered 1…N in placement order. Sections, in order:
  - Front app (when `front != nil`): `App: <appName>`, then `Window: <windowTitle>` when non-empty.
  - Then one section per item:

| Piece | Section text |
|---|---|
| `.windowImage` | `Image <n>: screenshot of the front window` |
| `.regionImage` | `Image <n>: screenshot of a selected screen region` |
| `.youtubeVideo(y)` | `YouTube video: <title>` / `Channel: <channel>` (if any) / `Chapter: <chapter>` (if any) / `Position: at <fmt(playhead)> of <fmt(duration)>` (or `Position: at <fmt(playhead)>` when `durationSeconds == nil`). Never `y.transcript`. |
| `.transcriptWindow(s, from, to)` | `Transcript from <fmt(from)> to <fmt(to)>:` then one `[<fmt(start)>] <text>` line per segment |
| `.webPage(p)` | `Web page: <title>` / `URL: <url>` / `Visible text:` / `<visibleText>` (math comes only from `.math`) |
| `.math(m)` | `Math on the page (exact source):` then `- LaTeX: <source>` or `- MathML: <source>` per snippet |
| `.selectedText(s)` | `Selected text:` / `<s>` |
| `.focusedText(s)` | `Screen text:` / `<s>` |
| `.pdfPages(pages)` | one section per page: `Book page <printedLabel> (PDF page <pdfIndex+1>), image <n>:` then `<text>` when non-empty |
| `.notice(n)` | `Note: <n.label>` |

(`fmt` = `formatTimestamp`; `/` means newline.)

**History.**
- Copy each history message, replacing all `.image` blocks in it with one `.text(omittedImagePlaceholder)` at the first image's position. Only the new turn carries images.
- Then normalize `history + [new]`: drop `.text` blocks that are empty after trimming whitespace, drop messages left with no content, and merge consecutive same-role messages by concatenating their content in order.
- Anthropic returns a 400 on empty text blocks and on non-alternating roles, and a failed or cancelled turn can leave either behind.

- [ ] **Step 1: Write the failing tests** (file-private builders: `img1 = Fixtures.samplePNG(width: 4, height: 3)`, `img2 = Fixtures.samplePNG(width: 2, height: 2)`, `ctx(_ items: [ContextPiece], front: FrontAppInfo? = nil) -> CapturedContext` with `privacy: .allowed`, `kind: .genericWindow`, `isComplete: true`; `dia(_ title: String)` = `FrontAppInfo(bundleID: "company.thebrowser.dia", appName: "Dia", pid: 42, windowTitle: title, windowFrame: nil)`)

```swift
@Test func baseSystemPromptIsExact()     // build(question: "q", context: nil, history: [], hintMode: false).system == PromptBuilder.baseInstructions
@Test func hintBlockOnlyInHintMode()     // hintMode true → system == base + "\n\n" + hintModeInstructions; false → !system.contains("Hint mode is on")
@Test func readingRuleRules() {
    let s = { (c: CapturedContext?) in PromptBuilder().build(question: "q", context: c, history: [], hintMode: false).system }
    #expect(s(ctx([.windowImage(img1)])).hasSuffix(PromptBuilder.readingLineInstruction))
    #expect(s(ctx([.regionImage(img1)])).hasSuffix(PromptBuilder.readingLineInstruction))
    #expect(!s(ctx([.windowImage(img1), .math([MathSnippet(format: .latex, source: "x^2")])])).contains("Reading:"))
    #expect(!s(ctx([.pdfPages([RenderedPage(printedLabel: "231", pdfIndex: 246, image: img1, text: "t")])])).contains("Reading:"))
    #expect(!s(nil).contains("Reading:"))
    // hint + reading together: base, hint, reading in that order
}
@Test func youtubeContextIsExact() {
    let yt = YouTubeContext(videoId: "abc123XYZ00", title: "Solving Quadratics by Factoring", channel: "Math Channel", chapter: "Finding the roots",
                            playheadSeconds: 761, durationSeconds: 1450, transcriptStatus: .available,
                            transcript: [TranscriptSegment(start: 1, duration: 2, text: "FULL-TRANSCRIPT-ONLY")])
    let c = ctx([.windowImage(img1), .youtubeVideo(yt),
                 .transcriptWindow(segments: [TranscriptSegment(start: 575, duration: 6.2, text: "so now we factor the left side"),
                                              TranscriptSegment(start: 740.5, duration: 5, text: "x minus two times x minus three equals zero")], from: 581, to: 761),
                 .selectedText("x^2-5x+6=0")], front: dia("Solving Quadratics by Factoring - YouTube"))
    let m = PromptBuilder().build(question: "What are the roots?", context: c, history: [], hintMode: false).messages
    #expect(m == [LLMMessage(role: .user, content: [.image(img1), .text("""
    <context>
    App: Dia
    Window: Solving Quadratics by Factoring - YouTube

    Image 1: screenshot of the front window

    YouTube video: Solving Quadratics by Factoring
    Channel: Math Channel
    Chapter: Finding the roots
    Position: at 12:41 of 24:10

    Transcript from 9:41 to 12:41:
    [9:35] so now we factor the left side
    [12:20] x minus two times x minus three equals zero

    Selected text:
    x^2-5x+6=0
    </context>

    What are the roots?
    """)])])
}
@Test func webPageContextIsExact() {
    // front dia("Unit 4 Quiz Review"); items: .webPage(WebPageContext(url: "https://example-homework.test/unit4/q3", title: "Unit 4 Quiz Review",
    //   visibleText: "Question 3. Solve for x.", math: [MathSnippet(format: .latex, source: "IGNORED")])),
    //   .math([latex "x^2-5x+6=0", mathml "<math><mi>x</mi></math>"]), .focusedText("x = 2, 3"), .notice(.siteNotChecked); question "check my work"
    // → content == [.text("<context>\nApp: Dia\nWindow: Unit 4 Quiz Review\n\nWeb page: Unit 4 Quiz Review\nURL: https://example-homework.test/unit4/q3\nVisible text:\nQuestion 3. Solve for x.\n\nMath on the page (exact source):\n- LaTeX: x^2-5x+6=0\n- MathML: <math><mi>x</mi></math>\n\nScreen text:\nx = 2, 3\n\nNote: site not checked\n</context>\n\ncheck my work")]
}
@Test func pdfPagesImagesFirstInOrder() {
    // items: .pdfPages([("231", 246, img1, "Exercises 5.2"), ("232", 247, img2, "")]); question "explain pages 231-232"
    // → content == [.image(img1), .image(img2), .text("<context>\nBook page 231 (PDF page 247), image 1:\nExercises 5.2\n\nBook page 232 (PDF page 248), image 2:\n</context>\n\nexplain pages 231-232")]
}
@Test func regionImageLabel()           // ctx([.regionImage(img1)]) text contains "Image 1: screenshot of a selected screen region"
@Test func removedItemsAreAbsent()      // ctx with window image + selectedText("SECRET"); .removingItem(selection id) → no "SECRET", image still present
@Test func noContextSendsQuestionOnly() // context nil → messages == [LLMMessage(role: .user, content: [.text("q")])]
@Test func historyImagesReplacedAndOnlyNewTurnCarriesImages() {
    // history [user [.image(img1), .image(img2), .text("q1")], assistant [.text("a1")]]; new context with .windowImage(img2)
    // → messages[0].content == [.text("[image from an earlier turn omitted]"), .text("q1")]; messages[1] == assistant a1;
    //   messages[2].content.first == .image(img2); only messages[2] contains any .image
}
@Test func normalizesHistoryAfterFailedTurn() {
    // history [user [.text("q1")], assistant [.text("")], user [.text("q2")]], question "q3", context nil
    // → messages == [LLMMessage(role: .user, content: [.text("q1"), .text("q2"), .text("q3")])]
}
```

- [ ] **Step 2: Run** `swift test --filter CompanionLLMTests.PromptBuilderTests` → FAIL.
- [ ] **Step 3: Implement** `PromptBuilder` with the exact constants above and the serialization, history and normalization rules.
- [ ] **Step 4: Run** `swift test --filter CompanionLLMTests.PromptBuilderTests` → PASS.
- [ ] **Step 5: Commit** — `git add -A Sources/CompanionLLM Tests/CompanionLLMTests && git commit -m "feat(llm): prompt builder with context serialization, hint mode and Reading rule"`

---

### Task 10: Live time-to-first-token smoke test (opt-in)

**Files:**
- Test: `Tests/CompanionLLMTests/LiveSmokeTests.swift`

**Interfaces:**
- Consumes: `ProviderRegistry` (Task 6), `PromptBuilder` (Task 9), `FakeSecretStore`, `Fixtures.samplePNG` (TestSupport), `ModelCatalog.haiku45`.
- Produces: nothing (measurement only).

- [ ] **Step 1: Write the test**

```swift
@Test(.enabled(if: ProcessInfo.processInfo.environment["COMPANION_LIVE_ANTHROPIC_KEY"] != nil), .timeLimit(.minutes(1)))
func liveHaikuTimeToFirstToken() async throws {
    // registry = ProviderRegistry(secrets: FakeSecretStore([SecretKey.anthropicAPIKey: env key]), openAICompatibleBaseURL: { URL(string: "https://api.openai.com/v1")! })
    // provider = try registry.provider(for: ModelCatalog.haiku45); await provider.prewarm()
    // (system, messages) = PromptBuilder().build(question: "Reply with one short sentence: what is 2+2?",
    //     context: CapturedContext(front: nil, privacy: .allowed, kind: .genericWindow,
    //                              items: [ContextItem(piece: .windowImage(Fixtures.samplePNG(width: 1500, height: 1000)))], isComplete: true),
    //     history: [], hintMode: false)
    // start = ContinuousClock.now; stream LLMRequest(model: haiku45, system:, messages:, maxTokens: 128)
    // record elapsed at the first .textDelta; #expect(at least one .textDelta) and #expect(last event is .finished)
    // print("Haiku 4.5 time to first token: \(ms) ms (spec budget ≈ 1000–1500 ms)")
}
```

- [ ] **Step 2: Run without the key** — `swift test --filter CompanionLLMTests.LiveSmokeTests` → the test is reported as skipped, and the suite passes.
- [ ] **Step 3: Run with the key** (human or executor with a key, never committed) — `COMPANION_LIVE_ANTHROPIC_KEY=sk-ant-… swift test --filter CompanionLLMTests.LiveSmokeTests` → PASS, and the printed TTFT is recorded in the commit message body.
- [ ] **Step 4: Full suite** — `swift test --filter CompanionLLMTests` → all PASS (live test skipped).
- [ ] **Step 5: Commit** — `git add Tests/CompanionLLMTests/LiveSmokeTests.swift && git commit -m "test(llm): opt-in live Haiku 4.5 time-to-first-token smoke test"`

---

## Hand-off

`CompanionLLM` now exposes exactly the overview's WS1 API (`KeychainSecretStore`, `ModelRouter`, `PromptBuilder`, `ProviderRegistry` incl. `makeSession()`), plus `KeychainError`. Before merging: `git fetch && git rebase main && scripts/test-all.sh`. Then tell the human that WS1 is ready for WS7's M1 gate.
