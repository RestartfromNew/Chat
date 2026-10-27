import Foundation
import Combine

@MainActor final class ChatCoordinator: ObservableObject {
    @Published private(set) var loadingFriends = false
    @Published private(set) var friends: [ChatUser] = []
    @Published private(set) var activity: String?
    @Published private(set) var waitingForNetwork = false
    private var directoryLoaded = false
    private var friendsRefreshPending = false
    private var preparedDirectory = false
    let store: ChatStore
    @Published private(set) var busy = false
    @Published var error: String?
    private unowned let app: AppModel
    private var generation = UUID()
    private let pushes = OnlineEnvelopeBuffer()
    private var subscriptions = Set<AnyCancellable>()
    private var pump: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var foreground = true
    private var reconnectAllowed = true
    private var reconnectAttempt = 0
    private var lastSync: Date?
    private var queriedUnknown = Set<UUID>()

    init(app: AppModel, store: ChatStore? = nil) {
        self.app = app; self.store = store ?? ChatStore()
        app.socket.onlineEnvelopes.sink { [weak self] value in self?.receiveOnline(value) }.store(in: &subscriptions)
        app.socket.$state.removeDuplicates().dropFirst().sink { [weak self] state in
            guard let self else { return }
            if state == .connected { self.waitingForNetwork = false }
            if state == .disconnected { self.scheduleReconnect() }
        }.store(in: &subscriptions)
    }
    func reset() {
        generation = UUID(); pump?.cancel(); pump = nil; reconnect?.cancel(); reconnect = nil
        foreground = false; reconnectAllowed = true; reconnectAttempt = 0; lastSync = nil
        friendsRefreshPending = false; friends = []; loadingFriends = false; directoryLoaded = false; preparedDirectory = false; activity = nil; waitingForNetwork = false
        queriedUnknown = []; pushes.reset(); busy = false; error = nil; store.reset()
    }
    func suspend() {
        activity = nil; loadingFriends = false; waitingForNetwork = false
        app.friendRequests.suspend()
        foreground = false; pump?.cancel(); pump = nil; reconnect?.cancel(); reconnect = nil
        app.socket.disconnect()
    }
    private func context() async throws -> (String, LocalDeviceKeys, UUID) {
        guard let user = app.login?.id else { throw ClientError(message: "请先登录。") }
        let epoch = generation, identity = app.identity, scope = try app.deviceScope()
        guard var local = try app.devices.vault.load(scope), local.phase == .registered, let device = local.deviceId else {
            throw ClientError(message: "请在“我的 → 本机设备”注册并上传预密钥。")
        }
        try await store.bind(scope: scope, user: user, device: device)
        try check(epoch)
        guard identity == app.identity else { throw CancellationError() }
        if let retired = store.retiringBootstrapMaterial(local) {
            try app.devices.vault.save(retired, scope: scope); local = retired
        }
        return (scope, local, device)
    }
    private func connection() async throws {
        guard foreground else { throw CancellationError() }
        if app.socket.state != .connected { try await app.connectWebSocket() }
    }
    private func run(_ action: (UUID) async throws -> Void) async {
        guard !busy, foreground else { return }
        busy = true; error = nil; activity = "正在同步消息…"; let current = generation
        var completed = false
        defer {
            if generation == current {
                busy = false; activity = nil
                if completed { schedulePump() }
                scheduleReconnect()
                if friendsRefreshPending {
                    friendsRefreshPending = false
                    Task { [weak self] in
                        guard let self, self.generation == current else { return }
                        await self.reloadFriends()
                    }
                }
            }
        }
        do { try await action(current); completed = true }
        catch is CancellationError {}
        catch {
            if generation == current {
                if NetworkRetry.isTransient(error) {
                    self.error = nil; waitingForNetwork = true
                    app.socket.disconnect()
                } else { self.error = error.localizedDescription; waitingForNetwork = false }
                if error is WebSocketHandshakeError, !NetworkRetry.isTransient(error) { reconnectAllowed = false }
                if let failure = error as? SocketBusinessError, failure.isSessionFailure {
                    reconnectAllowed = false
                    app.socket.disconnect()
                }
            }
        }
    }
    private func check(_ epoch: UUID) throws {
        guard epoch == generation, foreground else { throw CancellationError() }
        try Task.checkCancellation()
    }
    func start() async {
        foreground = true; reconnectAllowed = true
        guard !busy, app.login != nil else { return }
        if app.socket.state == .connected, let lastSync, Date().timeIntervalSince(lastSync) < 2 { return }
        // No synchronous archive read or duplicate preflight before the coalesced operation.
        await sync(forceDirectory: false)
    }
    private func scheduleReconnect() {
        guard foreground, reconnectAllowed, !busy, reconnect == nil, (store.device != nil || waitingForNetwork),
              app.login != nil, app.socket.state == .disconnected else { return }
        let epoch = generation
        waitingForNetwork = true
        let delay = NetworkRetry.delay(attempt: reconnectAttempt); reconnectAttempt += 1
        reconnect = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == epoch, self.foreground else { return }
            self.reconnect = nil
            await self.start() // Always backfill from durable cursors after reconnect.
        }
    }
    private func receiveOnline(_ envelope: IncomingEnvelope) {
        guard foreground, app.login != nil else { return }
        do { try pushes.append(envelope); schedulePump() }
        catch { self.error = error.localizedDescription; app.socket.disconnect() }
    }
    private func schedulePump() {
        guard foreground, !busy, pump == nil, !pushes.values.isEmpty else { return }
        let epoch = generation
        pump = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            guard let self, self.generation == epoch, self.foreground else { return }
            self.pump = nil
            await self.run { epoch in
                let (_, local, device) = try await self.context()
                try await self.connection(); try self.check(epoch)
                try await self.drainPushes(epoch: epoch)
                try await self.refreshUnknownDirectory(epoch: epoch, force: false)
                try await self.store.decryptPending(local: local, retryFailures: false)
                _ = try await self.context()
                try await self.flushAcks(device: device, epoch: epoch)
            }
        }
    }
    private func drainPushes(epoch: UUID) async throws {
        let batch = Array(pushes.values.prefix(100))
        guard !batch.isEmpty else { return }
        try await store.ingest(batch, advanceCursors: false)
        try check(epoch); pushes.removeFirst(batch.count)
        // Cursor advancement is reserved for complete sync pages, never push max(seq).
    }
    private func refreshUnknownDirectory(epoch: UUID, force: Bool) async throws {
        let unknown = Set(store.archive.inbox.values.filter { !$0.decrypted && store.archive.peers[$0.envelope.senderDeviceId] == nil }.map { $0.envelope.senderDeviceId })
        guard !unknown.isEmpty, force || !unknown.isSubset(of: queriedUnknown) else { return }
        do {
            let app = self.app, repo = app.friends, devices = app.deviceRepository
            guard let actor = app.login?.id else { throw CancellationError() }
            let own = try await app.authorized { try await devices.ownDevices(token: $0) }
            try check(epoch); try own.validate(target: actor, actor: actor)
            try await store.remember(user: actor, devices: own.devices.filter { $0.id != store.device })
            let friends = try await app.authorized { try await repo.friends(token: $0) }; try check(epoch)
            let entries = try await withThrowingTaskGroup(of: (UUID, [FriendDevice]).self) { group in
                var next = 0, results: [(UUID, [FriendDevice])] = []
                func add(_ friend: ChatUser) {
                    group.addTask {
                        let result = try await app.authorized { try await devices.devices(friend: friend.id, token: $0) }
                        try result.validate(target: friend.id, actor: actor)
                        return (friend.id, result.devices)
                    }
                }
                while next < min(4, friends.count) { add(friends[next]); next += 1 }
                while let result = try await group.next() {
                    results.append(result)
                    if next < friends.count { add(friends[next]); next += 1 }
                }
                return results
            }
            try check(epoch)
            try await store.rememberDirectory(entries)
            queriedUnknown.formUnion(unknown)
            // Previously saved unknown-device packets can now be retried.
            let (_, local, _) = try await context()
            try await store.decryptPending(local: local, retryFailures: true)
        } catch is CancellationError { throw CancellationError() }
        catch {
            try check(epoch)
            if NetworkRetry.isTransient(error) { throw error }
            self.error = "设备目录更新失败，密文已保留：" + error.localizedDescription
        }
    }
    func sync(forceDirectory: Bool = true) async {
        reconnectAllowed = true
        await run { epoch in
            try await prepareStartup(epoch: epoch)
            let (_, local, device) = try await context()
            activity = "正在连接…"
            try await connection(); try check(epoch)
            try await drainPushes(epoch: epoch)
            try await flushAcks(device: device, epoch: epoch)
            for _ in 0..<100 {
                let previous = store.archive.cursors
                let bytes = try await app.socketRequest(responseType: "chat.sync.envelope.result") {
                    try EnvelopeAPI.sync(device: device, cursors: previous, token: $0)
                }
                try check(epoch)
                let page = try JSONCodec.decoder().decode(EnvelopePage.self, from: bytes)
                try page.validate(device: device)
                if !page.envelopes.isEmpty { try await store.ingest(page.envelopes, advanceCursors: true) }
                try await drainPushes(epoch: epoch)
                try await refreshUnknownDirectory(epoch: epoch, force: forceDirectory)
                try await store.decryptPending(local: local, retryFailures: forceDirectory)
                _ = try await context()
                try await flushAcks(device: device, epoch: epoch)
                if !page.hasMore {
                    let pending = Set(store.archive.outgoing.values.filter { $0.receipt == nil && ($0.errorCode == nil || SocketBusinessError(code: $0.errorCode ?? "").isTransient) }.map(\.messageId))
                    for id in pending { try check(epoch); try await sendPending(id, epoch: epoch) }
                    try await prepareSessions(epoch: epoch)
                    lastSync = Date(); reconnectAttempt = 0; waitingForNetwork = false
                    return
                }
                guard store.archive.cursors != previous else { throw ClientError(message: "同步页没有推进游标，已停止重复请求。") }
                try check(epoch)
            }
            throw ClientError(message: "已保存本轮消息，请再次刷新继续同步。")
        }
    }
    func reloadFriends() async {
        guard !busy else { friendsRefreshPending = true; return }
        directoryLoaded = false; preparedDirectory = false
        await sync(forceDirectory: true)
    }
    func loadFriendDirectory(fetch: () async throws -> [ChatUser]) async throws {
        guard !loadingFriends else { return }
        let epoch = generation
        loadingFriends = true; activity = "正在获取好友…"
        defer { if epoch == generation { loadingFriends = false } }
        let users = try await fetch()
        try check(epoch)
        friends = users; directoryLoaded = true
    }
    private func prepareStartup(epoch: UUID) async throws {
        guard app.login != nil else { throw CancellationError() }
        if !directoryLoaded {
            let repo = app.friends
            try await loadFriendDirectory { try await self.app.authorized { try await repo.friends(token: $0) } }
        }
        let scope = try app.deviceScope(), repo = app.deviceRepository
        let local = try app.devices.local(scope)
        guard local.phase == .registered else { throw ClientError(message: "设备状态需要处理，请打开本机设备与密钥。") }
        if !local.oneTimePrekeys.contains(where: { $0.upload == .uploaded && !$0.privateKey.isEmpty }) {
            activity = "正在准备加密密钥…"
            try await app.devices.upload(scope: scope) { body in
                try await self.app.authorized { try await repo.upload(body, token: $0) }
            }
            try check(epoch)
        }
    }
    private func prepareSessions(epoch: UUID) async throws {
        guard !preparedDirectory, let actor = app.login?.id else { return }
        activity = "正在准备加密会话…"
        let (scope, _, local) = try await context(), repo = app.deviceRepository
        let targets = [actor] + friends.map(\.id).filter { $0 != actor }
        for target in targets {
            try check(epoch)
            let response = try await app.authorized { try await repo.devices(friend: target, token: $0) }
            try check(epoch); try response.validate(target: target, actor: actor)
            let devices = response.devices.filter { $0.id != local }
            try await store.remember(user: target, devices: devices)
            for device in devices where store.session(for: device.id) == nil {
                do {
                    _ = try await app.devices.prepareEnvelope(scope: scope, sender: actor, friend: target, device: device,
                        fetchBundle: { try await self.app.authorized { try await repo.bundle(friend: target, device: device.id, token: $0) } },
                        claim: { try await self.app.authorized { try await repo.claim(friend: target, device: device.id, token: $0) } })
                    try check(epoch)
                } catch {
                    try check(epoch)
                    if NetworkRetry.isTransient(error) { throw error }
                    // A peer with no bundle/OPK must not block other peers or the inbox.
                    // Sending retries preparation explicitly; uncertain claims stay protected.
                }
            }
        }
        preparedDirectory = true
    }
    private func flushAcks(device: UUID, epoch: UUID) async throws {
        let pending = store.archive.inbox.values.filter { !$0.acknowledged }.map { $0.envelope.envelopeId }
        for start in stride(from: 0, to: pending.count, by: 100) {
            let ids = Array(pending[start..<min(start + 100, pending.count)])
            let bytes = try await app.socketRequest(responseType: "chat.envelopes.ack.result") { try EnvelopeAPI.ack(device: device, ids: ids, token: $0) }
            try check(epoch)
            let ack = try JSONCodec.decoder().decode(EnvelopeAck.self, from: bytes)
            try ack.validate(device: device, requested: ids)
            if !ack.acknowledgedIds.isEmpty { try await store.confirm(ack.acknowledgedIds) }
            if ack.acknowledgedIds.count != ids.count { error = "部分接收确认未完成，将在下次同步重试。" }
        }
    }
    func send(_ text: String, friend: ChatUser) async -> Bool {
        guard !busy else { return false }
        var saved = false
        await run { epoch in
            let (scope, _, localDevice) = try await context()
            guard let actor = app.login?.id else { throw CancellationError() }
            let repo = app.deviceRepository
            let response = try await app.authorized { try await repo.devices(friend: friend.id, token: $0) }
            try check(epoch)
            try response.validate(target: friend.id, actor: actor)
            let targets = response.devices.filter { $0.status == "active" && $0.id != localDevice }
            let own = try await app.authorized { try await repo.ownDevices(token: $0) }
            try check(epoch); try own.validate(target: actor, actor: actor)
            let ownTargets = friend.id == actor ? [] : own.devices.filter { $0.id != localDevice }
            try await store.remember(user: actor, devices: ownTargets)
            try await store.remember(user: friend.id, devices: targets)
            var seeds: [UUID: CachedPrekey] = [:]
            for target in targets + ownTargets where store.session(for: target.id) == nil {
                let owner = ownTargets.contains(where: { $0.id == target.id }) ? actor : friend.id
                _ = try await app.devices.prepareEnvelope(scope: scope, sender: actor, friend: owner, device: target,
                    fetchBundle: { try await self.app.authorized { try await repo.bundle(friend: owner, device: target.id, token: $0) } },
                    claim: { try await self.app.authorized { try await repo.claim(friend: owner, device: target.id, token: $0) } })
                try check(epoch)
                seeds[target.id] = try app.devices.cachedClaim(scope: scope, friend: owner, device: target)
            }
            let (_, local, _) = try await context()
            let id = try await store.prepareMessage(text: text, friend: friend.id, targets: targets, ownTargets: ownTargets, seeds: seeds, local: local)
            saved = true // UI clears composer after durable encryption, even if sending fails.
            _ = try await context() // Retire bootstrap secrets after the atomic session/packet commit.
            try await connection()
            try check(epoch)
            try await sendPending(id, epoch: epoch)
        }
        return saved
    }
    func retry(_ id: UUID) async {
        await run { epoch in _ = try await context(); try await connection(); try check(epoch); try await sendPending(id, epoch: epoch) }
    }
    private func sendPending(_ id: UUID, epoch: UUID) async throws {
        let pending = Array(store.archive.outgoing.values.filter { $0.messageId == id && $0.receipt == nil })
        for item in pending {
            guard item.errorCode != "envelope_conflict" else { throw ClientError(message: "密文冲突，不能重新编号绕过。") }
            do {
                let bytes = try await app.socketRequest(responseType: "newTextMessage.result") { try self.store.outgoingFrame(item, token: $0) }
                try check(epoch)
                let receipt = try JSONCodec.decoder().decode(StoredMessageReceipt.self, from: bytes)
                try await store.accepted(item, receipt: receipt)
            } catch is CancellationError { throw CancellationError() }
            catch { try check(epoch); try await store.failed(item, error: error); throw error }
        }
    }

}
