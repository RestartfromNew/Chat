import Foundation
import CryptoKit

/// Verified bundle material; also accepts registration JSON for optional manual debugging.
struct SignedPrekeyMaterial: Codable, Equatable {
    let protocolSuite: String
    let identityPublicKeyHex: String
    let signedPrekeyId: String
    let signedPrekeyPublicHex: String
    let signedPrekeySignatureHex: String

    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= 8192 else { throw ClientError(message: "公钥 JSON 超过 8 KB。") }
        do { return try JSONCodec.decoder().decode(Self.self, from: Data(text.utf8)) }
        catch { throw ClientError(message: "请粘贴好友“本机设备与密钥”页面的完整注册公钥 JSON。") }
    }
    func validate(for device: FriendDevice) throws {
        guard device.status == "active", protocolSuite == DeviceKeyCrypto.suite,
              protocolSuite == device.protocolSuite else { throw ClientError(message: "设备状态或协议套件不匹配。") }
        guard identityPublicKeyHex.lowercased() == device.identityPublicKeyHex.lowercased() else {
            throw ClientError(message: "导入的身份公钥与好友设备不一致，已停止计算 S。")
        }
        guard !signedPrekeyId.isEmpty, signedPrekeyId.utf8.allSatisfy({ (48...57).contains($0) }),
              let id = Int64(signedPrekeyId), id >= 0,
              DeviceKeyCrypto.validPublicHex(identityPublicKeyHex),
              DeviceKeyCrypto.validPublicHex(signedPrekeyPublicHex) else { throw ClientError(message: "Signed prekey 编号或公钥无效。") }
        let signature = try PrekeyVerification.hex(signedPrekeySignatureHex, bytes: 64)
        guard DeviceKeyCrypto.verify(signature: signature,
            prekey: try PrekeyVerification.hex(signedPrekeyPublicHex, bytes: 32),
            identity: try PrekeyVerification.hex(identityPublicKeyHex, bytes: 32)) else {
            throw ClientError(message: "XEdDSA 签名验证失败，已停止计算 S。")
        }
    }
}

/// Saved only in the device Keychain, bound to a previously claimed OPK.
struct PrekeyCheckState: Codable {
    let bundle: SignedPrekeyMaterial
    let ephemeralPrivate: Data
}

struct PrekeyCheckResult {
    let prekeyID: Int
    let signedPrekeyID: String
    let ephemeralPublicHex: String
    let secretFingerprint: String
    // Diagnostic secret never enters logs or release UI.
    #if DEBUG
    let secretHex: String
    #endif
}

/// Document's TEST four-DH/KDF calculation. This is not a completed ratchet session.
enum PrekeyVerification {
    static let info = "Example-X3DH-Core-v1"
    static func hex(_ text: String, bytes: Int) throws -> Data {
        guard text.utf8.count == bytes * 2 else { throw ClientError(message: "十六进制字段长度无效。") }
        let input = Array(text.utf8)
        guard input.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw ClientError(message: "公钥材料包含非十六进制字符。")
        }
        func nibble(_ byte: UInt8) -> UInt8 { byte <= 57 ? byte - 48 : (byte | 32) - 87 }
        return Data(stride(from: 0, to: input.count, by: 2).map { nibble(input[$0]) * 16 + nibble(input[$0 + 1]) })
    }
    static func derive(identity: Data, ephemeral: Data, remoteIdentity: Data, signedPrekey: Data, oneTimePrekey: Data) throws -> Data {
        typealias PrivateKey = Curve25519.KeyAgreement.PrivateKey
        func dh(_ secret: Data, _ publicKey: Data) throws -> Data {
            let agreement = try PrivateKey(rawRepresentation: secret).sharedSecretFromKeyAgreement(
                with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey))
            return agreement.withUnsafeBytes { Data($0) }
        }
        let d1 = try dh(identity, signedPrekey)
        let d2 = try dh(ephemeral, remoteIdentity)
        let d3 = try dh(ephemeral, signedPrekey)
        let d4 = try dh(ephemeral, oneTimePrekey)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(repeating: 0xff, count: 32) + d1 + d2 + d3 + d4),
            salt: Data(repeating: 0, count: 32), info: Data(info.utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }
    static func result(identity: Data, state: PrekeyCheckState, claim: ClaimedPrekey) throws -> PrekeyCheckResult {
        let secret = try derive(identity: identity, ephemeral: state.ephemeralPrivate,
            remoteIdentity: hex(state.bundle.identityPublicKeyHex, bytes: 32),
            signedPrekey: hex(state.bundle.signedPrekeyPublicHex, bytes: 32),
            oneTimePrekey: hex(claim.publicKeyHex, bytes: 32))
        let publicHex = DeviceKeyCrypto.hex(try DeviceKeyCrypto.publicKey(state.ephemeralPrivate))
        let fingerprint = DeviceKeyCrypto.hex(Data(SHA256.hash(data: secret)))
        #if DEBUG
        return PrekeyCheckResult(prekeyID: claim.prekeyId, signedPrekeyID: state.bundle.signedPrekeyId,
            ephemeralPublicHex: publicHex, secretFingerprint: fingerprint, secretHex: DeviceKeyCrypto.hex(secret))
        #else
        return PrekeyCheckResult(prekeyID: claim.prekeyId, signedPrekeyID: state.bundle.signedPrekeyId,
            ephemeralPublicHex: publicHex, secretFingerprint: fingerprint)
        #endif
    }
}

