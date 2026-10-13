import Foundation

protocol AuthRepository {
    func login(email: String, password: String) async throws -> LoginResponse
    func register(email: String, password: String, username: String, displayName: String) async throws -> ChatUser
    func refresh(token: String) async throws -> RefreshResponse
    func verify(token: String) async throws
}

struct RemoteAuthRepository: AuthRepository {
    let api: APIClient
    func login(email: String, password: String) async throws -> LoginResponse {
        try await login(email: email, password: password, deviceID: nil)
    }
    func login(email: String, password: String, deviceID: UUID?) async throws -> LoginResponse {
        var body = ["email": email, "password": password]
        if let deviceID { body["device_id"] = deviceID.uuidString.lowercased() }
        return try await api.decode(LoginResponse.self, path: "login_by_email", method: "POST", body: body, authentication: .none)
    }
    func register(email: String, password: String, username: String, displayName: String) async throws -> ChatUser {
        try await api.decode(ChatUser.self, path: "register_by_email", method: "POST",
                             body: ["email": email, "password": password, "username": username, "display_name": displayName], authentication: .none)
    }
    func refresh(token: String) async throws -> RefreshResponse {
        try await api.decode(RefreshResponse.self, path: "refresh_token",
                             method: api.configuration.legacyGETBodies ? "GET" : "POST", body: ["refreshToken": token], authentication: .none)
    }
    func verify(token: String) async throws {
        _ = try await api.request(path: "verify_access_token", method: "POST", token: token)
    }
}

protocol FriendsRepository {
    func friends(token: String) async throws -> [ChatUser]
    func requests(token: String) async throws -> [FriendRequest]
    func search(username: String, token: String) async throws -> ChatUser
    func request(friendID: UUID, message: String, token: String) async throws
    func process(requestID: UUID, action: FriendAction, token: String) async throws
}

struct RemoteFriendsRepository: FriendsRepository {
    let api: APIClient
    func friends(token: String) async throws -> [ChatUser] {
        try await api.decode(FriendsResponse.self, path: "fetch_friends", token: token).friends
    }
    func requests(token: String) async throws -> [FriendRequest] {
        try await api.decode(FriendRequestsResponse.self, path: "fetch_unprocessed_friend_request", token: token).requests
    }
    func search(username: String, token: String) async throws -> ChatUser {
        try await api.decode(ChatUser.self, path: "find_user_by_username",
                             method: api.configuration.legacyGETBodies ? "GET" : "POST", body: ["username": username], token: token)
    }
    func request(friendID: UUID, message: String, token: String) async throws {
        _ = try await api.request(path: "request_friendship", method: "POST",
                                  body: ["friend_id": friendID.uuidString.lowercased(), "message": message], token: token)
    }
    func process(requestID: UUID, action: FriendAction, token: String) async throws {
        _ = try await api.request(path: "process_friendship_request", method: "POST",
                                  body: ["request_id": requestID.uuidString.lowercased(), "process": action.rawValue], token: token)
    }
}

/// Future integration boundary. No plaintext fallback and no homegrown cryptographic protocol.
protocol MessageEncryptionService {
    func encrypt(_ plaintext: Data, recipient: UUID) async throws -> Data
    func decrypt(_ ciphertext: Data, sender: UUID) async throws -> Data
}

struct UnavailableEncryptionService: MessageEncryptionService {
    func encrypt(_ plaintext: Data, recipient: UUID) async throws -> Data {
        throw ClientError(message: "端到端加密尚未接入，不能发送聊天消息。")
    }
    func decrypt(_ ciphertext: Data, sender: UUID) async throws -> Data {
        throw ClientError(message: "端到端加密尚未接入。")
    }
}
