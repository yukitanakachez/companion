/// One dispatched server-sent event. `event` is nil for unnamed events.
struct SSEEvent: Equatable, Sendable {
    var event: String?
    var data: String
}

/// Incremental WHATWG server-sent-events parser. Accepts bytes split at any boundary:
/// mid-line, mid-UTF-8 character, or between the CR and LF of one terminator.
struct SSEParser: Sendable {
    private static let lf = UInt8(ascii: "\n")
    private static let cr = UInt8(ascii: "\r")
    private static let colon = UInt8(ascii: ":")
    private static let space = UInt8(ascii: " ")

    private var line: [UInt8] = []
    private var data = ""
    private var hasData = false
    private var eventName: String?
    private var skipNextLF = false

    init() {}

    mutating func feed<S: Sequence>(_ bytes: S) -> [SSEEvent] where S.Element == UInt8 {
        var events: [SSEEvent] = []
        for byte in bytes {
            if skipNextLF {
                skipNextLF = false
                if byte == Self.lf { continue }
            }
            if byte == Self.lf || byte == Self.cr {
                skipNextLF = byte == Self.cr
                if let event = processLine() { events.append(event) }
            } else {
                line.append(byte)
            }
        }
        return events
    }

    /// Discards an unterminated last line, then dispatches any pending event that has data.
    mutating func finish() -> [SSEEvent] {
        line.removeAll()
        skipNextLF = false
        guard let event = dispatch() else { return [] }
        return [event]
    }

    private mutating func processLine() -> SSEEvent? {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty { return dispatch() }
        if line[0] == Self.colon { return nil }

        let fieldEnd = line.firstIndex(of: Self.colon) ?? line.endIndex
        var valueStart = min(fieldEnd + 1, line.endIndex)
        if valueStart < line.endIndex, line[valueStart] == Self.space { valueStart += 1 }

        let value = String(decoding: line[valueStart...], as: UTF8.self)
        switch String(decoding: line[..<fieldEnd], as: UTF8.self) {
        case "data":
            if hasData { data += "\n" }
            data += value
            hasData = true
        case "event":
            eventName = value
        default:
            break
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            data = ""
            hasData = false
            eventName = nil
        }
        guard hasData else { return nil }
        return SSEEvent(event: eventName, data: data)
    }
}
