import Foundation
import CryptoKit
import Testing
@testable import Chat

private final class AutoKeyStore: CredentialStore {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
    func delete() throws { data = nil }
}
private final class BundleWire: HTTPTransport, @unchecked Sendable {
    var request: URLRequest?
    var data = Data()
    func send(_ request: URLRequest) async throws -> HTTPResult { self.request = request; return HTTPResult(status: 200, data: data) }
}
private struct AutoExistingSession: DeviceSessionLookup {
    func hasSession(scope: String, local: UUID, remote: UUID) -> Bool { true }
}
@MainActor
struct AutomaticHandshakeTests {
    private struct Fixture {
        let coordinator: DeviceCoordinator
        let store: AutoKeyStore
        let sender = UUID()
        let friend: ChatUser
        let device: FriendDevice
        let bob: LocalDeviceKeys
        let opk: Data
        let bundle: DeviceKeyBundleResponse
        let claim: ClaimedPrekey
        func prepare() async throws -> InitialEnvelope {
            try #require(try await coordinator.prepareEnvelope(scope: "alice", sender: sender, friend: friend.id, device: device,
                fetchBundle: { bundle }, claim: { claim }))
        }
    }
    private func fixture() async throws -> Fixture {
        let store = AutoKeyStore()
        // Use the same archive across restart tests.
        let client = DeviceCoordinator(vault: DeviceKeyVault(store: store))
        try await client.register(scope: "alice", name: "A") { _ in RegisteredDevice(deviceId: UUID(), deviceStatus: "active") }
        let bob = try LocalDeviceKeys.generate(), request = try bob.registration(name: "B"), opk = try DeviceKeyCrypto.privateKey()
        let friend = ChatUser(id: UUID(), username: "bob", displayName: "Bob")
        let device = FriendDevice(deviceId: UUID(), deviceName: "B", status: "active", identityPublicKeyHex: request.identity_public_key_hex, protocolSuite: request.protocol_suite)
        return Fixture(coordinator: client, store: store, friend: friend, device: device, bob: bob, opk: opk,
            bundle: DeviceKeyBundleResponse(friendId: friend.id, deviceId: device.id, signedPrekeyId: 42,
                signedPrekeyPublicHex: request.signed_prekey_public_hex, signedPrekeySignatureHex: request.signed_prekey_signature_hex, isCurrent: true),
            claim: ClaimedPrekey(friendId: friend.id, deviceId: device.id, prekeyId: 1001, publicKeyHex: DeviceKeyCrypto.hex(try DeviceKeyCrypto.publicKey(opk))))
    }
    private func responderSecret(_ f: Fixture, _ envelope: InitialEnvelope) throws -> Data {
        func dh(_ secret: Data, _ hex: String) throws -> Data {
            let value = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secret).sharedSecretFromKeyAgreement(
                with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: PrekeyVerification.hex(hex, bytes: 32)))
            return value.withUnsafeBytes { Data($0) }
        }
        let h = envelope.header
        let parts = try [dh(f.bob.signedPrekeyPrivate, h.senderIdentityPublicHex), dh(f.bob.identityPrivate, h.senderEphemeralPublicHex),
                         dh(f.bob.signedPrekeyPrivate, h.senderEphemeralPublicHex), dh(f.opk, h.senderEphemeralPublicHex)]
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: parts.reduce(Data(repeating: 0xff, count: 32), +)),
            salt: Data(repeating: 0, count: 32), info: Data(h.handshakeKdf.utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }
    private func mustFail(_ action: () async throws -> Void) async {
        do { try await action(); Issue.record("Expected failure") } catch {}
    }
    @Test func orderedLoginPreparationAndBobDecryptsEnvelope() async throws {
        let f = try await fixture(), model = HandshakePreparation()
        var calls: [String] = []
        await model.run(coordinator: f.coordinator, scope: "alice", sender: f.sender,
            friends: { calls.append("friends"); return [f.friend] },
            devices: { id in #expect(id == f.friend.id); calls.append("devices"); return FriendDevicesResult(friendId: id, devices: [f.device]) },
            bundle: { _, _ in calls.append("bundle"); return f.bundle },
            claim: { _, _ in
                calls.append("prekey")
                let local = try f.coordinator.local("alice")
                #expect(local.claims.values.first?.bundle != nil) // bundle persisted BEFORE claim
                return f.claim
            })
        #expect(calls == ["friends", "devices", "bundle", "prekey"])
        let envelope = try #require(model.entries.first?.envelope)
        let secret = try responderSecret(f, envelope)
        #expect(String(decoding: try envelope.open(secret: secret), as: UTF8.self) == InitialEnvelope.testMessage)
        #expect(envelope.header.senderId == f.sender && envelope.header.recipientId == f.friend.id)
        let json = try envelope.json()
        #expect(!json.contains("private") && !json.contains("secret") && !json.contains(InitialEnvelope.testMessage))
        let restored = try JSONCodec.decoder().decode(InitialEnvelope.self, from: Data(json.utf8))
        #expect(restored == envelope)
    }
    @Test func customPlaintextProducesFreshAuthenticatedPackets() async throws {
        let f = try await fixture(), original = try await f.prepare()
        let secret = try responderSecret(f, original)
        let local = try f.coordinator.local("alice")
        let cached = try #require(try f.coordinator.cachedClaim(scope: "alice", friend: f.friend.id, device: f.device))
        let state = try #require(cached.check)
        let message = "新的加密消息 🔐"
        let new = try InitialEnvelope.make(secret: secret, sender: f.sender, local: local, friend: f.friend.id,
            device: f.device, state: state, claim: f.claim, plaintext: message)
        #expect(String(decoding: try new.open(secret: secret), as: UTF8.self) == message)
        #expect(new.header.messageId != original.header.messageId && new.nonceHex != original.nonceHex)
        #expect(new.header.saltHex != original.header.saltHex)
        #expect(!(try new.json()).contains(message))
    }
    @Test func cacheSurvivesRestartWithoutNetworkOrNonceChange() async throws {
        let f = try await fixture(), first = try await f.prepare()
        let restored = DeviceCoordinator(vault: DeviceKeyVault(store: f.store))
        let second = try await restored.prepareEnvelope(scope: "alice", sender: f.sender, friend: f.friend.id, device: f.device,
            fetchBundle: { Issue.record("Unexpected bundle"); return f.bundle }, claim: { Issue.record("Unexpected OPK claim"); return f.claim })
        #expect(first == second)
    }
    @Test func invalidSignatureDoesNotConsumeOPK() async throws {
        let f = try await fixture()
        let bad = DeviceKeyBundleResponse(friendId: f.friend.id, deviceId: f.device.id, signedPrekeyId: 42,
            signedPrekeyPublicHex: f.bundle.signedPrekeyPublicHex, signedPrekeySignatureHex: String(repeating: "00", count: 64), isCurrent: true)
        await mustFail { _ = try await f.coordinator.prepareEnvelope(scope: "alice", sender: f.sender, friend: f.friend.id, device: f.device,
            fetchBundle: { bad }, claim: { Issue.record("Invalid bundle consumed OPK"); return f.claim }) }
        #expect(try f.coordinator.local("alice").claims.isEmpty)
    }
    @Test func establishedSessionSkipsAllKeyRequests() async throws {
        let f = try await fixture(), coordinator = DeviceCoordinator(vault: DeviceKeyVault(store: f.store), sessions: AutoExistingSession())
        let envelope = try await coordinator.prepareEnvelope(scope: "alice", sender: f.sender, friend: f.friend.id, device: f.device,
            fetchBundle: { Issue.record("Unexpected bundle"); return f.bundle }, claim: { Issue.record("Unexpected claim"); return f.claim })
        #expect(envelope == nil)
    }
    @Test func failedDeviceDoesNotPreventOtherFriendsAndUnregisteredDoesNotClaim() async throws {
        let f = try await fixture(), model = HandshakePreparation()
        let other = ChatUser(id: UUID(), username: "other", displayName: "Other")
        await model.run(coordinator: f.coordinator, scope: "alice", sender: f.sender,
            friends: { [other, f.friend] },
            devices: { id in
                if id == other.id { throw APIError(status: 404, code: "device_unavailable", message: "unavailable") }
                return FriendDevicesResult(friendId: id, devices: [f.device])
            }, bundle: { _, _ in f.bundle }, claim: { _, _ in f.claim })
        #expect(model.entries.count == 2 && model.entries.last?.envelope != nil)
        await model.run(coordinator: f.coordinator, scope: "unregistered", sender: UUID(),
            friends: { Issue.record("Unregistered preparation"); return [] }, devices: { _ in throw URLError(.badURL) },
            bundle: { _, _ in throw URLError(.badURL) }, claim: { _, _ in throw URLError(.badURL) })
        #expect(model.entries.isEmpty && model.status.contains("尚未注册"))
    }
    @Test func tamperedAADAndCiphertextAreRejected() async throws {
        let f = try await fixture(), envelope = try await f.prepare(), secret = try responderSecret(f, envelope)
        var ciphertext = Data(base64Encoded: envelope.ciphertextBase64)!; ciphertext[0] ^= 1
        let bad = InitialEnvelope(header: envelope.header, aadBase64: envelope.aadBase64, nonceHex: envelope.nonceHex,
                                  ciphertextBase64: ciphertext.base64EncodedString(), tagHex: envelope.tagHex)
        await mustFail { _ = try bad.open(secret: secret) }
        var aad = try JSONSerialization.jsonObject(with: Data(base64Encoded: envelope.aadBase64)!) as! [String: Any]
        aad["recipient_id"] = UUID().uuidString
        let changed = InitialEnvelope(header: envelope.header, aadBase64: try JSONSerialization.data(withJSONObject: aad).base64EncodedString(),
            nonceHex: envelope.nonceHex, ciphertextBase64: envelope.ciphertextBase64, tagHex: envelope.tagHex)
        await mustFail { _ = try changed.open(secret: secret) }
        await mustFail { _ = try envelope.open(secret: Data(repeating: 0, count: 32)) }
    }
    @Test func bundleHTTPContractUsesNumericIDAndBearer() async throws {
        let f = try await fixture(), wire = BundleWire()
        wire.data = try JSONSerialization.data(withJSONObject: ["friend_id": f.friend.id.uuidString, "device_id": f.device.id.uuidString,
            "signed_prekey_id": 42, "signed_prekey_public_hex": f.bundle.signedPrekeyPublicHex,
            "signed_prekey_signature_hex": f.bundle.signedPrekeySignatureHex, "is_current": true])
        let repo = RemoteDeviceRepository(api: APIClient(configuration: ServerConfiguration(), transport: wire, legacyTransport: wire))
        let result = try await repo.bundle(friend: f.friend.id, device: f.device.id, token: "test-token")
        #expect(result.signedPrekeyId == 42)
        #expect(try result.material(friend: f.friend.id, device: f.device).signedPrekeyId == "42")
        #expect(wire.request?.url?.path == "/get_device_key_bundle" && wire.request?.httpMethod == "POST")
        #expect(wire.request?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        let body = try JSONSerialization.jsonObject(with: wire.request!.httpBody!) as! [String: String]
        #expect(body["target_user_id"] == f.friend.id.uuidString.lowercased() && body["device_id"] == f.device.id.uuidString.lowercased())
    }
    @Test func resetDuringFetchDiscardsOldAccountResults() async throws {
        let f = try await fixture(), model = HandshakePreparation()
        await model.run(coordinator: f.coordinator, scope: "alice", sender: f.sender,
            friends: { model.reset(); return [f.friend] }, devices: { _ in Issue.record("Stale account continued"); throw URLError(.cancelled) },
            bundle: { _, _ in f.bundle }, claim: { _, _ in f.claim })
        #expect(model.entries.isEmpty && !model.isRunning)
    }
}
