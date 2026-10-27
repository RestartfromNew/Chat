import Foundation
import Combine

struct FriendRequestPush: Decodable {
    let type: String
    let unprocessedRequests: [FriendRequest]
    static func decode(_ data: Data) throws -> [FriendRequest] {
        let value = try JSONCodec.decoder().decode(Self.self, from: data)
        guard value.type == "friend.request.received", value.unprocessedRequests.count == 1 else {
            throw ClientError(message: "好友申请推送格式无效。")
        }
        let request = value.unprocessedRequests[0]
        let zero = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
        guard request.id != zero, request.requestId != zero else { throw ClientError(message: "好友申请编号无效。") }
        return value.unprocessedRequests
    }
}

/// HTTP snapshots are authoritative except for pushes/processing that happened
/// after the snapshot request started. Request UUID is the only deduplication key.
struct FriendRequestInbox {
    private(set) var values: [FriendRequest] = []
    private var arrivals: [FriendRequest] = []
    private var handled = Set<UUID>()
    private var refreshing = false
    mutating func beginSnapshot() { refreshing = true; arrivals = [] }
    mutating func receive(_ requests: [FriendRequest]) {
        for request in requests where !handled.contains(request.requestId) {
            values.removeAll { $0.requestId == request.requestId }
            values.insert(request, at: 0)
            if refreshing {
                arrivals.removeAll { $0.requestId == request.requestId }
                arrivals.append(request)
            }
        }
    }
    mutating func finishSnapshot(_ snapshot: [FriendRequest]) {
        var seen = Set<UUID>()
        values = snapshot.filter { !handled.contains($0.requestId) && seen.insert($0.requestId).inserted }
        let pending = arrivals
        refreshing = false; arrivals = []
        receive(pending)
    }
    mutating func cancelSnapshot() { refreshing = false; arrivals = [] }
    mutating func processed(_ id: UUID) {
        handled.insert(id); values.removeAll { $0.requestId == id }; arrivals.removeAll { $0.requestId == id }
    }
}

@MainActor final class FriendRequestsModel: ObservableObject {
    @Published private(set) var requests: [FriendRequest] = []
    @Published private(set) var loading = false
    @Published private(set) var processing = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    private unowned let app: AppModel
    private var inbox = FriendRequestInbox()
    private var generation = UUID()
    private var subscriptions = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var suspended = false
    private var retryNeeded = false
    init(app: AppModel) {
        self.app = app
        app.socket.friendRequestEvents.sink { [weak self] requests in
            guard let self, self.app.login != nil, !self.suspended else { return }
            self.inbox.receive(requests); self.requests = self.inbox.values
        }.store(in: &subscriptions)
        app.socket.$state.removeDuplicates().sink { [weak self] state in
            guard let self, state == .connected else { return }
            self.suspended = false; self.scheduleRefresh()
        }.store(in: &subscriptions)
    }
    func reset() {
        generation = UUID(); refreshTask?.cancel(); refreshTask = nil
        inbox = FriendRequestInbox(); requests = []; loading = false; processing = false; error = nil; notice = nil
    }
    func suspend() { generation = UUID(); suspended = true; refreshTask?.cancel(); refreshTask = nil; loading = false; processing = false; inbox.cancelSnapshot() }
    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        let epoch = generation
        refreshTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 0..<6 {
                await self.refresh()
                guard self.generation == epoch, !self.suspended, !Task.isCancelled else { break }
                if !self.retryNeeded { break }
                do { try await Task.sleep(for: .seconds(NetworkRetry.delay(attempt: attempt))) } catch { break }
            }
            if self.generation == epoch { self.refreshTask = nil }
        }
    }
    func refresh() async {
        guard !loading, app.login != nil else { return }
        let epoch = generation; loading = true; error = nil; retryNeeded = false; inbox.beginSnapshot()
        defer { if epoch == generation { loading = false } }
        do {
            let repo = app.friends
            let rows = try await app.authorized { try await repo.requests(token: $0) }
            guard epoch == generation else { return }
            try Task.checkCancellation()
            inbox.finishSnapshot(rows); requests = inbox.values
        } catch {
            guard epoch == generation else { return }
            inbox.cancelSnapshot()
            if !(error is CancellationError) {
                retryNeeded = NetworkRetry.isTransient(error)
                self.error = retryNeeded ? "好友申请暂时无法更新，将自动重试。" : error.localizedDescription
                if retryNeeded { scheduleRefresh() }
            }
        }
    }
    func process(_ id: UUID, action: FriendAction) async {
        guard !processing else { return }
        let epoch = generation; processing = true; error = nil; notice = nil
        defer { if epoch == generation { processing = false } }
        do {
            let repo = app.friends
            try await app.authorized { try await repo.process(requestID: id, action: action, token: $0) }
            guard epoch == generation else { return }
            inbox.processed(id); requests = inbox.values
            notice = action == .accepted ? "已接受申请，可在好友页下拉刷新。" : action == .rejected ? "已拒绝申请。" : "已取消申请。"
            if action == .accepted { await app.chats.reloadFriends() }
        } catch {
            guard epoch == generation else { return }
            if let api = error as? APIError, api.status == 409, api.code == "friend_request_already_processed" {
                inbox.processed(id); requests = inbox.values
                await refresh(); await app.chats.reloadFriends()
            } else if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
}
