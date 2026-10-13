import Foundation
import CryptoKit

/// Versioned test wire format. No S or private key is serialized.
struct InitialEnvelope: Codable, Equatable {
    struct Header: Codable, Equatable {
        let version: Int
        let type: String
        let protocolSuite: String
        let handshakeKdf: String
        let messageKdf: String
        let cipher: String
        let messageId: UUID
        let senderId: UUID
        let senderDeviceId: UUID
        let recipientId: UUID
        let recipientDeviceId: UUID
        let senderIdentityPublicHex: String
        let senderEphemeralPublicHex: String
        let recipientIdentityPublicHex: String
        let signedPrekeyId: String
        let oneTimePrekeyId: Int
        let saltHex: String
    }
    let header: Header
    /// These exact UTF-8 bytes are authenticated; receivers must not reserialize JSON for AAD.
    let aadBase64: String
    let nonceHex: String
    let ciphertextBase64: String
    let tagHex: String
    static let messageInfo = "Chat-Initial-Envelope-v1"
    static let testMessage = "你好，这是首次加密握手测试消息。"
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
    func json() throws -> String {
        let encoder = Self.encoder(); encoder.outputFormatting.insert(.prettyPrinted)
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
    static func make(secret: Data, sender: UUID, local: LocalDeviceKeys, friend: UUID, device: FriendDevice,
                     state: PrekeyCheckState, claim: ClaimedPrekey, plaintext: String = testMessage) throws -> Self {
        guard !plaintext.isEmpty, plaintext.utf8.count <= 16384 else { throw ClientError(message: "正文需为 1–16384 字节。") }
        guard let localID = local.deviceId else { throw ClientError(message: "本机尚未注册。") }
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let header = Header(version: 1, type: "prekey_message", protocolSuite: DeviceKeyCrypto.suite,
            handshakeKdf: PrekeyVerification.info, messageKdf: messageInfo, cipher: "ChaCha20-Poly1305",
            messageId: UUID(), senderId: sender, senderDeviceId: localID, recipientId: friend, recipientDeviceId: device.id,
            senderIdentityPublicHex: DeviceKeyCrypto.hex(try DeviceKeyCrypto.publicKey(local.identityPrivate)),
            senderEphemeralPublicHex: DeviceKeyCrypto.hex(try DeviceKeyCrypto.publicKey(state.ephemeralPrivate)),
            recipientIdentityPublicHex: device.identityPublicKeyHex.lowercased(), signedPrekeyId: state.bundle.signedPrekeyId,
            oneTimePrekeyId: claim.prekeyId, saltHex: DeviceKeyCrypto.hex(salt))
        let aad = try encoder().encode(header)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt,
                                      info: Data(messageInfo.utf8), outputByteCount: 32)
        let box = try ChaChaPoly.seal(Data(plaintext.utf8), using: key, authenticating: aad)
        return Self(header: header, aadBase64: aad.base64EncodedString(), nonceHex: box.nonce.withUnsafeBytes { DeviceKeyCrypto.hex(Data($0)) },
                    ciphertextBase64: box.ciphertext.base64EncodedString(), tagHex: DeviceKeyCrypto.hex(box.tag))
    }
    /// Crypto primitive for B and interoperability tests. Delivery, identity trust and replay storage remain transport responsibilities.
    func open(secret: Data) throws -> Data {
        guard header.version == 1, header.type == "prekey_message", header.protocolSuite == DeviceKeyCrypto.suite,
              header.handshakeKdf == PrekeyVerification.info, header.messageKdf == Self.messageInfo,
              header.cipher == "ChaCha20-Poly1305", let aad = Data(base64Encoded: aadBase64), aad.count <= 8192,
              try JSONCodec.decoder().decode(Header.self, from: aad) == header,
              let ciphertext = Data(base64Encoded: ciphertextBase64), ciphertext.count <= 16384 else {
            throw ClientError(message: "Envelope 头或 AAD 不一致。")
        }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
            salt: try PrekeyVerification.hex(header.saltHex, bytes: 32), info: Data(Self.messageInfo.utf8), outputByteCount: 32)
        let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: PrekeyVerification.hex(nonceHex, bytes: 12)),
            ciphertext: ciphertext, tag: PrekeyVerification.hex(tagHex, bytes: 16))
        return try ChaChaPoly.open(box, using: key, authenticating: aad)
    }
}
