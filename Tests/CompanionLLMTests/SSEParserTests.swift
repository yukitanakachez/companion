@testable import CompanionLLM
import Testing

private func parse(_ chunks: [String]) -> [SSEEvent] {
    var parser = SSEParser()
    var events: [SSEEvent] = []
    for chunk in chunks { events += parser.feed(Array(chunk.utf8)) }
    return events + parser.finish()
}

struct SSEParserTests {
    @Test func namedEvent() {
        #expect(parse(["event: message_start\ndata: {\"a\":1}\n\n"]) == [SSEEvent(event: "message_start", data: "{\"a\":1}")])
    }
    @Test func multiLineDataJoinedWithNewline() {
        #expect(parse(["data: one\ndata: two\n\n"]) == [SSEEvent(event: nil, data: "one\ntwo")])
    }
    @Test(arguments: ["\r\n", "\r", "\n"]) func anyLineTerminator(_ t: String) {
        #expect(parse(["event: e\(t)data: x\(t)\(t)"]) == [SSEEvent(event: "e", data: "x")])
    }
    @Test func crlfSplitAcrossChunks() {
        #expect(parse(["data: a\r", "\n\r", "\n"]) == [SSEEvent(event: nil, data: "a")])
    }
    @Test func commentsAndUnknownFieldsIgnored() {
        #expect(parse([": keep-alive\nretry: 100\nid: 7\nfoo\ndata: x\n\n"]) == [SSEEvent(event: nil, data: "x")])
    }
    @Test func onlyOneLeadingSpaceStripped() {
        #expect(parse(["data:  two\n\ndata:x\n\n"]) == [SSEEvent(event: nil, data: " two"), SSEEvent(event: nil, data: "x")])
    }
    @Test func blankLineWithoutDataDispatchesNothingAndResetsName() {
        #expect(parse(["event: ping\n\ndata: y\n\n"]) == [SSEEvent(event: nil, data: "y")])
    }
    @Test func emptyDataHeartbeatDispatchesNothing() {
        #expect(parse(["data: \n\ndata:\n\ndata: y\n\n"]) == [SSEEvent(event: nil, data: "y")])
    }
    @Test func multibyteUTF8SplitAcrossChunks() {
        let bytes = Array("data: café ∑\n\n".utf8)
        var p = SSEParser()
        let split = bytes.firstIndex(of: 0xC3)! + 1                 // inside "é"
        let events = p.feed(bytes[..<split]) + p.feed(bytes[split...]) + p.finish()
        #expect(events == [SSEEvent(event: nil, data: "café ∑")])
    }
    @Test func byteAtATimeMatchesWholeFeed() {
        let stream = "event: a\ndata: 1\n\n: c\r\nevent: b\r\ndata: 2\r\ndata: 3\r\n\r\ndata: [DONE]\n\n"
        var p = SSEParser()
        var oneByOne: [SSEEvent] = []
        for b in stream.utf8 { oneByOne += p.feed(CollectionOfOne(b)) }
        #expect(oneByOne + p.finish() == parse([stream]))
        #expect(parse([stream]).count == 3)
    }
    @Test func finishDispatchesPendingCompleteLinesAndDropsPartialLine() {
        #expect(parse(["data: [DONE]\n"]) == [SSEEvent(event: nil, data: "[DONE]")])
        #expect(parse(["data: {\"type\":\"content_bl"]) == [])
    }
}
