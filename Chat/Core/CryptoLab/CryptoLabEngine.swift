import Foundation
import CryptoKit

// Local teaching protocol only. NOT X3DH wire format or a Double Ratchet.
// No networking, production credentials, persistence, or secret logging.
enum LabPeer: String, CaseIterable, Identifiable, Codable {
    case alice = "A", bob = "B"
    var id: String { rawValue }
    var other: Self { self == .alice ? .bob : .alice }
}

enum LabFailure: String, Error, LocalizedError {
    case notReady = "请先生成密钥、验证身份，再建立会话。"
    case invalidBundle = "公钥包版本、签名或身份核验失败。"
    case invalidEnvelope = "信封认证失败，未显示明文。"
    case replay = "重复信封已拒绝，不重复展示消息。"
    case input = "请输入 1–4096 字节的文本。"
    var errorDescription: String? { rawValue }
}

enum LabEncoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func display<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return "无法编码" }
        return String(decoding: data, as: UTF8.self)
    }
    static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}

struct LabBundle: Codable {
    static let suite = "LOCAL-DEMO-4DH-Ed25519-ChaChaPoly-v1"
    struct PublicMaterial: Codable {
        var suite: String
        var deviceID: UUID
        var identityKey: Data
        var signingKey: Data // Separate Ed25519 key, NOT XEdDSA.
        var signedPrekeyID: Int
        var signedPrekey: Data
        var oneTimePrekeyID: Int
        var oneTimePrekey: Data
    }
    var material: PublicMaterial
    var signature: Data
    var fingerprint: String {
        let identity = material.identityKey + material.signingKey + Data(material.deviceID.uuidString.utf8)
        return LabEncoding.hex(Data(SHA256.hash(data: identity)))
    }
    func verify(pinnedFingerprint: String) throws {
        guard material.suite == Self.suite, fingerprint == pinnedFingerprint,
              material.identityKey.count == 32, material.signingKey.count == 32,
              material.signedPrekey.count == 32, material.oneTimePrekey.count == 32,
              material.signedPrekeyID == 42, material.oneTimePrekeyID == 1007,
              signature.count == 64 else { throw LabFailure.invalidBundle }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: material.signingKey)
        guard key.isValidSignature(signature, for: try LabEncoding.encode(material)) else { throw LabFailure.invalidBundle }
    }
}

private final class LabDevice {
    let id = UUID()
    let identity = Curve25519.KeyAgreement.PrivateKey()
    let signing = Curve25519.Signing.PrivateKey()
    let prekey = Curve25519.KeyAgreement.PrivateKey()
    var oneTime: Curve25519.KeyAgreement.PrivateKey? = .init()
    func bundle() throws -> LabBundle {
        guard let oneTime else { throw LabFailure.notReady }
        let material = LabBundle.PublicMaterial(suite: LabBundle.suite, deviceID: id,
            identityKey: identity.publicKey.rawRepresentation, signingKey: signing.publicKey.rawRepresentation,
            signedPrekeyID: 42, signedPrekey: prekey.publicKey.rawRepresentation,
            oneTimePrekeyID: 1007, oneTimePrekey: oneTime.publicKey.rawRepresentation)
        return LabBundle(material: material, signature: try signing.signature(for: LabEncoding.encode(material)))
    }
}

/// The document's section 8 KDF, isolated for known-vector tests.
enum LabFourDH {
    typealias PrivateKey = Curve25519.KeyAgreement.PrivateKey
    static func dh(_ privateKey: PrivateKey, _ publicBytes: Data) throws -> Data {
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicBytes)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return secret.withUnsafeBytes { Data($0) }
    }
    static func initiate(identity: PrivateKey, ephemeral: PrivateKey, peer: LabBundle.PublicMaterial) throws -> SymmetricKey {
        let parts = try [dh(identity, peer.signedPrekey), dh(ephemeral, peer.identityKey),
                         dh(ephemeral, peer.signedPrekey), dh(ephemeral, peer.oneTimePrekey)]
        return derive(parts)
    }
    static func respond(identity: PrivateKey, prekey: PrivateKey, oneTime: PrivateKey,
                        senderIdentity: Data, senderEphemeral: Data) throws -> SymmetricKey {
        let parts = try [dh(prekey, senderIdentity), dh(identity, senderEphemeral),
                         dh(prekey, senderEphemeral), dh(oneTime, senderEphemeral)]
        return derive(parts)
    }
    private static func derive(_ parts: [Data]) -> SymmetricKey {
        let input = parts.reduce(Data(repeating: 0xff, count: 32), +)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: input),
            salt: Data(repeating: 0, count: 32), info: Data("Example-X3DH-Core-v1".utf8), outputByteCount: 32)
    }
}

struct LabEnvelope: Codable, Identifiable {
    struct Header: Codable {
        var suite: String
        var sessionID: UUID
        var conversationID: UUID
        var messageID: UUID
        var senderDeviceID: UUID
        var recipientDeviceID: UUID
        var salt: Data
    }
    var header: Header
    var sealedBox: Data // CryptoKit combined: 12-byte nonce || ciphertext || 16-byte tag.
    var id: UUID { header.messageID }
}

struct LabHandshake: Codable {
    let senderDeviceID: UUID
    let recipientDeviceID: UUID
    let identityPublicKey: Data
    let ephemeralPublicKey: Data
    let signedPrekeyID: Int
    let oneTimePrekeyID: Int
}

