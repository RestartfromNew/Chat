import Foundation
import CryptoKit

/// Classical Double Ratchet §3, with a versioned app-specific wire format.
/// Not Signal wire-compatible. All state changes are returned as value copies;
/// callers commit only after authentication and durable message storage succeed.
struct RatchetState: Codable, Equatable {
    var root: Data
    var localPrivate: Data
    var remotePublic: Data?
    var sending: Data?
    var receiving: Data?
    var ns = 0
    var nr = 0
    var pn = 0
    var skipped: [String: Data] = [:]
    var retired: Set<String> = []
}
struct RatchetBootstrap: Codable, Equatable {
    let identityHex: String
    let ephemeralHex: String
    let signedPrekeyId: String
    let oneTimePrekeyId: Int
}
struct RatchetHeader: Codable, Equatable {
    let version: String
    let sessionId: UUID
    let messageId: UUID
    let senderId: UUID
    let senderDeviceId: UUID
    let recipientId: UUID
    let recipientDeviceId: UUID
    let dh: Data
    let pn: Int
    let n: Int
    let bootstrap: RatchetBootstrap?
}
struct RatchetPacket: Codable {
    let header: RatchetHeader
    let aad: Data
    let sealed: Data // CryptoKit ChaChaPoly combined: nonce || ciphertext || tag.
}
enum DoubleRatchet {
    static let version = "Chat-DR-X25519-HKDF-SHA256-ChaChaPoly-v1"
    static let maxSkip = 200
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.keyEncodingStrategy = .convertToSnakeCase; return try e.encode(value)
    }
    static func dh(_ secret: Data, _ pub: Data) throws -> Data {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secret)
        let shared = try key.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: pub))
        return shared.withUnsafeBytes { Data($0) }
    }
    static func root(_ key: Data, _ dh: Data) -> (Data, Data) {
        let value = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: dh), salt: key,
            info: Data((version + "/root").utf8), outputByteCount: 64).withUnsafeBytes { Data($0) }
        return (Data(value.prefix(32)), Data(value.suffix(32)))
    }
    static func chain(_ key: Data) -> (Data, Data) {
        let k = SymmetricKey(data: key)
        return (Data(HMAC<SHA256>.authenticationCode(for: Data([2]), using: k)),
                Data(HMAC<SHA256>.authenticationCode(for: Data([1]), using: k)))
    }
    static func initiator(secret: Data, remote: Data) throws -> RatchetState {
        let local = try DeviceKeyCrypto.privateKey()
        let (rk, ck) = root(secret, try dh(local, remote))
        return RatchetState(root: rk, localPrivate: local, remotePublic: remote, sending: ck)
    }
    static func responder(secret: Data, signedPrivate: Data) -> RatchetState {
        RatchetState(root: secret, localPrivate: signedPrivate)
    }
    static func seal(_ plaintext: String, state: RatchetState, session: UUID, message: UUID,
                     sender: UUID, local: UUID, friend: UUID, remote: UUID, bootstrap: RatchetBootstrap?) throws -> (RatchetState, Data) {
        guard !plaintext.isEmpty, plaintext.utf8.count <= 16384, let ck = state.sending,
              state.ns < Int(UInt32.max) else { throw ClientError(message: "发送链不可用或消息超长。") }
        var next = state
        let header = RatchetHeader(version: version, sessionId: session, messageId: message, senderId: sender,
            senderDeviceId: local, recipientId: friend, recipientDeviceId: remote,
            dh: try DeviceKeyCrypto.publicKey(state.localPrivate), pn: state.pn, n: state.ns, bootstrap: bootstrap)
        let aad = try encode(header), (chainKey, messageKey) = chain(ck)
        let sealed = try ChaChaPoly.seal(Data(plaintext.utf8), using: SymmetricKey(data: messageKey), authenticating: aad)
        next.sending = chainKey; next.ns += 1
        return (next, try encode(RatchetPacket(header: header, aad: aad, sealed: sealed.combined)))
    }
    private static func keyId(_ dh: Data, _ n: Int) -> String { dh.base64EncodedString() + ":" + String(n) }
    private static func skip(_ count: Int, state: inout RatchetState) throws {
        guard count >= state.nr, count - state.nr <= maxSkip else { throw ClientError(message: "乱序跨度超过上限。") }
        if state.receiving == nil {
            guard count == 0 else { throw ClientError(message: "接收链尚未建立。") }; return
        }
        guard state.skipped.count + count - state.nr <= maxSkip else { throw ClientError(message: "乱序密钥缓存已满。") }
        while state.nr < count {
            guard let ck = state.receiving, let remote = state.remotePublic else { throw ClientError(message: "缺少接收链。") }
            let (next, mk) = chain(ck)
            state.skipped[keyId(remote, state.nr)] = mk; state.receiving = next; state.nr += 1
        }
    }
    static func open(_ packet: RatchetPacket, state: RatchetState) throws -> (RatchetState, String) {
        let h = packet.header
        guard h.version == version, h.dh.count == 32, h.n >= 0, h.n < Int(UInt32.max),
              h.pn >= 0, h.pn < Int(UInt32.max), packet.aad.count <= 8192,
              packet.sealed.count >= 28, packet.sealed.count <= 16412,
              try JSONCodec.decoder().decode(RatchetHeader.self, from: packet.aad) == h else {
            throw ClientError(message: "密文格式或认证头无效。")
        }
        var next = state
        let key = keyId(h.dh, h.n)
        let mk: Data
        if let saved = next.skipped.removeValue(forKey: key) { mk = saved }
        else {
            if h.dh != next.remotePublic {
                guard !next.retired.contains(h.dh.base64EncodedString()), next.retired.count < 4096 else {
                    throw ClientError(message: "旧棘轮重放或会话轮数达到上限。")
                }
                try skip(h.pn, state: &next)
                if let old = next.remotePublic { next.retired.insert(old.base64EncodedString()) }
                next.pn = next.ns; next.ns = 0; next.nr = 0; next.remotePublic = h.dh
                (next.root, next.receiving) = root(next.root, try dh(next.localPrivate, h.dh))
                next.localPrivate = try DeviceKeyCrypto.privateKey()
                (next.root, next.sending) = root(next.root, try dh(next.localPrivate, h.dh))
            }
            try skip(h.n, state: &next)
            guard let ck = next.receiving else { throw ClientError(message: "接收链不可用。") }
            let result = chain(ck); next.receiving = result.0; mk = result.1; next.nr += 1
        }
        let bytes = try ChaChaPoly.open(.init(combined: packet.sealed), using: SymmetricKey(data: mk), authenticating: packet.aad)
        guard let body = String(data: bytes, encoding: .utf8) else { throw ClientError(message: "正文不是 UTF-8。") }
        return (next, body)
    }
    static func responderSecret(local: LocalDeviceKeys, bootstrap: RatchetBootstrap) throws -> Data {
        guard bootstrap.signedPrekeyId == "42",
              let opk = local.oneTimePrekeys.first(where: { $0.id == bootstrap.oneTimePrekeyId }), opk.privateKey.count == 32 else {
            throw ClientError(message: "缺少本机对应的预密钥，无法解密首消息。")
        }
        let identity = try PrekeyVerification.hex(bootstrap.identityHex, bytes: 32)
        let ephemeral = try PrekeyVerification.hex(bootstrap.ephemeralHex, bytes: 32)
        let material = try Data(repeating: 0xff, count: 32) + dh(local.signedPrekeyPrivate, identity)
            + dh(local.identityPrivate, ephemeral) + dh(local.signedPrekeyPrivate, ephemeral) + dh(opk.privateKey, ephemeral)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: Data(repeating: 0, count: 32),
            info: Data(PrekeyVerification.info.utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
    }
}
