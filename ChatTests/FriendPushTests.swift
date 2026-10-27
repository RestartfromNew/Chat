import Foundation
import Testing
@testable import Chat

private final class PushMemoryStore: CredentialStore {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
    func delete() throws { data = nil }
}
@MainActor struct FriendPushTests {
    private func row(_ id: UUID = UUID(), message: String = "Hi") -> FriendRequest {
        FriendRequest(requestId: id, id: UUID(), username: "alice", displayName: "Alice", message: message)
    }
    @Test func actualBackendPushDecodesAndRejectsWrongShape() throws {
        let id = UUID()
        let bytes = try JSONSerialization.data(withJSONObject: ["type": "friend.request.received", "unprocessed_requests": [
            ["request_id": id.uuidString, "id": UUID().uuidString, "username": "alice", "display_name": "Alice", "message": "Hi"]]])
        let result = try FriendRequestPush.decode(bytes)
        #expect(result.count == 1 && result[0].requestId == id)
        #expect(throws: (any Error).self) { try FriendRequestPush.decode(Data(#"{"type":"friend.request.received","unprocessed_requests":"None"}"#.utf8)) }
        #expect(throws: (any Error).self) { try FriendRequestPush.decode(Data(#"{"type":"friend.request.received","unprocessed_requests":[]}"#.utf8)) }
    }
    @Test func pushUpsertsByRequestIDWithoutReplacingWholeList() {
        var inbox = FriendRequestInbox()
        let a = row(), b = row()
        inbox.receive([a]); inbox.receive([b]); inbox.receive([row(a.requestId, message: "Updated")])
        #expect(inbox.values.count == 2)
        #expect(inbox.values.first?.message == "Updated")
        #expect(inbox.values.contains { $0.requestId == b.requestId })
    }
    @Test func pushDuringSnapshotSurvivesStaleHTTPResponse() {
        var inbox = FriendRequestInbox()
        let a = row(), b = row()
        inbox.receive([a]); inbox.beginSnapshot(); inbox.receive([b])
        inbox.finishSnapshot([a, a])
        #expect(inbox.values.map(\.requestId) == [b.requestId, a.requestId])
        inbox.beginSnapshot(); inbox.finishSnapshot([])
        #expect(inbox.values.isEmpty) // An actual later snapshot can remove resolved requests.
    }
    @Test func processedRequestCannotBeResurrectedByLateSnapshotOrPush() {
        var inbox = FriendRequestInbox(); let a = row()
        inbox.receive([a]); inbox.beginSnapshot(); inbox.processed(a.requestId)
        inbox.finishSnapshot([a]); inbox.receive([a])
        #expect(inbox.values.isEmpty)
    }
    @Test func sharedInboxReceivesPushAndLogoutClearsIt() throws {
        let memory = PushMemoryStore()
        let login = LoginResponse(id: UUID(), username: "bob", displayName: "Bob", accessToken: "test", refreshToken: "test")
        memory.data = try JSONEncoder().encode(SavedSession(server: ServerConfiguration(), login: login))
        let app = AppModel(credentials: memory, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let model = app.friendRequests, a = row()
        app.socket.friendRequestEvents.send([a]); app.socket.friendRequestEvents.send([a])
        #expect(model.requests.count == 1)
        try app.logout()
        app.socket.friendRequestEvents.send([a])
        #expect(model.requests.isEmpty)
    }
    @Test func friendSpinnerStopsImmediatelyWhenDirectoryFinishes() async throws {
        let app = AppModel(credentials: PushMemoryStore(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let model = ChatCoordinator(app: app, store: ChatStore(storage: PushMemoryStore()))
        let friend = ChatUser(id: UUID(), username: "alice", displayName: "Alice")
        try await model.loadFriendDirectory {
            #expect(model.loadingFriends)
            return [friend]
        }
        #expect(!model.loadingFriends && model.friends == [friend])
        // Activity text may still describe background work; it no longer controls the popup.
        #expect(model.activity != nil)
    }
    @Test func failedOrCancelledDirectoryNeverLeavesSpinnerVisible() async throws {
        let app = AppModel(credentials: PushMemoryStore(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let model = ChatCoordinator(app: app, store: ChatStore(storage: PushMemoryStore()))
        await #expect(throws: (any Error).self) {
            try await model.loadFriendDirectory { throw URLError(.notConnectedToInternet) }
        }
        #expect(!model.loadingFriends)
        await #expect(throws: CancellationError.self) {
            try await model.loadFriendDirectory { model.reset(); return [] }
        }
        #expect(!model.loadingFriends && model.friends.isEmpty)
    }
}
