import Foundation

public enum BridgeConstants {
    public static let protocolVersion = 1
    public static let ports: [UInt16] = [47823, 47824, 47825, 47826, 47827]
    public static let maxChunkBytes = 1_048_576
    public static let helloTimeout: Duration = .seconds(5)
    public static let hotPathTimeout: Duration = .milliseconds(300)
    public static let pingInterval: Duration = .seconds(20)
    public static let drivePdfTimeout: Duration = .seconds(120)
    public static let viewerRequestTimeout: Duration = .seconds(10)
    public static let closeCodeUnauthorized: UInt16 = 4001
    public static let closeCodeVersionMismatch: UInt16 = 4002
}

public enum BridgeErrorCode: String, Codable, Sendable {
    case notConnected, notFound, downloadBlocked, notPdf, noViewer, timeout, blocked, unauthorized, versionMismatch, `internal`
}

public struct BridgeError: Error, Codable, Sendable, Equatable {
    public var code: BridgeErrorCode
    public var message: String

    public init(code: BridgeErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct HelloMessage: Codable, Sendable, Equatable {
    public var token: String
    public var extensionVersion: String
    public var browserName: String

    public init(token: String, extensionVersion: String, browserName: String) {
        self.token = token
        self.extensionVersion = extensionVersion
        self.browserName = browserName
    }
}

public struct TabActivatedMessage: Codable, Sendable, Equatable {
    public var tabId: Int
    public var windowId: Int
    public var url: String
    public var title: String

    public init(tabId: Int, windowId: Int, url: String, title: String) {
        self.tabId = tabId
        self.windowId = windowId
        self.url = url
        self.title = title
    }
}

public struct YouTubePlayheadMessage: Codable, Sendable, Equatable {
    public var tabId: Int
    public var videoId: String
    public var playheadSeconds: Double
    public var chapter: String?

    public init(tabId: Int, videoId: String, playheadSeconds: Double, chapter: String?) {
        self.tabId = tabId
        self.videoId = videoId
        self.playheadSeconds = playheadSeconds
        self.chapter = chapter
    }
}

public struct ProgressMessage: Codable, Sendable, Equatable {
    public var id: String
    public var step: String

    public init(id: String, step: String) {
        self.id = id
        self.step = step
    }
}

public struct BridgeResponse: Codable, Sendable, Equatable {
    public var id: String
    public var ok: Bool
    public var result: JSONValue?
    public var error: BridgeError?

    public init(id: String, ok: Bool, result: JSONValue?, error: BridgeError?) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
    }

    /// A missing or `null` result decodes as JSON `null`.
    public func decodeResult<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(result ?? .null))
    }
}

// MARK: - Envelope

private enum EnvelopeKey: String, CodingKey {
    case v, type, context, tabId, appVersion, blocklist
}

/// Checks `v` before anything else, so a future version never fails as an unknown `type`.
private func decodeEnvelopeType(from decoder: any Decoder) throws -> String {
    let container = try decoder.container(keyedBy: EnvelopeKey.self)
    let version = try container.decode(Int.self, forKey: .v)
    guard version == BridgeConstants.protocolVersion else {
        throw BridgeError(code: .versionMismatch, message: "Unsupported protocol version \(version)")
    }
    return try container.decode(String.self, forKey: .type)
}

private func encodeEnvelope(type: String, to encoder: any Encoder) throws -> KeyedEncodingContainer<EnvelopeKey> {
    var container = encoder.container(keyedBy: EnvelopeKey.self)
    try container.encode(BridgeConstants.protocolVersion, forKey: .v)
    try container.encode(type, forKey: .type)
    return container
}

private func unknownType(_ type: String, in decoder: any Decoder) -> DecodingError {
    .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown message type \(type)"))
}

// MARK: - Extension → app

public enum ExtensionToApp: Codable, Sendable, Equatable {
    case hello(HelloMessage)
    case tabActivated(TabActivatedMessage)
    case tabContext(TabContext)
    case youtubePlayhead(YouTubePlayheadMessage)
    case tabClosed(tabId: Int)
    case response(BridgeResponse)
    case progress(ProgressMessage)