/// One direction per channel, with two independently calculated roots.
/// No ratchet: random per-message salt derives a new key, but offers no forward secrecy.
private struct LabChannel {
    let id = UUID()
    let handshake: LabHandshake
    let sendRoot: SymmetricKey
    let receiveRoot: SymmetricKey
}

@MainActor
final class CryptoLabEngine {
    private var devices: [LabPeer: LabDevice] = [:]
    private var channels: [LabPeer: LabChannel] = [:]
    private var received: Set<UUID> = []
    private var conversationID = UUID()
    private(set) var bundles: [LabPeer: LabBundle] = [:]
    private(set) var verified = false
    var ready: Bool { channels.count == 2 }
    var handshakes: [LabHandshake] { LabPeer.allCases.compactMap { channels[$0]?.handshake } }
    var consumedPrekeys: Int { devices.values.filter { $0.oneTime == nil }.count }

    func generate() throws {
        let alice = LabDevice(), bob = LabDevice()
        let fresh: [LabPeer: LabBundle] = [.alice: try alice.bundle(), .bob: try bob.bundle()]
        devices = [.alice: alice, .bob: bob]; bundles = fresh
        channels = [:]; received = []; conversationID = UUID(); verified = false
    }
    func verify() throws {
        guard devices.count == 2 else { throw LabFailure.notReady }
        for peer in LabPeer.allCases {
            guard let device = devices[peer], let bundle = bundles[peer] else { throw LabFailure.notReady }
            // Local lab trust anchor: the fingerprint taken directly from that device.
            // Production must use an independently verified/pinned peer identity.
            try bundle.verify(pinnedFingerprint: device.bundle().fingerprint)
        }
        verified = true
    }
    func establish() throws {
        guard verified, !ready else { throw LabFailure.notReady }
        var candidates: [LabPeer: LabChannel] = [:]
        for from in LabPeer.allCases {
            guard let sender = devices[from], let recipient = devices[from.other],
                  let opk = recipient.oneTime, let bundle = bundles[from.other] else { throw LabFailure.notReady }
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let sendRoot = try LabFourDH.initiate(identity: sender.identity, ephemeral: ephemeral, peer: bundle.material)
            let receiveRoot = try LabFourDH.respond(identity: recipient.identity, prekey: recipient.prekey,
                oneTime: opk, senderIdentity: sender.identity.publicKey.rawRepresentation,
                senderEphemeral: ephemeral.publicKey.rawRepresentation)
            guard sendRoot == receiveRoot else { throw LabFailure.invalidBundle }
            let header = LabHandshake(senderDeviceID: sender.id, recipientDeviceID: recipient.id,
                identityPublicKey: sender.identity.publicKey.rawRepresentation,
                ephemeralPublicKey: ephemeral.publicKey.rawRepresentation, signedPrekeyID: 42, oneTimePrekeyID: 1007)
            candidates[from] = LabChannel(handshake: header, sendRoot: sendRoot, receiveRoot: receiveRoot)
        }
        channels = candidates
    }
    func encrypt(_ text: String, from: LabPeer) throws -> LabEnvelope {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 4096 else { throw LabFailure.input }
        guard let channel = channels[from] else { throw LabFailure.notReady }
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let header = LabEnvelope.Header(suite: LabBundle.suite, sessionID: channel.id, conversationID: conversationID,
            messageID: UUID(), senderDeviceID: channel.handshake.senderDeviceID,
            recipientDeviceID: channel.handshake.recipientDeviceID, salt: salt)
        let aad = try LabEncoding.encode(header)
        let key = messageKey(root: channel.sendRoot, salt: salt, aad: aad)
        let box = try ChaChaPoly.seal(Data(text.utf8), using: key, authenticating: aad)
        return LabEnvelope(header: header, sealedBox: box.combined)
    }
    func decrypt(_ packet: LabEnvelope, at recipient: LabPeer, wrongKey: Bool = false) throws -> String {
        guard let channel = channels[recipient.other], let device = devices[recipient],
              packet.header.suite == LabBundle.suite, packet.header.conversationID == conversationID,
              packet.header.sessionID == channel.id, packet.header.recipientDeviceID == device.id,
              packet.header.senderDeviceID == channel.handshake.senderDeviceID,
              packet.header.salt.count == 32, packet.sealedBox.count >= 29,
              packet.sealedBox.count <= 4096 + 28 else { throw LabFailure.invalidEnvelope }
        guard !received.contains(packet.id) else { throw LabFailure.replay }
        let text: String
        do {
            let aad = try LabEncoding.encode(packet.header)
            let root = wrongKey ? SymmetricKey(size: .bits256) : channel.receiveRoot
            let key = messageKey(root: root, salt: packet.header.salt, aad: aad)
            let data = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: packet.sealedBox), using: key, authenticating: aad)
            guard let decoded = String(data: data, encoding: .utf8) else { throw LabFailure.invalidEnvelope }
            text = decoded
        } catch { throw LabFailure.invalidEnvelope }
        // Commit only after authentication succeeds. Failures never consume the OPK or message ID.
        received.insert(packet.id)
        device.oneTime = nil
        return text
    }
    private func messageKey(root: SymmetricKey, salt: Data, aad: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: root, salt: salt,
            info: Data("Local-Demo-Message-v1".utf8) + aad, outputByteCount: 32)
    }
}