extension DeviceCoordinator {
    /// Read-only; reopening the result page never claims another key or regenerates EKa.
    func cachedClaim(scope: String, friend: UUID, device: FriendDevice) throws -> CachedPrekey? {
        guard let record = try vault.load(scope), record.phase == .registered, let local = record.deviceId else {
            throw ClientError(message: "请先注册本机设备。")
        }
        guard let cached = record.claims["\(local)|\(friend)|\(device.deviceId)"] else { return nil }
        guard cached.identityHex == device.identityPublicKeyHex.lowercased(), cached.suite == device.protocolSuite,
              device.status == "active", cached.phase == .cached, let value = cached.value,
              value.friendId == friend, value.deviceId == device.id,
              DeviceKeyCrypto.validPublicHex(value.publicKeyHex) else {
            throw ClientError(message: "缓存未完成、设备身份变化或 OPK 无效，不能计算 S。")
        }
        return cached
    }
    func verificationResult(scope: String, friend: UUID, device: FriendDevice) throws -> PrekeyCheckResult? {
        guard let cached = try cachedClaim(scope: scope, friend: friend, device: device),
              let state = cached.check, let claim = cached.value,
              let record = try vault.load(scope) else { return nil }
        try state.bundle.validate(for: device)
        return try PrekeyVerification.result(identity: record.identityPrivate, state: state, claim: claim)
    }
    func verifyPrekey(scope: String, friend: UUID, device: FriendDevice, json: String) throws -> PrekeyCheckResult {
        try begin(scope); defer { end(scope) }
        let bundle = try SignedPrekeyMaterial.parse(json)
        try bundle.validate(for: device)
        guard var cached = try cachedClaim(scope: scope, friend: friend, device: device), let claim = cached.value,
              var record = try vault.load(scope), let local = record.deviceId else {
            throw ClientError(message: "尚未领取 OPK，请先返回并点击“准备会话 / 获取 prekey”。")
        }
        let state: PrekeyCheckState
        if let previous = cached.check {
            // A pending handshake must keep the exact same SPK and ephemeral key.
            guard previous.bundle.signedPrekeyId == bundle.signedPrekeyId,
                  previous.bundle.signedPrekeyPublicHex.lowercased() == bundle.signedPrekeyPublicHex.lowercased() else {
                throw ClientError(message: "该 OPK 已绑定另一份 signed prekey，不能覆盖已有握手材料。")
            }
            state = previous
        } else { state = PrekeyCheckState(bundle: bundle, ephemeralPrivate: try DeviceKeyCrypto.privateKey()) }
        let result = try PrekeyVerification.result(identity: record.identityPrivate, state: state, claim: claim)
        cached.check = state; record.claims["\(local)|\(friend)|\(device.deviceId)"] = cached
        try vault.save(record, scope: scope)
        return result
    }
}