    public init(from decoder: any Decoder) throws {
        let type = try decodeEnvelopeType(from: decoder)
        let container = try decoder.container(keyedBy: EnvelopeKey.self)
        switch type {
        case "hello": self = .hello(try HelloMessage(from: decoder))
        case "tabActivated": self = .tabActivated(try TabActivatedMessage(from: decoder))
        case "tabContext": self = .tabContext(try container.decode(TabContext.self, forKey: .context))
        case "youtubePlayhead": self = .youtubePlayhead(try YouTubePlayheadMessage(from: decoder))
        case "tabClosed": self = .tabClosed(tabId: try container.decode(Int.self, forKey: .tabId))
        case "response": self = .response(try BridgeResponse(from: decoder))
        case "progress": self = .progress(try ProgressMessage(from: decoder))
        default: throw unknownType(type, in: decoder)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .hello(let message):
            _ = try encodeEnvelope(type: "hello", to: encoder)
            try message.encode(to: encoder)
        case .tabActivated(let message):
            _ = try encodeEnvelope(type: "tabActivated", to: encoder)
            try message.encode(to: encoder)
        case .tabContext(let context):
            var container = try encodeEnvelope(type: "tabContext", to: encoder)
            try container.encode(context, forKey: .context)
        case .youtubePlayhead(let message):
            _ = try encodeEnvelope(type: "youtubePlayhead", to: encoder)
            try message.encode(to: encoder)
        case .tabClosed(let tabId):
            var container = try encodeEnvelope(type: "tabClosed", to: encoder)
            try container.encode(tabId, forKey: .tabId)
        case .response(let response):
            _ = try encodeEnvelope(type: "response", to: encoder)
            try response.encode(to: encoder)
        case .progress(let message):
            _ = try encodeEnvelope(type: "progress", to: encoder)
            try message.encode(to: encoder)
        }
    }
}

// MARK: - App → extension

public enum BridgeRequest: Codable, Sendable, Equatable {
    case getTabContext(id: String, tabId: Int?)
    case fetchDrivePdf(id: String, fileId: String)
    case viewerInfo(id: String, tabId: Int)
    case viewerCapturePage(id: String, tabId: Int, pageIndex: Int)
    case viewerRestore(id: String, tabId: Int, pageIndex: Int)

    public var id: String {
        switch self {
        case .getTabContext(let id, _), .fetchDrivePdf(let id, _), .viewerInfo(let id, _),
             .viewerCapturePage(let id, _, _), .viewerRestore(let id, _, _):
            id
        }
    }

    public var method: String {
        switch self {
        case .getTabContext: "getTabContext"
        case .fetchDrivePdf: "fetchDrivePdf"
        case .viewerInfo: "viewerInfo"
        case .viewerCapturePage: "viewerCapturePage"
        case .viewerRestore: "viewerRestore"
        }
    }

    private enum CodingKeys: String, CodingKey { case id, method, params }
    private enum ParamKeys: String, CodingKey { case tabId, fileId, pageIndex }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let method = try container.decode(String.self, forKey: .method)
        let params = try container.nestedContainer(keyedBy: ParamKeys.self, forKey: .params)
        switch method {
        case "getTabContext":
            self = .getTabContext(id: id, tabId: try params.decodeIfPresent(Int.self, forKey: .tabId))
        case "fetchDrivePdf":
            self = .fetchDrivePdf(id: id, fileId: try params.decode(String.self, forKey: .fileId))
        case "viewerInfo":
            self = .viewerInfo(id: id, tabId: try params.decode(Int.self, forKey: .tabId))
        case "viewerCapturePage":
            self = .viewerCapturePage(id: id, tabId: try params.decode(Int.self, forKey: .tabId),
                                      pageIndex: try params.decode(Int.self, forKey: .pageIndex))
        case "viewerRestore":
            self = .viewerRestore(id: id, tabId: try params.decode(Int.self, forKey: .tabId),
                                  pageIndex: try params.decode(Int.self, forKey: .pageIndex))
        default:
            throw DecodingError.dataCorruptedError(forKey: .method, in: container, debugDescription: "Unknown method \(method)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        var params = container.nestedContainer(keyedBy: ParamKeys.self, forKey: .params)
        switch self {
        case .getTabContext(_, let tabId):
            // An absent tab is an explicit `null` on the wire, not a missing key.
            if let tabId { try params.encode(tabId, forKey: .tabId) } else { try params.encodeNil(forKey: .tabId) }
        case .fetchDrivePdf(_, let fileId):
            try params.encode(fileId, forKey: .fileId)
        case .viewerInfo(_, let tabId):
            try params.encode(tabId, forKey: .tabId)
        case .viewerCapturePage(_, let tabId, let pageIndex), .viewerRestore(_, let tabId, let pageIndex):
            try params.encode(tabId, forKey: .tabId)
            try params.encode(pageIndex, forKey: .pageIndex)
        }
    }
}

public enum AppToExtension: Codable, Sendable, Equatable {
    case helloAck(appVersion: String)
    case config(blocklist: BlocklistConfig)
    case request(BridgeRequest)
    case ping

