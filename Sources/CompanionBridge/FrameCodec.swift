import CompanionCore
import Foundation

enum FrameCodec {
    private struct VersionProbe: Decodable { let v: Int }

    /// UTF-8 JSON for one text frame.
    static func encode(_ message: AppToExtension) throws -> Data {
        try JSONEncoder().encode(message)
    }

    /// Checks `v` before anything else, so a future version never fails as an unknown or malformed message.
    static func decodeText(_ data: Data) throws -> ExtensionToApp {
        let decoder = JSONDecoder()
        let version = try decoder.decode(VersionProbe.self, from: data).v
        guard version == BridgeConstants.protocolVersion else {
            throw BridgeError(code: .versionMismatch, message: "Unsupported protocol version \(version)")
        }
        return try decoder.decode(ExtensionToApp.self, from: data)
    }
}
