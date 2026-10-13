import Foundation
import Combine

@MainActor
final class StoredMessageOutbox: ObservableObject {
    enum State: String, Codable {
        case prepared = "待发送", sending = "等待存储回执", accepted = "服务器已持久化（非送达）"
        case uncertain = "结果不确定，可重试原报文", rejected = "服务器拒绝"
    }
    struct Item: Codable {
        let envelope: InitialEnvelope
        let packet: Data
        var state: State = .prepared
        var detail: String?
        var errorCode: String?
        var receipt: StoredMessageReceipt?
    }
    @Published private(set) var outgoing: [UUID: Item] = [:]
    @Published private(set) var isSending = false
    let receiveStatus = "当前后端只返回存储结果；尚未实现好友推送、离线收件与 ACK。"
    private let store: any CredentialStore
    private var scope: String?
    private var account: UUID?
    private var device: UUID?
    private var generation = UUID()
    init(store: any CredentialStore = KeychainStore(service: "personal-learning.Chat.outbox.v1", account: "packets")) { self.store = store }
    private func archive() throws -> [String: [UUID: Item]] {
        guard let data = try store.read() else { return [:] }
        return try JSONDecoder().decode([String: [UUID: Item]].self, from: data)
    }
    private func save(_ values: [UUID: Item], scope: String) throws {
        var archive = try archive(); archive[scope] = values; try store.write(JSONEncoder().encode(archive))
    }
    func bind(scope: String, account: UUID, device: UUID) throws {
        let scope = scope + "/" + account.uuidString.lowercased() + "/" + device.uuidString.lowercased()
        if self.scope == scope && self.account == account && self.device == device { return }
        reset()
        var values = try archive()[scope] ?? [:]
        for id in values.keys where values[id]?.state == .sending { values[id]?.state = .uncertain }
        try save(values, scope: scope)
        self.scope = scope; self.account = account; self.device = device; outgoing = values
    }
    func stage(_ envelope: InitialEnvelope) throws {
        guard let scope, envelope.header.senderId == account, envelope.header.senderDeviceId == device else {
            throw ClientError(message: "报文不属于当前账号和设备。")
        }
        let id = envelope.header.messageId
        if let existing = outgoing[id] {
            guard existing.envelope == envelope else { throw ClientError(message: "消息 ID 已绑定其他密文。") }; return
        }
        let packet = try InitialEnvelope.encoder().encode(envelope)
        guard packet.count <= 65536 else { throw ClientError(message: "密文包超过 64 KiB。") }
        var values = outgoing; values[id] = Item(envelope: envelope, packet: packet)
        try save(values, scope: scope); outgoing = values
    }
    func canSend(_ id: UUID) -> Bool {
        guard !isSending, let value = outgoing[id], value.errorCode != "envelope_conflict" else { return false }
        return value.state == .prepared || value.state == .uncertain || value.state == .rejected
    }
    func send(_ id: UUID, token: String, submit: (Data, UUID) async throws -> StoredMessageReceipt) async throws {
        guard canSend(id), let scope, var value = outgoing[id] else { throw ClientError(message: "消息不能发送，或上一条仍等待回执。") }
        let frame = try StoredMessageProtocol.encode(value.envelope, packet: value.packet, token: token)
        let current = generation
        isSending = true
        defer { if generation == current { isSending = false } }
        value.state = .sending; value.detail = nil; value.errorCode = nil
        var values = outgoing; values[id] = value
        try save(values, scope: scope); outgoing = values // Durable before any network write.
        do {
            let receipt = try await submit(frame, id)
            guard generation == current else { throw CancellationError() }
            guard receipt.messageId == id, receipt.seq > 0 else { throw SocketBusinessError(code: "invalid_response") }
            value.state = .accepted; value.receipt = receipt
            value.detail = "seq=\(receipt.seq) · envelope_id=\(receipt.envelopeId) · duplicate=\(receipt.duplicate)"
            values = outgoing; values[id] = value
            try save(values, scope: scope); outgoing = values
        } catch {
            guard generation == current else { throw CancellationError() }
            value.state = .uncertain
            if let business = error as? SocketBusinessError {
                value.errorCode = business.code
                if business.isAuthentication || ["invalid_request", "send_permission_denied", "envelope_conflict"].contains(business.code) { value.state = .rejected }
            }
            value.detail = error.localizedDescription
            values = outgoing; values[id] = value
            try save(values, scope: scope); outgoing = values
            throw error
        }
    }
    func reset() { generation = UUID(); scope = nil; account = nil; device = nil; outgoing = [:]; isSending = false }
}