    public init(from decoder: any Decoder) throws {
        let type = try decodeEnvelopeType(from: decoder)
        let container = try decoder.container(keyedBy: EnvelopeKey.self)
        switch type {
        case "helloAck": self = .helloAck(appVersion: try container.decode(String.self, forKey: .appVersion))
        case "config": self = .config(blocklist: try container.decode(BlocklistConfig.self, forKey: .blocklist))
        case "request": self = .request(try BridgeRequest(from: decoder))
        case "ping": self = .ping
        default: throw unknownType(type, in: decoder)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .helloAck(let appVersion):
            var container = try encodeEnvelope(type: "helloAck", to: encoder)
            try container.encode(appVersion, forKey: .appVersion)
        case .config(let blocklist):
            var container = try encodeEnvelope(type: "config", to: encoder)
            try container.encode(blocklist, forKey: .blocklist)
        case .request(let request):
            _ = try encodeEnvelope(type: "request", to: encoder)
            try request.encode(to: encoder)
        case .ping:
            _ = try encodeEnvelope(type: "ping", to: encoder)
        }
    }
}

// MARK: - Results

public struct TabContextResult: Codable, Sendable, Equatable {
    public var context: TabContext?

    public init(context: TabContext?) {
        self.context = context
    }
}

public struct DrivePdfResult: Codable, Sendable, Equatable {
    public var fileId: String
    public var title: String
    public var byteLength: Int

    public init(fileId: String, title: String, byteLength: Int) {
        self.fileId = fileId
        self.title = title
        self.byteLength = byteLength
    }
}

public struct ViewerPageResult: Codable, Sendable, Equatable {
    public var pageIndex: Int
    public var pngBase64: String

    public init(pageIndex: Int, pngBase64: String) {
        self.pageIndex = pageIndex
        self.pngBase64 = pngBase64
    }
}

/// Decodes from `{}` or `null`.
public struct EmptyResult: Codable, Sendable, Equatable {
    public init() {}
    public init(from decoder: any Decoder) throws {}
    public func encode(to encoder: any Encoder) throws {
        _ = encoder.container(keyedBy: EmptyKeys.self)
    }
    private enum EmptyKeys: CodingKey {}
}

// MARK: - Binary frames

public struct BinaryFrameHeader: Codable, Sendable, Equatable {
    public var id: String
    public var seq: Int
    public var last: Bool

    public init(id: String, seq: Int, last: Bool) {
        self.id = id
        self.seq = seq
        self.last = last
    }
}

/// 4-byte big-endian header length N, N bytes of UTF-8 JSON `BinaryFrameHeader`, then the payload.
public enum BinaryFrame {
    private static let lengthPrefixBytes = 4

    public static func encode(header: BinaryFrameHeader, payload: Data) throws -> Data {
        try checkSize(payload.count)
        let headerData = try JSONEncoder().encode(header)
        var frame = Data(capacity: lengthPrefixBytes + headerData.count + payload.count)
        withUnsafeBytes(of: UInt32(headerData.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(headerData)
        frame.append(payload)
        return frame
    }

    public static func decode(_ frame: Data) throws -> (header: BinaryFrameHeader, payload: Data) {
        guard frame.count >= lengthPrefixBytes else { throw malformed("Binary frame shorter than its length prefix") }
        let headerLength = frame.prefix(lengthPrefixBytes).reduce(0) { $0 << 8 | Int($1) }
        guard headerLength <= frame.count - lengthPrefixBytes else { throw malformed("Binary frame header is truncated") }

        let headerStart = frame.startIndex + lengthPrefixBytes
        let payloadStart = headerStart + headerLength
        let header: BinaryFrameHeader
        do {
            header = try JSONDecoder().decode(BinaryFrameHeader.self, from: frame[headerStart..<payloadStart])
        } catch {
            throw malformed("Binary frame header is not valid JSON")
        }
        let payload = Data(frame[payloadStart...])
        try checkSize(payload.count)
        return (header, payload)
    }

    private static func checkSize(_ count: Int) throws {
        guard count <= BridgeConstants.maxChunkBytes else {
            throw malformed("Binary chunk of \(count) bytes exceeds \(BridgeConstants.maxChunkBytes)")
        }
    }

    private static func malformed(_ message: String) -> BridgeError {
        BridgeError(code: .internal, message: message)
    }
}
