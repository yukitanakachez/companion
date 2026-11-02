import CompanionCore
import CompanionTestSupport
import Testing
@testable import CompanionBridge

@Suite struct BridgePairingTests {
    @Test func tokenIsCreatedOnceAndStored() throws {
        let store = FakeSecretStore()
        let t = try BridgePairing.token(in: store)
        #expect(t.count == 64 && t.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(store.secret(for: SecretKey.bridgeToken) == t)
        #expect(try BridgePairing.token(in: store) == t)
    }
    @Test func existingTokenIsReturnedUnchanged() throws {
        let existing = String(repeating: "ab", count: 32)
        #expect(try BridgePairing.token(in: FakeSecretStore([SecretKey.bridgeToken: existing])) == existing)
    }
    @Test func regenerateReplacesStoredToken() throws {
        let store = FakeSecretStore()
        let old = try BridgePairing.token(in: store)
        let new = try BridgePairing.regenerate(in: store)
        #expect(new != old && new.count == 64)
        #expect(store.secret(for: SecretKey.bridgeToken) == new)
    }
    @Test func tokensAreRandom() throws { #expect(try BridgePairing.makeToken() != (try BridgePairing.makeToken())) }
}
