import Foundation

struct ChatUser: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let username: String
    let displayName: String
}

struct LoginResponse: Codable, Sendable {
    let id: UUID
    let username: String
    let displayName: String
    let accessToken: String
    let refreshToken: String
    var deviceStatus: String? = nil
    var user: ChatUser { ChatUser(id: id, username: username, displayName: displayName) }
}

struct RefreshResponse: Decodable, Sendable {
    let id: UUID
    let accessToken: String
    let refreshToken: String
}

struct FriendRequest: Decodable, Identifiable, Sendable {
    let requestId: UUID
    let id: UUID // The requester user ID, NOT the request ID.
    let username: String
    let displayName: String
    let message: String
}

struct FriendRequestsResponse: Decodable {
    let requests: [FriendRequest]
    enum CodingKeys: String, CodingKey { case unprocessedRequests }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let marker = try? values.decode(String.self, forKey: .unprocessedRequests), marker == "None" {
            requests = []
        } else {
            requests = try values.decode([FriendRequest].self, forKey: .unprocessedRequests)
        }
    }
}

struct FriendsResponse: Decodable { let friends: [ChatUser] }
enum FriendAction: String, Sendable { case accepted, rejected, cancelled }

struct APIError: LocalizedError, Sendable {
    let status: Int
    let code: String
    let message: String
    var errorDescription: String? { "\(message)（\(status) · \(code)）" }
}

struct ClientError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

enum JSONCodec {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

struct ServerConfiguration: Codable, Equatable, Sendable {
    var baseURL: String = "https://aittelegramapi.uk"
    var webSocketPath: String = "/"
    // Only switch these after the backend actually supports POST.
    var legacyGETBodies: Bool = true

    func validatedURL() throws -> URL {
        guard let url = URL(string: baseURL), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw ClientError(message: "请输入 HTTPS 服务地址，例如 https://aittelegramapi.uk，不含路径或查询参数。")
        }
        return url
    }

    func socketURL() throws -> URL {
        var parts = URLComponents(url: try validatedURL(), resolvingAgainstBaseURL: false)!
        guard webSocketPath.hasPrefix("/"), !webSocketPath.contains("?"), !webSocketPath.contains("#") else {
            throw ClientError(message: "WebSocket 路径必须以 / 开头且不含查询参数。")
        }
        parts.scheme = "wss"
        parts.path = webSocketPath
        guard let url = parts.url else { throw ClientError(message: "WebSocket 地址无效。") }
        return url
    }
}

extension ServerConfiguration {
    var migratedWebSocket: Self {
        var value = self
        if (try? validatedURL().host?.lowercased()) == "aittelegramapi.uk", ["/ws", "/websocket-test"].contains(webSocketPath) {
            value.webSocketPath = "/"
        }
        return value
    }
}
