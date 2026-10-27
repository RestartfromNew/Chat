import Foundation
import CryptoKit
import CXEdDSA
import Testing
@testable import Chat

private final class DeviceMemoryStore: CredentialStore {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
    func delete() throws { data = nil }
}
private struct ExistingDeviceSession: DeviceSessionLookup {
    func hasSession(scope: String, local: UUID, remote: UUID) -> Bool { true }
}
private final class DeviceWire: HTTPTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    var response = Data()
    var status = 201
    func send(_ request: URLRequest) async throws -> HTTPResult {
        requests.append(request); return HTTPResult(status: status, data: response)
    }
}
@MainActor
struct DeviceTests {
    private func pair() -> (DeviceCoordinator, DeviceMemoryStore) {
        let store = DeviceMemoryStore(); return (DeviceCoordinator(vault: DeviceKeyVault(store: store)), store)
    }
    private func registered(_ coordinator: DeviceCoordinator) async throws {
        try await coordinator.register(scope: "alice", name: "iPhone") { _ in RegisteredDevice(deviceId: UUID(), deviceStatus: "active") }
    }
    private func peer() throws -> FriendDevice {
        FriendDevice(deviceId: UUID(), deviceName: "Bob", status: "active", identityPublicKeyHex: DeviceKeyCrypto.hex(try DeviceKeyCrypto.publicKey(DeviceKeyCrypto.privateKey())), protocolSuite: DeviceKeyCrypto.suite)
    }
    private func mustFail(_ action: () async throws -> Void) async {
        do { try await action(); Issue.record("Expected failure") } catch {}
    }
    @Test func signatureAndPublicWireFormat() throws {
        let record = try LocalDeviceKeys.generate(), body = try record.registration(name: "iPhone")
        #expect(record.oneTimePrekeys.isEmpty)
        #expect(body.identity_public_key_hex.count == 64)
        #expect(body.signed_prekey_public_hex.count == 64)
        #expect(body.signed_prekey_signature_hex.count == 128)
        let publicKey = try DeviceKeyCrypto.publicKey(record.signedPrekeyPrivate)
        #expect(DeviceKeyCrypto.verify(signature: record.signature, prekey: publicKey, identity: try DeviceKeyCrypto.publicKey(record.identityPrivate)))
        var altered = record.signature; altered[0] ^= 1
        #expect(!DeviceKeyCrypto.verify(signature: altered, prekey: publicKey, identity: try DeviceKeyCrypto.publicKey(record.identityPrivate)))
        #expect(!DeviceKeyCrypto.validPublicHex(String(repeating: "00", count: 32)))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as! [String: Any]
        #expect(json["signed_prekey_id"] as? String == "42")
        #expect(json["identityPrivate"] == nil)
    }
    @Test func upstreamXEdDSAKnownVector() throws {
        var secret = [UInt8](repeating: 0, count: 32); secret[8] = 189; secret[31] = 64
        let message = [UInt8](repeating: 0, count: 200), random = [UInt8](repeating: 0, count: 64)
        var signature = [UInt8](repeating: 0, count: 64)
        #expect(xed25519_sign(&signature, secret, message, 200, random) == 0)
        #expect(DeviceKeyCrypto.hex(Data(signature)) == "11c7f3e6c4df9e8a5150e1db3b30f92de3a3b3aa438656545fa7390f4bcc7bb26c431d9e90643e4f0eaa0e9c557766fa69ada576d63dcaf2ac326c11d0b97702")
        let publicKey = [UInt8](try DeviceKeyCrypto.publicKey(Data(secret)))
        #expect(xed25519_verify(signature, publicKey, message, 200) == 0)
    }
    @Test func unregisteredCannotCreateOPKOrClaim() async throws {
        let (coordinator, _) = pair(); let device = try peer()
        await mustFail { try await coordinator.upload(scope: "alice") { _ in Issue.record("Unexpected upload"); throw URLError(.badURL) } }
        await mustFail { _ = try await coordinator.prepare(scope: "alice", friend: UUID(), device: device) { Issue.record("Unexpected claim"); throw URLError(.badURL) } }
        #expect(try coordinator.local("alice").oneTimePrekeys.isEmpty)
    }
    @Test func uploadKeepsPrivateKeysAndUniqueIDs() async throws {
        let (coordinator, _) = pair(); try await registered(coordinator)
        for _ in 0..<2 {
            try await coordinator.upload(scope: "alice") { request in
                let stored = try coordinator.local("alice")
                #expect(request.prekeys.count == 5)
                for key in request.prekeys {
                    let privateKey = try #require(stored.oneTimePrekeys.first { $0.id == key.prekey_id })
                    #expect(privateKey.upload == .submitting)
                    #expect(DeviceKeyCrypto.hex(try DeviceKeyCrypto.publicKey(privateKey.privateKey)) == key.public_key_hex)
                }
                let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
                #expect((json["prekeys"] as! [[String: Any]])[0]["prekey_id"] is NSNumber)
                return PrekeyUploadResult(deviceId: request.device_id, uploadedCount: 5)
            }
        }
        let keys = try coordinator.local("alice").oneTimePrekeys
        #expect(keys.count == 10 && Set(keys.map(\.id)).count == 10)
        #expect(keys.allSatisfy { $0.upload == .uploaded })
    }
    @Test func cacheSurvivesRestartAndIdentityChangeIsBlocked() async throws {
        let (coordinator, store) = pair(); try await registered(coordinator)
        let friend = UUID(), device = try peer()
        let expected = ClaimedPrekey(friendId: friend, deviceId: device.id, prekeyId: 1001, publicKeyHex: device.identityPublicKeyHex)
        _ = try await coordinator.prepare(scope: "alice", friend: friend, device: device) { expected }
        let restored = DeviceCoordinator(vault: DeviceKeyVault(store: store))
        let result = try await restored.prepare(scope: "alice", friend: friend, device: device) { Issue.record("Repeated claim"); return expected }
        #expect(result.contains("缓存"))
        let changed = FriendDevice(deviceId: device.id, deviceName: "Bob", status: "active", identityPublicKeyHex: try peer().identityPublicKeyHex, protocolSuite: device.protocolSuite)
        await mustFail { _ = try await restored.prepare(scope: "alice", friend: friend, device: changed) { Issue.record("Claimed changed identity"); return expected } }
    }
    @Test func existingSessionSkipsClaim() async throws {
        let (coordinator, store) = pair(); try await registered(coordinator)
        let connected = DeviceCoordinator(vault: DeviceKeyVault(store: store), sessions: ExistingDeviceSession())
        let result = try await connected.prepare(scope: "alice", friend: UUID(), device: peer()) { Issue.record("Session consumed OPK"); throw URLError(.badURL) }
        #expect(result.contains("已有会话"))
    }
    @Test func uncertainClaimDoesNotConsumeAgain() async throws {
        let (coordinator, store) = pair(); try await registered(coordinator)
        let friend = UUID(), device = try peer()
        await mustFail { _ = try await coordinator.prepare(scope: "alice", friend: friend, device: device) { throw URLError(.timedOut) } }
        let restored = DeviceCoordinator(vault: DeviceKeyVault(store: store))
        await mustFail { _ = try await restored.prepare(scope: "alice", friend: friend, device: device) { Issue.record("Repeated ambiguous claim"); throw URLError(.badURL) } }
    }
    @Test func missingPrekeyCanBeRetriedWithoutFakeSession() async throws {
        let (coordinator, _) = pair(); try await registered(coordinator)
        let friend = UUID(), device = try peer()
        let result = try await coordinator.prepare(scope: "alice", friend: friend, device: device) { throw APIError(status: 404, code: "prekey_unavailable", message: "empty") }
        #expect(result.contains("没有可用")); #expect(try coordinator.local("alice").claims.isEmpty)
        _ = try await coordinator.prepare(scope: "alice", friend: friend, device: device) { ClaimedPrekey(friendId: friend, deviceId: device.id, prekeyId: 1, publicKeyHex: device.identityPublicKeyHex) }
    }
    @Test func uncertainRegistrationAndUploadKeepKeys() async throws {
        let (coordinator, _) = pair()
        await mustFail { try await coordinator.register(scope: "bob", name: "phone") { _ in throw URLError(.timedOut) } }
        await mustFail { try await coordinator.register(scope: "bob", name: "phone") { _ in Issue.record("Repeated register"); throw URLError(.badURL) } }
        #expect(try coordinator.local("bob").oneTimePrekeys.isEmpty)
        try await registered(coordinator)
        await mustFail { try await coordinator.upload(scope: "alice") { _ in throw URLError(.timedOut) } }
        #expect(try coordinator.local("alice").oneTimePrekeys.count == 5)
        await mustFail { try await coordinator.upload(scope: "alice") { _ in Issue.record("Repeated upload"); throw URLError(.badURL) } }
    }
    @Test func loginMappingAndAccountIsolation() async throws {
        let store = DeviceMemoryStore(), user = UUID(), config = ServerConfiguration()
        let vault = DeviceKeyVault(store: store), coordinator = DeviceCoordinator(vault: DeviceKeyVault(store: store))
        let scope = try DeviceKeyVault.scope(server: config, user: user)
        try vault.bindLogin(server: config, email: "Alice@example.org", user: user, status: nil)
        #expect(try vault.loginDevice(server: config, email: "alice@example.org") == nil)
        try await coordinator.register(scope: scope, name: "phone") { _ in RegisteredDevice(deviceId: UUID(), deviceStatus: "active") }
        #expect(try vault.loginDevice(server: config, email: "alice@example.org") == coordinator.local(scope).deviceId)
        #expect(try vault.loginDevice(server: config, email: "bob@example.org") == nil)
        try vault.bindLogin(server: config, email: "alice@example.org", user: user, status: "unavailable")
        #expect(try coordinator.local(scope).phase == .unavailable)
    }
    @Test func protectedDeviceDirectoryDecoding() async throws {
        let wire = DeviceWire(), id = UUID()
        wire.response = Data("{\"friend_id\":\"\(id)\",\"devices\":[]}".utf8)
        let repo = RemoteDeviceRepository(api: APIClient(configuration: ServerConfiguration(), transport: wire, legacyTransport: wire))
        #expect(try await repo.devices(friend: id, token: "test-token").devices.isEmpty)
        #expect(wire.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }
    @Test func ownDirectoryAndRevocationWireContracts() async throws {
        let wire = DeviceWire(), user = UUID(), device = UUID()
        let repo = RemoteDeviceRepository(api: APIClient(configuration: ServerConfiguration(), transport: wire, legacyTransport: wire))
        wire.response = try JSONSerialization.data(withJSONObject: ["friend_id": user.uuidString, "target_user_id": user.uuidString, "is_own_device": true, "devices": []])
        let own = try await repo.ownDevices(token: "test-token")
        try own.validate(target: user, actor: user)
        #expect(wire.requests.last?.url?.path == "/user_devices")
        #expect(try JSONSerialization.jsonObject(with: wire.requests.last!.httpBody!) as? [String: String] == [:])
        wire.response = try JSONSerialization.data(withJSONObject: ["device_id": device.uuidString, "status": "revoked", "already_revoked": true, "websocket_closed": false])
        wire.status = 202
        let revoked = try await repo.revoke(device: device, password: " keep spaces ", token: "test-token")
        #expect(revoked.alreadyRevoked && !revoked.websocketClosed)
        let body = try JSONSerialization.jsonObject(with: wire.requests.last!.httpBody!) as! [String: String]
        #expect(body["deviceID"] == device.uuidString.lowercased() && body["device_id"] == nil)
        #expect(body["password"] == " keep spaces ")
        #expect(throws: (any Error).self) { try revoked.validate(device: UUID()) }
        #expect(throws: (any Error).self) { try own.validate(target: UUID(), actor: user) }
    }
    @Test func uploadAndClaimWireContracts() async throws {
        let wire = DeviceWire(), device = UUID(), friend = UUID()
        let repo = RemoteDeviceRepository(api: APIClient(configuration: ServerConfiguration(), transport: wire, legacyTransport: wire))
        wire.response = Data("{\"device_id\":\"\(device)\",\"uploaded_count\":1}".utf8)
        _ = try await repo.upload(PrekeyUploadRequest(device_id: device, prekeys: [.init(prekey_id: 1001, public_key_hex: "test")]), token: "token")
        #expect(wire.requests.last?.url?.path == "/upload_one_time_prekeys")
        let upload = try JSONSerialization.jsonObject(with: wire.requests.last!.httpBody!) as! [String: Any]
        #expect((upload["prekeys"] as! [[String: Any]])[0]["prekey_id"] as? Int == 1001)
        wire.response = Data("{\"friend_id\":\"\(friend)\",\"device_id\":\"\(device)\",\"prekey_id\":1001,\"public_key_hex\":\"test\"}".utf8)
        let claimed = try await repo.claim(friend: friend, device: device, token: "token")
        #expect(claimed.prekeyId == 1001 && claimed.friendId == friend)
        #expect(wire.requests.last?.url?.path == "/get_one_time_prekey")
        let claim = try JSONSerialization.jsonObject(with: wire.requests.last!.httpBody!) as! [String: String]
        #expect(claim["target_user_id"] == friend.uuidString.lowercased())
        #expect(claim["device_id"] == device.uuidString.lowercased())
        #expect(wire.requests.allSatisfy { $0.httpMethod == "POST" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer token" })
    }

}
