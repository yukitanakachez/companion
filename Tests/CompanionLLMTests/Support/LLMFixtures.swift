@testable import CompanionLLM
import CompanionCore
import Foundation

enum LLMFixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    static func events(_ name: String) throws -> [SSEEvent] {
        var parser = SSEParser()
        return try parser.feed(data(name)) + parser.finish()
    }
}

/// Runs a decoder over a fixture, stopping at the first throw, and calls `finish()` if it is not done.
func decodeAll<D: StreamDecoding>(_ fixture: String, with initial: D) throws -> (events: [LLMStreamEvent], error: (any Error)?) {
    var decoder = initial
    var events: [LLMStreamEvent] = []
    do {
        for event in try LLMFixture.events(fixture) { events += try decoder.decode(event) }
        if !decoder.isDone { events += try decoder.finish() }
        return (events, nil)
    } catch {
        return (events, error)
    }
}
