import CompanionCore
import Foundation
import Security

public enum BridgePairing {
    /// Returns the stored token, creating and storing one if none exists.
    public static func token(in secrets: any SecretStoring) throws -> String {
        if let existing = secrets.secret(for: SecretKey.bridgeToken), !existing.isEmpty { return existing }
        return try regenerate(in: secrets)
    }

    /// Always makes, stores and returns a new token. Open connections stay authenticated.
    public static func regenerate(in secrets: any SecretStoring) throws -> String {
        let token = try makeToken()
        do {
            try secrets.setSecret(token, for: SecretKey.bridgeToken)
        } catch let error as BridgeError {
            throw error
        } catch {
            throw BridgeError(code: .internal, message: "Couldn't store the pairing token: \(error.localizedDescription)")
        }
        return token
    }

    /// 32 random bytes as 64 lowercase hex characters.
    static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw BridgeError(code: .internal, message: "SecRandomCopyBytes failed (\(status))")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
