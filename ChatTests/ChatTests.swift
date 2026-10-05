import Foundation
import Testing
@testable import Chat

private actor StubTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let result: HTTPResult
    init(status: Int = 200, json: String = "") { result = HTTPResult(status: status, data: Data(json.utf8)) }
    func send(_ request: URLRequest) async throws -> HTTPResult { requests.append(request); return result }
    var last: URLRequest? { requests.last }
    var count: Int { requests.count }
}

struct ChatTests {
    @Test func emptyRequestsCompatibility() throws {
        for json in [#"{"unprocessed_requests":"None"}"#, #"{"unprocessed_requests":[]}"#] {
            let response = try JSONCodec.decoder().decode(FriendRequestsResponse.self, from: Data(json.utf8))
            #expect(response.requests.isEmpty)
        }
        #expect(throws: (any Error).self) {
            try JSONCodec.decoder().decode(FriendRequestsResponse.self, from: Data(#"{"unprocessed_requests":"unexpected"}"#.utf8))
        }
    }
    @Test func distinctRequestAndUserIDs() throws {
        let json = #"{"unprocessed_requests":[{"request_id":"11111111-1111-1111-1111-111111111111","id":"22222222-2222-2222-2222-222222222222","username":"alice","display_name":"Alice","message":"hi"}]}"#
        let record = try JSONCodec.decoder().decode(FriendRequestsResponse.self, from: Data(json.utf8)).requests[0]
        #expect(record.requestId != record.id)
        #expect(record.displayName == "Alice")
    }
    @Test func emptySuccessBody() async throws {
        let transport = StubTransport()
        let api = APIClient(configuration: ServerConfiguration(), transport: transport, legacyTransport: transport)
        try await RemoteAuthRepository(api: api).verify(token: "test-token")
        try await RemoteFriendsRepository(api: api).request(friendID: UUID(), message: "hi", token: "test-token")
        #expect(await transport.count == 2)
    }
    @Test func legacyGETAndPostSwitch() async throws {
        let standard = StubTransport(json: #"{"id":"11111111-1111-1111-1111-111111111111","username":"alice","display_name":"Alice"}"#)
        let legacy = StubTransport(json: #"{"id":"11111111-1111-1111-1111-111111111111","username":"alice","display_name":"Alice"}"#)
        var config = ServerConfiguration()
        var api = APIClient(configuration: config, transport: standard, legacyTransport: legacy)
        _ = try await RemoteFriendsRepository(api: api).search(username: "alice", token: "test-token")
        #expect(await legacy.last?.httpMethod == "GET")
        #expect(await standard.count == 0)
        let request = try #require(await legacy.last)
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer test-token")
        #expect(request.url?.path == "/find_user_by_username")
        #expect(request.url?.query == nil)
        config.legacyGETBodies = false
        api = APIClient(configuration: config, transport: standard, legacyTransport: legacy)
        _ = try await RemoteFriendsRepository(api: api).search(username: "alice", token: "test-token")
        #expect(await standard.last?.httpMethod == "POST")
    }
    @Test func processUsesRequestIDAndExactAction() async throws {
        let transport = StubTransport(json: "{}")
        let api = APIClient(configuration: ServerConfiguration(), transport: transport, legacyTransport: transport)
        let id = UUID()
        try await RemoteFriendsRepository(api: api).process(requestID: id, action: .accepted, token: "token")
        let request = try #require(await transport.last)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["request_id": id.uuidString.lowercased(), "process": "accepted"])
    }
    @Test func errorMapping() async throws {
        let transport = StubTransport(status: 409, json: #"{"error":{"code":"request_already_exists","message":"Already pending"}}"#)
        let api = APIClient(configuration: ServerConfiguration(), transport: transport, legacyTransport: transport)
        do {
            _ = try await api.request(path: "request_friendship", method: "POST")
            Issue.record("Expected error")
        } catch let error as APIError {
            #expect(error.status == 409); #expect(error.code == "request_already_exists")
        }
    }
    @Test func lengthDelimitedAndPartialHTTP() throws {
        let header = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n"
        #expect(try HTTP1ResponseParser.parse(Data((header + "{").utf8)) == nil)
        let result = try #require(try HTTP1ResponseParser.parse(Data((header + "{}").utf8)))
        #expect(result.data == Data("{}".utf8))
        #expect(throws: (any Error).self) { try HTTP1ResponseParser.parse(Data((header + "{").utf8), eof: true) }
    }
    @Test func chunkedHTTP() throws {
        let input = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n"
        let result = try #require(try HTTP1ResponseParser.parse(Data(input.utf8)))
        #expect(result.data == Data("{}".utf8))
        let invalid = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\r\n"
        #expect(throws: (any Error).self) { try HTTP1ResponseParser.parse(Data(invalid.utf8)) }
    }
    @Test func rejectsAmbiguousHTTPFraming() throws {
        for headers in ["Content-Length: 2\r\nContent-Length: 4", "Content-Length: 2\r\nTransfer-Encoding: chunked", "Content-Length: -1"] {
            #expect(throws: (any Error).self) {
                try HTTP1ResponseParser.parse(Data("HTTP/1.1 200 OK\r\n\(headers)\r\n\r\n{}".utf8))
            }
        }
    }
    @Test func closeDelimitedHTTP() throws {
        let data = Data("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\nerror".utf8)
        #expect(try HTTP1ResponseParser.parse(data) == nil)
        #expect(try HTTP1ResponseParser.parse(data, eof: true)?.status == 503)
    }
    @Test func configurationRequiresSecureOrigin() throws {
        for input in ["http://example.com", "https://user:pass@example.com", "https://example.com/login", "https://example.com?token=x"] {
            var config = ServerConfiguration(); config.baseURL = input
            #expect(throws: (any Error).self) { try config.validatedURL() }
        }
        #expect(try ServerConfiguration().socketURL().absoluteString == "wss://aittelegramapi.uk/ws")
    }
    @Test func encryptionNeverFallsBackToPlaintext() async throws {
        await #expect(throws: ClientError.self) {
            try await UnavailableEncryptionService().encrypt(Data("secret".utf8), recipient: UUID())
        }
    }
}

private final class MemoryCredentials: CredentialStore {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
    func delete() throws { data = nil }
}

private actor StubAuth: AuthRepository {
    let userID = UUID()
    var refreshes = 0
    var refreshError: Error?
    func setError(_ error: Error) { refreshError = error }
    func login(email: String, password: String) async throws -> LoginResponse {
        LoginResponse(id: userID, username: "alice", displayName: "Alice", accessToken: "old", refreshToken: "refresh")
    }
    func register(email: String, password: String, username: String, displayName: String) async throws -> ChatUser {
        ChatUser(id: userID, username: username, displayName: displayName)
    }
    func refresh(token: String) async throws -> RefreshResponse {
        refreshes += 1
        try await Task.sleep(for: .milliseconds(40))
        if let refreshError { throw refreshError }
        return RefreshResponse(id: userID, accessToken: "new", refreshToken: "refresh")
    }
    func verify(token: String) async throws {}
}

@MainActor
struct SessionTests {
    private func fixture() -> (AppModel, MemoryCredentials, StubAuth) {
        let credentials = MemoryCredentials()
        let auth = StubAuth()
        let defaults = UserDefaults(suiteName: "ChatTests.\(UUID())")!
        return (AppModel(credentials: credentials, defaults: defaults, authRepository: auth), credentials, auth)
    }
    @Test func refreshesOnceAndPersists() async throws {
        let (model, store, auth) = fixture()
        try await model.signIn(email: "a@example.com", password: "unused")
        async let first: String = model.refreshAccessToken()
        async let second: String = model.refreshAccessToken()
        let values = try await [first, second]
        #expect(values == ["new", "new"])
        #expect(await auth.refreshes == 1)
        let data = try #require(store.data)
        #expect(try JSONDecoder().decode(SavedSession.self, from: data).login.accessToken == "new")
    }
    @Test func retriesBusiness401Once() async throws {
        let (model, _, auth) = fixture()
        try await model.signIn(email: "a@example.com", password: "unused")
        var attempts = 0
        let result: String = try await model.authorized { token in
            attempts += 1
            if token == "old" { throw APIError(status: 401, code: "invalid_access_token", message: "expired") }
            return token
        }
        #expect(result == "new"); #expect(attempts == 2); #expect(await auth.refreshes == 1)
    }
    @Test func networkFailureKeepsCredentials() async throws {
        let (model, store, auth) = fixture()
        try await model.signIn(email: "a@example.com", password: "unused")
        await auth.setError(URLError(.notConnectedToInternet))
        await #expect(throws: (any Error).self) { try await model.refreshAccessToken() }
        #expect(model.login != nil); #expect(store.data != nil)
    }
    @Test func invalidRefreshLogsOut() async throws {
        let (model, store, auth) = fixture()
        try await model.signIn(email: "a@example.com", password: "unused")
        await auth.setError(APIError(status: 401, code: "invalid_refreshToken", message: "expired"))
        await #expect(throws: ClientError.self) { try await model.refreshAccessToken() }
        #expect(model.login == nil); #expect(store.data == nil)
    }
    @Test func logoutDuringRefreshCannotRestoreSession() async throws {
        let (model, store, _) = fixture()
        try await model.signIn(email: "a@example.com", password: "unused")
        let refresh = Task { try await model.refreshAccessToken() }
        await Task.yield()
        try model.logout()
        _ = await refresh.result
        #expect(model.login == nil); #expect(store.data == nil)
    }
    @Test func configurationChangeClearsSession() async throws {
        let (model, store, _) = fixture()
        try await model.signIn(email: "a@example.com", password: "unused")
        var config = model.configuration; config.baseURL = "https://example.com"
        try model.saveConfiguration(config)
        #expect(model.login == nil); #expect(store.data == nil)
    }
}
