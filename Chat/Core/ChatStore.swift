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
    @Published private(set) var readState = ConversationReadState(savedIDs: [], existing: [])
    @Published var visibleConversation: UUID?
    private let readDefaults: UserDefaults
    private let io: ChatArchiveIO
    private var generation = UUID()
    private var writing = false
    private var revision = 0
    private(set) var scope: String?
    private(set) var user: UUID?
    private(set) var device: UUID?
    init(storage: any CredentialStore = KeychainStore(service: "personal-learning.Chat.ratchet.v1", account: "archive"), readDefaults: UserDefaults = .standard) {
        self.io = ChatArchiveIO(storage: storage)
        self.readDefaults = readDefaults
    }
    func reset() { visibleConversation = nil; generation = UUID(); revision += 1; writing = false; archive = ChatArchive(); readState = ConversationReadState(savedIDs: [], existing: []); scope = nil; user = nil; device = nil }
    func bind(scope: String, user: UUID, device: UUID) async throws {
        let key = scope + "|" + user.uuidString + "|" + device.uuidString
        if self.scope == key { return }
        reset(); let current = generation
        let value = try await io.read(key)
        guard current == generation else { throw CancellationError() }
        self.scope = key; self.user = user; self.device = device
        let readKey = "chat.read.v1." + key
        readState = ConversationReadState(savedIDs: readDefaults.stringArray(forKey: readKey), existing: Array(value.messages.values))
        readDefaults.set(readState.savedIDs, forKey: readKey)
        archive = value
    }
    var unreadCounts: [UUID: Int] {
        readState.unreadCounts(in: Array(archive.messages.values))
    }
    func markRead(friend: UUID) {
        guard let scope else { return }
        var next = readState
        next.markRead(Array(archive.messages.values), friend: friend)
        guard next.ids != readState.ids else { return }
        readDefaults.set(next.savedIDs, forKey: "chat.read.v1." + scope)
        readState = next
    }
    private func commit(_ value: ChatArchive) async throws {
        guard let scope, !writing else { throw ClientError(message: "聊天存储未就绪或正在写入。") }
        let current = generation
        writing = true; defer { if current == generation { writing = false } }
        try await io.write(value, scope: scope)
        guard current == generation else { throw CancellationError() }
        revision += 1; archive = value
    }
    func remember(user: UUID, devices: [FriendDevice]) async throws {
        try await rememberDirectory([(user, devices)])
    }
    func rememberDirectory(_ entries: [(UUID, [FriendDevice])]) async throws {
        var value = archive, changed = false
        for (user, devices) in entries {
            for device in devices {
                guard DeviceKeyCrypto.validPublicHex(device.identityPublicKeyHex) else { throw ClientError(message: "好友身份公钥无效。") }
                if let old = value.peers[device.id] {
                    guard old.user == user, old.identityHex == device.identityPublicKeyHex.lowercased() else {
                        throw ClientError(message: "好友设备身份发生变化，请核实身份。")
                    }
                } else {
                    value.peers[device.id] = ChatPeer(user: user, device: device.id, identityHex: device.identityPublicKeyHex.lowercased())
                    changed = true
                }
            }
        }
        if changed { try await commit(value) }
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
    func prepareMessage(text: String, friend: UUID, targets: [FriendDevice], ownTargets: [FriendDevice] = [], seeds: [UUID: CachedPrekey], local: LocalDeviceKeys) async throws -> UUID {
        guard let user, let device, device == local.deviceId, !targets.isEmpty, Set((targets + ownTargets).map(\.id)).count == targets.count + ownTargets.count else {
            throw ClientError(message: "没有可发送的好友设备。")
        }
        var value = archive
        let id = UUID()
        for target in targets + ownTargets {
            let owner = ownTargets.contains(where: { $0.id == target.id }) ? user : friend
            guard target.id != device, target.status == "active", target.protocolSuite == DeviceKeyCrypto.suite,
                  let peer = value.peers[target.id], peer.user == owner else { throw ClientError(message: "目标设备身份不可用。") }
            var state: ChatSession
            if let existing = session(for: target.id) { state = existing }
            else {
                guard value.sessions.count < 1000, let seed = seeds[target.id], seed.phase == .cached, let check = seed.check, let claim = seed.value else { throw ClientError(message: "缺少已验证的首消息密钥。") }
                try check.bundle.validate(for: target)
                guard claim.friendId == owner, claim.deviceId == target.id else { throw ClientError(message: "预密钥不属于目标设备。") }
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
            let content = owner == user ? try OwnDeviceMessage.encode(text: text, conversation: friend, message: id) : text
            let (ratchet, packet) = try DoubleRatchet.seal(content, state: state.ratchet, session: state.id, message: id,
                sender: user, local: device, friend: owner, remote: target.id, bootstrap: state.bootstrap)
            guard packet.count <= 65536 else { throw ClientError(message: "加密包超长。") }
            state.ratchet = ratchet; value.sessions[state.id] = state
            let pending = ChatOutgoing(messageId: id, target: target.id, packet: packet)
            value.outgoing[pending.id] = pending
        }
        value.messages[id] = ChatMessage(id: id, friend: friend, text: text, outgoing: true, date: Date(), status: "待发送")
        try await commit(value) // Advance the ratchet only in the same write as retryable ciphertext.
        return id
    }
    func outgoingFrame(_ item: ChatOutgoing, token: String) throws -> Data {
        guard let device else { throw ClientError(message: "设备未绑定。") }
        return try EnvelopeAPI.frame("chat.newTextMessage", token: token, fields: ["sender_device_id": device.uuidString.lowercased(),
            "recipient_device_id": item.target.uuidString.lowercased(), "message_id": item.messageId.uuidString.lowercased(),
            "protocol_version": DoubleRatchet.version, "packet_base64": item.packet.base64EncodedString()])
    }
    func accepted(_ item: ChatOutgoing, receipt: StoredMessageReceipt) async throws {
        guard receipt.messageId == item.messageId, receipt.seq > 0 else { throw ClientError(message: "发送回执不匹配。") }
        var value = archive; value.outgoing[item.id]?.receipt = receipt; value.outgoing[item.id]?.errorCode = nil
        let complete = value.outgoing.values.filter { $0.messageId == item.messageId }.allSatisfy { $0.receipt != nil }
        value.messages[item.messageId]?.status = complete ? "已存储" : "部分设备已存储"
        try await commit(value) // Never use outgoing seq as an incoming cursor.
    }
    func failed(_ item: ChatOutgoing, error: Error) async throws {
        var value = archive
        value.outgoing[item.id]?.errorCode = (error as? SocketBusinessError)?.code
        value.messages[item.messageId]?.status = (error as? SocketBusinessError)?.code == "envelope_conflict" ? "密文冲突，已停止重试" : "发送未完成，点按重试"
        try await commit(value)
    }
    /// Shared durable intake for sync and authenticated online push.
    /// A push cannot advance sync cursors: an earlier envelope may still be offline.
    func ingest(_ envelopes: [IncomingEnvelope], advanceCursors: Bool) async throws {
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
        try await commit(value)
    }
    func confirm(_ ids: [UUID]) async throws {
        var value = archive
        for id in ids { value.inbox[id]?.acknowledged = true }
        try await commit(value)
    }
    func decryptPending(local: LocalDeviceKeys, retryFailures: Bool = true) async throws {
        guard let user, let device else { throw ClientError(message: "聊天存储未绑定。") }
        let snapshot = archive, current = generation, version = revision
        let pending = snapshot.inbox.values.filter { !$0.decrypted && (retryFailures || $0.error == nil) }
        guard !pending.isEmpty else { return }
        let work = Task.detached(priority: .utility) {
            var value = snapshot
            let ordered = pending.sorted {
                if $0.envelope.senderDeviceId == $1.envelope.senderDeviceId { return $0.envelope.seq < $1.envelope.seq }
                return $0.envelope.senderDeviceId.uuidString < $1.envelope.senderDeviceId.uuidString
            }
            for item in ordered {
                if Task.isCancelled { break }
                do {
                    try Self.decrypt(item.envelope, local: local, user: user, device: device, value: &value)
                    value.inbox[item.envelope.envelopeId]?.decrypted = true
                    value.inbox[item.envelope.envelopeId]?.error = nil
                } catch { value.inbox[item.envelope.envelopeId]?.error = error.localizedDescription }
            }
            return value
        }
        let value = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
        guard current == generation else { throw CancellationError() }
        try Task.checkCancellation()
        guard version == revision else { throw ClientError(message: "会话状态已更新，请重试处理待收消息。") }
        try await commit(value) // One durable write per batch, not per message.
    }
    nonisolated private static func decrypt(_ e: IncomingEnvelope, local: LocalDeviceKeys, user: UUID, device: UUID, value: inout ChatArchive) throws {
        guard local.deviceId == device, let peer = value.peers[e.senderDeviceId] else {
            throw ClientError(message: "发送设备身份尚未核实，已保存密文等待处理。")
        }
        guard value.messages[e.messageId] == nil else { throw ClientError(message: "消息编号重复，已保留原消息。") }
        let bytes = try e.packet(), text: String
        var conversation = peer.user, outgoing = false
        if e.protocolVersion == DoubleRatchet.version {
            let packet = try JSONCodec.decoder().decode(RatchetPacket.self, from: bytes), h = packet.header
            guard h.senderId == peer.user, h.senderDeviceId == peer.device, h.recipientId == user,
                  h.recipientDeviceId == device, h.messageId == e.messageId else { throw ClientError(message: "密文路由绑定不匹配。") }
            var consumedPrekey: Int?
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
                consumedPrekey = initial.oneTimePrekeyId
            }
            let opened = try DoubleRatchet.open(packet, state: session.ratchet)
            if peer.user == user {
                let copy = try OwnDeviceMessage.decode(opened.1, message: e.messageId)
                conversation = copy.conversationId; outgoing = true; text = copy.text
            } else { text = opened.1 }
            session.ratchet = opened.0; session.bootstrap = nil
            // No archive mutation until authentication and plaintext decoding succeed.
            if let consumedPrekey { value.usedPrekeys[consumedPrekey] = h.sessionId }
            value.sessions[h.sessionId] = session
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
        value.messages[e.messageId] = ChatMessage(id: e.messageId, friend: conversation, text: text, outgoing: outgoing, date: Date(), status: "已解密")
    }
}
