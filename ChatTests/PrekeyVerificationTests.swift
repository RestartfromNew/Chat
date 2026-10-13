import Foundation
import CryptoKit
import Testing
@testable import Chat

private final class PrekeyCheckStore: CredentialStore {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
    func delete() throws { data = nil }
}

@MainActor
struct PrekeyVerificationTests {
    private struct Fixture {
        let coordinator: DeviceCoordinator
        let store: PrekeyCheckStore
        let peer: LocalDeviceKeys
        let opk: Data
        let friend: UUID
        let device: FriendDevice
        let json: String
    }
    private func fixture(claim: Bool = true) async throws -> Fixture {
        let store = PrekeyCheckStore(), peer = try LocalDeviceKeys.generate(), opk = try DeviceKeyCrypto.privateKey()
        let coordinator = DeviceCoordinator(vault: DeviceKeyVault(store: store)), friend = UUID()
        try await coordinator.register(scope: "alice", name: "phone") { _ in RegisteredDevice(deviceId: UUID(), deviceStatus: "active") }
        let request = try peer.registration(name: "Bob phone")
        let device = FriendDevice(deviceId: UUID(), deviceName: "Bob phone", status: "active",
                                  identityPublicKeyHex: request.identity_public_key_hex, protocolSuite: request.protocol_suite)
        if claim {
            _ = try await coordinator.prepare(scope: "alice", friend: friend, device: device) {
                ClaimedPrekey(friendId: friend, deviceId: device.id, prekeyId: 1001,
                    publicKeyHex: DeviceKeyCrypto.hex(try DeviceKeyCrypto.publicKey(opk)))
            }
        }
        return Fixture(coordinator: coordinator, store: store, peer: peer, opk: opk, friend: friend, device: device,
            json: String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
    }
    private func mustFail(_ action: () throws -> Void) {
        do { try action(); Issue.record("Expected rejection") } catch {}
    }
    @Test func signedBundleGeneratesMatchingResponderSecret() async throws {
        let f = try await fixture()
        let result = try f.coordinator.verifyPrekey(scope: "alice", friend: f.friend, device: f.device, json: f.json)
        let local = try f.coordinator.local("alice")
        let cached = try #require(try f.coordinator.cachedClaim(scope: "alice", friend: f.friend, device: f.device))
        let state = try #require(cached.check)
        func dh(_ privateKey: Data, _ publicKey: Data) throws -> Data {
            let secret = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey).sharedSecretFromKeyAgreement(
                with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey))
            return secret.withUnsafeBytes { Data($0) }
        }
        let ephemeral = try DeviceKeyCrypto.publicKey(state.ephemeralPrivate)
        let d1 = try dh(f.peer.signedPrekeyPrivate, DeviceKeyCrypto.publicKey(local.identityPrivate))
        let d2 = try dh(f.peer.identityPrivate, ephemeral)
        let d3 = try dh(f.peer.signedPrekeyPrivate, ephemeral)
        let d4 = try dh(f.opk, ephemeral)
        let secret = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(repeating: 0xff, count: 32) + d1 + d2 + d3 + d4),
            salt: Data(repeating: 0, count: 32), info: Data("Example-X3DH-Core-v1".utf8), outputByteCount: 32)
        let expected = secret.withUnsafeBytes { Data($0) }
        #expect(result.secretFingerprint == DeviceKeyCrypto.hex(Data(SHA256.hash(data: expected))))
        #if DEBUG
        #expect(result.secretHex == DeviceKeyCrypto.hex(expected))
        #endif
        #expect(result.prekeyID == 1001 && result.signedPrekeyID == "42")
    }
    @Test func documentSVector() throws {
        func bytes(_ value: String) throws -> Data { try PrekeyVerification.hex(value, bytes: 32) }
        let ai = try bytes("60860237e15f8f85adc80ec7723a6f0bf2601ac49234a1150c1154236fdab57e")
        let ae = try bytes("d09ea7e07d773d633232c017815e5d1fdfd5290a4fb81fb16db95a89505c6862")
        let bi = try bytes("a8f7c99c020a1a16e7237755fa6f73d711c4c22a864359cc4eb369e86c56b67d")
        let bs = try bytes("901893ba90df1299fbc4a80368837f57b11b7b70a281aa80a215ef83319aca4b")
        let bo = try bytes("50f8142c6b9539453a518f70cad9630eb05bd842f27001143439f22156071b5c")
        let secret = try PrekeyVerification.derive(identity: ai, ephemeral: ae, remoteIdentity: DeviceKeyCrypto.publicKey(bi),
            signedPrekey: DeviceKeyCrypto.publicKey(bs), oneTimePrekey: DeviceKeyCrypto.publicKey(bo))
        #expect(DeviceKeyCrypto.hex(secret) == "861134e2187bc12887e6d47325a8666f86282ce8984428afc2669e7458c82a56")
    }
    @Test func restartKeepsEphemeralAndSecret() async throws {
        let f = try await fixture()
        let first = try f.coordinator.verifyPrekey(scope: "alice", friend: f.friend, device: f.device, json: f.json)
        let restored = DeviceCoordinator(vault: DeviceKeyVault(store: f.store))
        let reloaded = try #require(try restored.verificationResult(scope: "alice", friend: f.friend, device: f.device))
        let repeated = try restored.verifyPrekey(scope: "alice", friend: f.friend, device: f.device, json: f.json)
        #expect(first.secretFingerprint == reloaded.secretFingerprint && first.secretFingerprint == repeated.secretFingerprint)
        #expect(first.ephemeralPublicHex == repeated.ephemeralPublicHex)
    }
    @Test func rejectsTamperingAndWrongPeerWithoutSavingState() async throws {
        let f = try await fixture()
        var body = try JSONSerialization.jsonObject(with: Data(f.json.utf8)) as! [String: Any]
        body["signed_prekey_signature_hex"] = String(repeating: "00", count: 64)
        let bad = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        mustFail { _ = try f.coordinator.verifyPrekey(scope: "alice", friend: f.friend, device: f.device, json: bad) }
        #expect(try f.coordinator.cachedClaim(scope: "alice", friend: f.friend, device: f.device)?.check == nil)
        let other = try LocalDeviceKeys.generate().registration(name: "Other")
        let otherJSON = String(decoding: try JSONEncoder().encode(other), as: UTF8.self)
        mustFail { _ = try f.coordinator.verifyPrekey(scope: "alice", friend: f.friend, device: f.device, json: otherJSON) }
    }
    @Test func cannotDeriveWithoutOPKOrWithInvalidBundle() async throws {
        let f = try await fixture(claim: false)
        #expect(try f.coordinator.verificationResult(scope: "alice", friend: f.friend, device: f.device) == nil)
        mustFail { _ = try f.coordinator.verifyPrekey(scope: "alice", friend: f.friend, device: f.device, json: f.json) }
        mustFail { _ = try SignedPrekeyMaterial.parse("{}") }
        mustFail { _ = try PrekeyVerification.hex(String(repeating: "xx", count: 32), bytes: 32) }
    }
    @Test func oldCacheStillDecodesAndBusyOperationBlocksVerification() async throws {
        let f = try await fixture()
        // Persisted before this feature: no `check` member.
        let original = try #require(f.store.data)
        let text = String(decoding: original, as: UTF8.self)
        #expect(!text.contains("ephemeralPrivate"))
        #expect(try f.coordinator.cachedClaim(scope: "alice", friend: f.friend, device: f.device)?.value != nil)
        try f.coordinator.begin("alice"); defer { f.coordinator.end("alice") }
        mustFail { _ = try f.coordinator.verifyPrekey(scope: "alice", friend: f.friend, device: f.device, json: f.json) }
        #expect(try f.coordinator.cachedClaim(scope: "alice", friend: f.friend, device: f.device)?.check == nil)
    }
}
