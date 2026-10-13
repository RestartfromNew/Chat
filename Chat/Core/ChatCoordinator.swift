import Foundation
import Combine

@MainActor final class ChatCoordinator: ObservableObject {
    let store: ChatStore
    @Published private(set) var busy = false
    @Published var error: String?
    private unowned let app: AppModel
    private var generation = UUID()
    init(app: AppModel, store: ChatStore? = nil) { self.app = app; self.store = store ?? ChatStore() }
    func reset() { generation = UUID(); busy = false; error = nil; store.reset() }
    private func context() throws -> (String, LocalDeviceKeys, UUID) {
        guard let user = app.login?.id else { throw ClientError(message: "请先登录。") }
        let scope = try app.deviceScope()
        guard var local = try app.devices.vault.load(scope), local.phase == .registered, let device = local.deviceId else {
            throw ClientError(message: "请在“我的 → 本机设备”注册并上传预密钥。")
        }
        try store.bind(scope: scope, user: user, device: device)
        if let retired = store.retiringBootstrapMaterial(local) {
            try app.devices.vault.save(retired, scope: scope); local = retired
        }
        return (scope, local, device)
    }
    private func connection() async throws {
        if app.socket.state != .connected { try await app.connectWebSocket() }
    }
    private func run(_ action: (UUID) async throws -> Void) async {
        guard !busy else { return }
        busy = true; error = nil; let current = generation
        defer { if generation == current { busy = false } }
        do { try await action(current) }
        catch is CancellationError {} catch { if generation == current { self.error = error.localizedDescription } }
    }
    private func check(_ epoch: UUID) throws {
        guard epoch == generation else { throw CancellationError() }
        try Task.checkCancellation()
    }
    func start() async {
        // Restore durable history even if the network is unavailable. Unregistered users use setup UI.
        guard (try? context()) != nil else { return }
        await sync()
    }
    func sync() async {
        await run { epoch in
            let (_, local, device) = try context()
            try await connection()
            try check(epoch)
            // Directory failure does not prevent durable download/ACK; unknown identities stay encrypted.
            do {
                let repo = app.friends, devices = app.deviceRepository
                let friends = try await app.authorized { try await repo.friends(token: $0) }
                try check(epoch)
                for friend in friends {
                    let response = try await app.authorized { try await devices.devices(friend: friend.id, token: $0) }
                    try check(epoch)
                    guard response.friendId == friend.id else { throw ClientError(message: "好友设备目录不匹配。") }
                    try store.remember(user: friend.id, devices: response.devices)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { try check(epoch); self.error = "设备目录更新失败，部分消息将保留密文：" + error.localizedDescription }
            try store.decryptPending(local: local)
            _ = try context()
            try await flushAcks(device: device, epoch: epoch)
            for _ in 0..<100 {
                let previous = store.archive.cursors
                let bytes = try await app.socketRequest(responseType: "chat.sync.envelope.result") {
                    try EnvelopeAPI.sync(device: device, cursors: previous, token: $0)
                }
                try check(epoch)
                let page = try JSONCodec.decoder().decode(EnvelopePage.self, from: bytes)
                try page.validate(device: device)
                try store.ingest(page.envelopes, advanceCursors: true)
                try store.decryptPending(local: local)
                _ = try context()
                try await flushAcks(device: device, epoch: epoch)
                if !page.hasMore { return }
                guard store.archive.cursors != previous else { throw ClientError(message: "同步页没有推进游标，已停止重复请求。") }
                try Task.checkCancellation()
            }
            throw ClientError(message: "已保存本轮消息，请再次刷新继续同步。")
        }
    }
    private func flushAcks(device: UUID, epoch: UUID) async throws {
        let pending = store.archive.inbox.values.filter { !$0.acknowledged }.map { $0.envelope.envelopeId }
        for start in stride(from: 0, to: pending.count, by: 100) {
            let ids = Array(pending[start..<min(start + 100, pending.count)])
            let bytes = try await app.socketRequest(responseType: "chat.envelopes.ack.result") { try EnvelopeAPI.ack(device: device, ids: ids, token: $0) }
            try check(epoch)
            let ack = try JSONCodec.decoder().decode(EnvelopeAck.self, from: bytes)
            try ack.validate(device: device, requested: ids)
            try store.confirm(ack.acknowledgedIds)
            if ack.acknowledgedIds.count != ids.count { error = "部分接收确认未完成，将在下次同步重试。" }
        }
    }
    func send(_ text: String, friend: ChatUser) async -> Bool {
        guard !busy else { return false }
        var saved = false
        await run { epoch in
            let (scope, _, _) = try context()
            let repo = app.deviceRepository
            let response = try await app.authorized { try await repo.devices(friend: friend.id, token: $0) }
            try check(epoch)
            guard response.friendId == friend.id else { throw ClientError(message: "好友设备目录不匹配。") }
            let targets = response.devices.filter { $0.status == "active" }
            try store.remember(user: friend.id, devices: targets)
            var seeds: [UUID: CachedPrekey] = [:]
            for target in targets where store.session(for: target.id) == nil {
                _ = try await app.devices.prepareEnvelope(scope: scope, sender: app.login!.id, friend: friend.id, device: target,
                    fetchBundle: { try await self.app.authorized { try await repo.bundle(friend: friend.id, device: target.id, token: $0) } },
                    claim: { try await self.app.authorized { try await repo.claim(friend: friend.id, device: target.id, token: $0) } })
                try check(epoch)
                seeds[target.id] = try app.devices.cachedClaim(scope: scope, friend: friend.id, device: target)
            }
            let (_, local, _) = try context()
            let id = try store.prepareMessage(text: text, friend: friend.id, targets: targets, seeds: seeds, local: local)
            saved = true // UI clears composer after durable encryption, even if sending fails.
            _ = try context() // Retire bootstrap secrets after the atomic session/packet commit.
            try await connection()
            try check(epoch)
            try await sendPending(id, epoch: epoch)
        }
        return saved
    }
    func retry(_ id: UUID) async {
        await run { epoch in _ = try context(); try await connection(); try check(epoch); try await sendPending(id, epoch: epoch) }
    }
    private func sendPending(_ id: UUID, epoch: UUID) async throws {
        for item in store.archive.outgoing.values.filter({ $0.messageId == id && $0.receipt == nil }) {
            guard item.errorCode != "envelope_conflict" else { throw ClientError(message: "密文冲突，不能重新编号绕过。") }
            do {
                let bytes = try await app.socketRequest(responseType: "newTextMessage.result") { try self.store.outgoingFrame(item, token: $0) }
                try check(epoch)
                let receipt = try JSONCodec.decoder().decode(StoredMessageReceipt.self, from: bytes)
                try store.accepted(item, receipt: receipt)
            } catch is CancellationError { throw CancellationError() }
            catch { try check(epoch); try store.failed(item, error: error); throw error }
        }
    }
    /// Online push integration point. Backend currently defines no push event type.
    /// A future adapter must validate its frame and call this; sync remains authoritative.
    func ingestOnlinePush(_ envelopes: [IncomingEnvelope]) throws {
        let (_, local, _) = try context()
        try store.ingest(envelopes, advanceCursors: false)
        try store.decryptPending(local: local)
        _ = try context()
        // ACKs are persisted as pending and drained by the serialized sync workflow.
    }
}
