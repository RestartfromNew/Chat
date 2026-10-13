import Foundation
import CryptoKit
import Security
import CXEdDSA

// Matches the backend's documented raw X25519 + XEdDSA test suite.
enum DeviceKeyCrypto {
    static let suite = "TEST-X25519-XEdDSA-HKDF-SHA256-v1"
    static func privateKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ClientError(message: "安全随机数生成失败。")
        }
        bytes[0] &= 248; bytes[31] &= 127; bytes[31] |= 64
        return Data(bytes)
    }
    static func publicKey(_ secret: Data) throws -> Data {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secret).publicKey.rawRepresentation
    }
    static func sign(prekey: Data, identity: Data) throws -> Data {
        guard prekey.count == 32, identity.count == 32 else { throw ClientError(message: "密钥长度无效。") }
        var signature = [UInt8](repeating: 0, count: 64), random = [UInt8](repeating: 0, count: 64)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw ClientError(message: "安全随机数生成失败。")
        }
        let key = [UInt8](identity), message = [UInt8](prekey)
        guard xed25519_sign(&signature, key, message, UInt(message.count), random) == 0 else {
            throw ClientError(message: "XEdDSA 签名失败。")
        }
        let result = Data(signature)
        guard verify(signature: result, prekey: prekey, identity: try publicKey(identity)) else {
            throw ClientError(message: "生成的 XEdDSA 签名未通过自检。")
        }
        return result
    }
    static func verify(signature: Data, prekey: Data, identity: Data) -> Bool {
        guard signature.count == 64, prekey.count == 32, identity.count == 32 else { return false }
        return xed25519_verify([UInt8](signature), [UInt8](identity), [UInt8](prekey), UInt(prekey.count)) == 0
    }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func validPublicHex(_ hex: String) -> Bool {
        guard hex.utf8.count == 64, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return false }
        let chars = Array(hex.utf8)
        func nibble(_ c: UInt8) -> UInt8 { c <= 57 ? c - 48 : (c | 32) - 87 }
        let bytes = Data(stride(from: 0, to: 64, by: 2).map { nibble(chars[$0]) * 16 + nibble(chars[$0 + 1]) })
        // Reject low-order/non-contributory keys by attempting X25519 (not identity authentication).
        guard let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: bytes),
              (try? Curve25519.KeyAgreement.PrivateKey().sharedSecretFromKeyAgreement(with: key)) != nil else { return false }
        return true
    }
}

enum DeviceRegistrationPhase: String, Codable { case prepared, submitting, registered, uncertain, unavailable }
enum PrekeyUploadPhase: String, Codable { case pending, submitting, uploaded, uncertain }
struct LocalOneTimePrekey: Codable {
    let id: Int
    let privateKey: Data
    var upload: PrekeyUploadPhase
}
struct CachedPrekey: Codable {
    enum Phase: String, Codable { case claiming, cached, uncertain }
    var phase: Phase
    let identityHex: String
    let suite: String
    var value: ClaimedPrekey?
    var check: PrekeyCheckState? = nil
    var bundle: SignedPrekeyMaterial? = nil
    var envelope: InitialEnvelope? = nil
}
struct LocalDeviceKeys: Codable {
    let identityPrivate: Data
    let signedPrekeyPrivate: Data
    let signature: Data
    var deviceId: UUID?
    var phase: DeviceRegistrationPhase = .prepared
    var oneTimePrekeys: [LocalOneTimePrekey] = [] // No OPK until registration succeeds.
    var claims: [String: CachedPrekey] = [:]
    var retiredClaimDevices: Set<UUID>? = nil
    static func generate() throws -> Self {
        let identity = try DeviceKeyCrypto.privateKey(), prekey = try DeviceKeyCrypto.privateKey()
        let signature = try DeviceKeyCrypto.sign(prekey: DeviceKeyCrypto.publicKey(prekey), identity: identity)
        return Self(identityPrivate: identity, signedPrekeyPrivate: prekey, signature: signature)
    }
    func registration(name: String) throws -> DeviceRegistrationRequest {
        DeviceRegistrationRequest(device_name: name, protocol_suite: DeviceKeyCrypto.suite,
            identity_public_key_hex: DeviceKeyCrypto.hex(try DeviceKeyCrypto.publicKey(identityPrivate)),
            signed_prekey_id: "42", signed_prekey_public_hex: DeviceKeyCrypto.hex(try DeviceKeyCrypto.publicKey(signedPrekeyPrivate)),
            signed_prekey_signature_hex: DeviceKeyCrypto.hex(signature))
    }
}

/// Independent Keychain namespace: logout removes tokens, never device identity/OPK private keys.
@MainActor
final class DeviceKeyVault {
    private struct Archive: Codable {
        var profiles: [String: LocalDeviceKeys] = [:]
        var loginIndex: [String: String] = [:]
    }
    private let store: any CredentialStore
    init(store: any CredentialStore = KeychainStore(service: "personal-learning.Chat.device-keys.v1", account: "devices")) { self.store = store }
    private func read() throws -> Archive {
        guard let data = try store.read() else { return Archive() }
        return try JSONDecoder().decode(Archive.self, from: data)
    }
    private func save(_ archive: Archive) throws { try store.write(JSONEncoder().encode(archive)) }
    static func scope(server: ServerConfiguration, user: UUID) throws -> String {
        try server.validatedURL().absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "|" + user.uuidString.lowercased()
    }
    func load(_ scope: String) throws -> LocalDeviceKeys? { try read().profiles[scope] }
    func save(_ record: LocalDeviceKeys, scope: String) throws {
        var archive = try read(), value = record
        if let old = archive.profiles[scope], old.deviceId != nil, old.deviceId == record.deviceId {
            // A delayed upload/claim completion must not resurrect retired bootstrap secrets.
            let retired = (old.retiredClaimDevices ?? []).union(record.retiredClaimDevices ?? [])
            if !retired.isEmpty { value.retiredClaimDevices = retired }
            for key in old.oneTimePrekeys where key.privateKey.isEmpty {
                if let i = value.oneTimePrekeys.firstIndex(where: { $0.id == key.id }) { value.oneTimePrekeys[i] = key }
                else { value.oneTimePrekeys.append(key) }
            }
            value.claims = value.claims.filter { key, claim in
                let peer = claim.value?.deviceId ?? key.split(separator: "|").last.flatMap { UUID(uuidString: String($0)) }
                return peer.map { !retired.contains($0) } ?? true
            }
        }
        archive.profiles[scope] = value; try save(archive)
    }
    private func loginKey(server: ServerConfiguration, email: String) throws -> String {
        let data = Data((try server.validatedURL().absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "|" + email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).utf8)
        return DeviceKeyCrypto.hex(Data(SHA256.hash(data: data)))
    }
    func loginDevice(server: ServerConfiguration, email: String) throws -> UUID? {
        let archive = try read()
        guard let scope = archive.loginIndex[try loginKey(server: server, email: email)],
              let record = archive.profiles[scope], record.phase == .registered else { return nil }
        return record.deviceId
    }
    func bindLogin(server: ServerConfiguration, email: String, user: UUID, status: String?) throws {
        var archive = try read(); let scope = try Self.scope(server: server, user: user)
        archive.loginIndex[try loginKey(server: server, email: email)] = scope
        if var record = archive.profiles[scope], record.deviceId != nil,
           status == "unregistered" || status == "unavailable" {
            record.phase = .unavailable; archive.profiles[scope] = record
        }
        try save(archive)
    }
}
