import Foundation
import Combine

struct ChatPeer: Codable {
    let user: UUID
    let device: UUID
    let identityHex: String
}
struct ChatSession: Codable {
    let id: UUID
    let peer: ChatPeer
    var ratchet: RatchetState
    var bootstrap: RatchetBootstrap?
}
struct ChatMessage: Codable, Identifiable {
    let id: UUID
    let friend: UUID
    let text: String
    let outgoing: Bool
    let date: Date // Local receipt/creation time, never claimed to be server time.
    var status: String
}
struct ChatOutgoing: Codable, Identifiable {
    let messageId: UUID
    let target: UUID
    let packet: Data
    var receipt: StoredMessageReceipt?
    var errorCode: String?
    var id: String { messageId.uuidString + "|" + target.uuidString }
}
struct ChatInboxItem: Codable {
    let envelope: IncomingEnvelope
    var acknowledged = false
    var decrypted = false
    var error: String?
}
struct ChatArchive: Codable {
    var peers: [UUID: ChatPeer] = [:]
    var sessions: [UUID: ChatSession] = [:]
    var messages: [UUID: ChatMessage] = [:]
    var outgoing: [String: ChatOutgoing] = [:]
    var inbox: [UUID: ChatInboxItem] = [:]
    var cursors: [UUID: Int64] = [:]
    var usedPrekeys: [Int: UUID] = [:]
}
/// One Keychain update commits sessions, message text, packets and cursors together.
/// Appropriate for this small client; the persistence boundary can later use an encrypted DB.
@MainActor final class ChatStore: ObservableObject, DeviceSessionLookup {
    @Published private(set) var archive = ChatArchive()
    private let storage: any CredentialStore
    private(set) var scope: String?
    private(set) var user: UUID?
    private(set) var device: UUID?
    init(storage: any CredentialStore = KeychainStore(service: "personal-learning.Chat.ratchet.v1", account: "archive")) {
        self.storage = storage
    }
    func reset() { archive = ChatArchive(); scope = nil; user = nil; device = nil }
    private func load() throws -> [String: ChatArchive] {
        guard let data = try storage.read() else { return [:] }
        return try JSONDecoder().decode([String: ChatArchive].self, from: data)
    }
    func bind(scope: String, user: UUID, device: UUID) throws {
        let key = scope + "|" + user.uuidString + "|" + device.uuidString
        if self.scope == key { return }
        reset()
        let value = try load()[key] ?? ChatArchive()
        self.scope = key; self.user = user; self.device = device; archive = value
    }
    private func commit(_ value: ChatArchive) throws {
        guard let scope else { throw ClientError(message: "聊天存储尚未绑定账号。") }
        var values = try load(); values[scope] = value
        try storage.write(JSONEncoder().encode(values)); archive = value
    }
    func remember(user: UUID, devices: [FriendDevice]) throws {
        var value = archive
        for device in devices {
            guard DeviceKeyCrypto.validPublicHex(device.identityPublicKeyHex) else { throw ClientError(message: "好友身份公钥无效。") }
            if let old = value.peers[device.id], old.user != user || old.identityHex != device.identityPublicKeyHex.lowercased() {
                throw ClientError(message: "好友设备身份发生变化，已暂停该设备通信，请核实身份。")
            }
            value.peers[device.id] = ChatPeer(user: user, device: device.id, identityHex: device.identityPublicKeyHex.lowercased())
        }
        try commit(value)
    }
    func hasSession(scope: String, local: UUID, remote: UUID) -> Bool {
        self.device == local && self.scope?.hasPrefix(scope + "|") == true && session(for: remote) != nil
    }
    /// Tombstones preserve monotonically allocated OPK IDs while removing consumed secrets.
    /// This cleanup follows the atomic chat commit and is repeated on restore after a crash.
    func retiringBootstrapMaterial(_ local: LocalDeviceKeys) -> LocalDeviceKeys? {
        guard local.deviceId == device else { return nil }
        var next = local, changed = false
        next.oneTimePrekeys = local.oneTimePrekeys.map { key in
            if archive.usedPrekeys[key.id] != nil && !key.privateKey.isEmpty {
                changed = true; return LocalOneTimePrekey(id: key.id, privateKey: Data(), upload: key.upload)
            }
            return key
        }
        let established = Set(archive.sessions.values.map { $0.peer.device })
        let retired = (local.retiredClaimDevices ?? []).union(established)
        if !retired.isEmpty && retired != local.retiredClaimDevices { next.retiredClaimDevices = retired; changed = true }
        for (key, claim) in local.claims {
            let peer = claim.value?.deviceId ?? key.split(separator: "|").last.flatMap { UUID(uuidString: String($0)) }
            if peer.map({ retired.contains($0) }) == true { next.claims.removeValue(forKey: key); changed = true }
        }
        return changed ? next : nil
    }
    func session(for peer: UUID) -> ChatSession? {
        // Simultaneous initiations retain both sessions. A deterministic preference converges
        // after both initial packets arrive; old sessions remain usable for delayed packets.
        archive.sessions.values.filter { $0.peer.device == peer }.sorted { $0.id.uuidString < $1.id.uuidString }.first
    }
    func prepareMessage(text: String, friend: UUID, targets: [FriendDevice], seeds: [UUID: CachedPrekey], local: LocalDeviceKeys) throws -> UUID {
        guard let user, let device, device == local.deviceId, !targets.isEmpty, Set(targets.map(\.id)).count == targets.count else {
            throw ClientError(message: "没有可发送的好友设备。")
        }
        var value = archive
        let id = UUID()
        for target in targets {
            guard target.status == "active", target.protocolSuite == DeviceKeyCrypto.suite,
                  let peer = value.peers[target.id], peer.user == friend else { throw ClientError(message: "目标设备身份不可用。") }
            var state: ChatSession
            if let existing = session(for: target.id) { state = existing }
            else {
                guard value.sessions.count < 1000, let seed = seeds[target.id], seed.phase == .cached, let check = seed.check, let claim = seed.value else { throw ClientError(message: "缺少已验证的首消息密钥。") }
                try check.bundle.validate(for: target)
                guard claim.friendId == friend, claim.deviceId == target.id else { throw ClientError(message: "预密钥不属于目标设备。") }
                let secret = try PrekeyVerification.derive(identity: local.identityPrivate, ephemeral: check.ephemeralPrivate,
                    remoteIdentity: PrekeyVerification.hex(peer.identityHex, bytes: 32),
                    signedPrekey: PrekeyVerification.hex(check.bundle.signedPrekeyPublicHex, bytes: 32),
                    oneTimePrekey: PrekeyVerification.hex(claim.publicKeyHex, bytes: 32))
                let bootstrap = RatchetBootstrap(identityHex: DeviceKeyCrypto.hex(try DeviceKeyCrypto.publicKey(local.identityPrivate)),
                    ephemeralHex: DeviceKeyCrypto.hex(try DeviceKeyCrypto.publicKey(check.ephemeralPrivate)),
                    signedPrekeyId: check.bundle.signedPrekeyId, oneTimePrekeyId: claim.prekeyId)
                state = ChatSession(id: UUID(), peer: peer,
                    ratchet: try DoubleRatchet.initiator(secret: secret, remote: PrekeyVerification.hex(check.bundle.signedPrekeyPublicHex, bytes: 32)), bootstrap: bootstrap)
            }
            let (ratchet, packet) = try DoubleRatchet.seal(text, state: state.ratchet, session: state.id, message: id,
                sender: user, local: device, friend: friend, remote: target.id, bootstrap: state.bootstrap)
            guard packet.count <= 65536 else { throw ClientError(message: "加密包超长。") }
            state.ratchet = ratchet; value.sessions[state.id] = state
            let pending = ChatOutgoing(messageId: id, target: target.id, packet: packet)
            value.outgoing[pending.id] = pending
        }
        value.messages[id] = ChatMessage(id: id, friend: friend, text: text, outgoing: true, date: Date(), status: "待发送")
        try commit(value) // Advance the ratchet only in the same write as retryable ciphertext.
        return id
    }
    func outgoingFrame(_ item: ChatOutgoing, token: String) throws -> Data {
        guard let device else { throw ClientError(message: "设备未绑定。") }
        return try EnvelopeAPI.frame("chat.newTextMessage", token: token, fields: ["sender_device_id": device.uuidString.lowercased(),
            "recipient_device_id": item.target.uuidString.lowercased(), "message_id": item.messageId.uuidString.lowercased(),
            "protocol_version": DoubleRatchet.version, "packet_base64": item.packet.base64EncodedString()])
    }
    func accepted(_ item: ChatOutgoing, receipt: StoredMessageReceipt) throws {
        guard receipt.messageId == item.messageId, receipt.seq > 0 else { throw ClientError(message: "发送回执不匹配。") }
        var value = archive; value.outgoing[item.id]?.receipt = receipt; value.outgoing[item.id]?.errorCode = nil
        let complete = value.outgoing.values.filter { $0.messageId == item.messageId }.allSatisfy { $0.receipt != nil }
        value.messages[item.messageId]?.status = complete ? "已存储" : "部分设备已存储"
        try commit(value) // Never use outgoing seq as an incoming cursor.
    }
    func failed(_ item: ChatOutgoing, error: Error) throws {
        var value = archive
        value.outgoing[item.id]?.errorCode = (error as? SocketBusinessError)?.code
        value.messages[item.messageId]?.status = (error as? SocketBusinessError)?.code == "envelope_conflict" ? "密文冲突，已停止重试" : "发送未完成，点按重试"
        try commit(value)
    }
    /// Shared durable intake for sync and a future authenticated push adapter.
    /// A push cannot advance sync cursors: an earlier envelope may still be offline.
    func ingest(_ envelopes: [IncomingEnvelope], advanceCursors: Bool) throws {
        guard let device else { throw ClientError(message: "设备未绑定。") }
        var value = archive
        for e in envelopes {
            guard e.recipientDeviceId == device else { throw ClientError(message: "信封目标不是本机。") }
            _ = try e.packet()
            if let old = value.inbox[e.envelopeId] {
                guard old.envelope == e else { throw ClientError(message: "重复信封内容不一致。") }
            } else { value.inbox[e.envelopeId] = ChatInboxItem(envelope: e) }
            if advanceCursors { value.cursors[e.senderDeviceId] = max(value.cursors[e.senderDeviceId] ?? 0, e.seq) }
        }
        guard value.cursors.count <= 1000 else { throw ClientError(message: "设备游标数量达到服务端上限。") }
        try commit(value)
    }
    func confirm(_ ids: [UUID]) throws {
        var value = archive
        for id in ids { value.inbox[id]?.acknowledged = true }
        try commit(value)
    }
    func decryptPending(local: LocalDeviceKeys) throws {
        let pending = archive.inbox.values.filter { !$0.decrypted }.sorted {
            if $0.envelope.senderDeviceId == $1.envelope.senderDeviceId { return $0.envelope.seq < $1.envelope.seq }
            return $0.envelope.senderDeviceId.uuidString < $1.envelope.senderDeviceId.uuidString
        }
        for item in pending {
            var next = archive
            do {
                try decrypt(item.envelope, local: local, value: &next)
                next.inbox[item.envelope.envelopeId]?.decrypted = true
                next.inbox[item.envelope.envelopeId]?.error = nil
            } catch {
                next = archive // Never commit failed AEAD's tentative chain/OPK changes.
                next.inbox[item.envelope.envelopeId]?.error = error.localizedDescription
            }
            try commit(next)
        }
    }
    private func decrypt(_ e: IncomingEnvelope, local: LocalDeviceKeys, value: inout ChatArchive) throws {
        guard let user, let device, local.deviceId == device, let peer = value.peers[e.senderDeviceId] else {
            throw ClientError(message: "发送设备身份尚未核实，已保存密文等待处理。")
        }
        let bytes = try e.packet(), text: String
        if e.protocolVersion == DoubleRatchet.version {
            let packet = try JSONCodec.decoder().decode(RatchetPacket.self, from: bytes), h = packet.header
            guard h.senderId == peer.user, h.senderDeviceId == peer.device, h.recipientId == user,
                  h.recipientDeviceId == device, h.messageId == e.messageId else { throw ClientError(message: "密文路由绑定不匹配。") }
            var session: ChatSession
            if let existing = value.sessions[h.sessionId] {
                guard existing.peer.device == peer.device, existing.peer.identityHex == peer.identityHex else { throw ClientError(message: "会话身份不匹配。") }
                session = existing
            } else {
                guard value.sessions.count < 1000, let initial = h.bootstrap, initial.identityHex.lowercased() == peer.identityHex,
                      h.pn == 0, value.usedPrekeys[initial.oneTimePrekeyId] == nil else {
                    throw ClientError(message: "缺少首次握手、预密钥已用或会话上限。")
                }
                session = ChatSession(id: h.sessionId, peer: peer,
                    ratchet: DoubleRatchet.responder(secret: try DoubleRatchet.responderSecret(local: local, bootstrap: initial), signedPrivate: local.signedPrekeyPrivate))
                value.usedPrekeys[initial.oneTimePrekeyId] = h.sessionId
            }
            let opened = try DoubleRatchet.open(packet, state: session.ratchet)
            session.ratchet = opened.0; session.bootstrap = nil
            value.sessions[h.sessionId] = session; text = opened.1
        } else if e.protocolVersion == StoredMessageProtocol.version {
            // Read-only migration for old TEST packets; never creates a ratchet session.
            let old = try JSONCodec.decoder().decode(InitialEnvelope.self, from: bytes), h = old.header
            guard h.senderId == peer.user, h.senderDeviceId == peer.device, h.recipientId == user,
                  h.recipientDeviceId == device, h.messageId == e.messageId,
                  h.senderIdentityPublicHex.lowercased() == peer.identityHex,
                  h.recipientIdentityPublicHex.lowercased() == DeviceKeyCrypto.hex(try DeviceKeyCrypto.publicKey(local.identityPrivate)) else {
                throw ClientError(message: "旧版信封身份不匹配。")
            }
            let bootstrap = RatchetBootstrap(identityHex: h.senderIdentityPublicHex, ephemeralHex: h.senderEphemeralPublicHex,
                signedPrekeyId: h.signedPrekeyId, oneTimePrekeyId: h.oneTimePrekeyId)
            let opened = try old.open(secret: DoubleRatchet.responderSecret(local: local, bootstrap: bootstrap))
            guard let result = String(data: opened, encoding: .utf8) else { throw ClientError(message: "旧正文无效。") }; text = result
        } else { throw ClientError(message: "暂不支持此密文协议：\(e.protocolVersion)") }
        guard value.messages[e.messageId] == nil else { throw ClientError(message: "消息编号重复，已保留原消息。") }
        value.messages[e.messageId] = ChatMessage(id: e.messageId, friend: peer.user, text: text, outgoing: false, date: Date(), status: "已解密")
    }
}
