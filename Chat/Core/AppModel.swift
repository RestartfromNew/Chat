import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var login: LoginResponse?
    @Published private(set) var configuration: ServerConfiguration
    @Published var startupError: String?
    @Published private(set) var identity = UUID()
    let socket = SocketConsole()
    private let credentials: any CredentialStore
    private let defaults: UserDefaults
    private let authOverride: (any AuthRepository)?
    private var refreshing: (id: UUID, task: Task<RefreshResponse, Error>)?
    var auth: any AuthRepository { authOverride ?? RemoteAuthRepository(api: APIClient(configuration: configuration)) }
    var friends: RemoteFriendsRepository { RemoteFriendsRepository(api: APIClient(configuration: configuration)) }

    init(credentials: any CredentialStore = KeychainStore(), defaults: UserDefaults = .standard, authRepository: (any AuthRepository)? = nil) {
        self.authOverride = authRepository
        self.credentials = credentials; self.defaults = defaults
        configuration = defaults.data(forKey: "chat.server.v1")
            .flatMap { try? JSONDecoder().decode(ServerConfiguration.self, from: $0) } ?? ServerConfiguration()
        do {
            if let data = try credentials.read() {
                let saved = try JSONDecoder().decode(SavedSession.self, from: data)
                if saved.server == configuration { login = saved.login }
            }
        } catch { startupError = error.localizedDescription }
    }
    func saveConfiguration(_ config: ServerConfiguration) throws {
        _ = try config.validatedURL(); _ = try config.socketURL()
        guard config != configuration else { return }
        try logout()
        defaults.set(try JSONEncoder().encode(config), forKey: "chat.server.v1")
        configuration = config
    }
    func signIn(email: String, password: String) async throws {
        let generation = identity
        let result = try await auth.login(email: email, password: password)
        guard generation == identity else { throw CancellationError() }
        try persist(result)
        login = result
        identity = UUID()
    }
    private func persist(_ login: LoginResponse) throws {
        try credentials.write(JSONEncoder().encode(SavedSession(server: configuration, login: login)))
    }
    func logout() throws {
        try credentials.delete()
        refreshing?.task.cancel(); refreshing = nil
        socket.disconnect(); socket.clear()
        login = nil; identity = UUID()
    }
    func authorized<T>(_ action: (String) async throws -> T) async throws -> T {
        guard let session = login else { throw ClientError(message: "请先登录。") }
        let generation = identity
        do {
            let result = try await action(session.accessToken)
            guard generation == identity else { throw CancellationError() }
            return result
        } catch let error as APIError where error.status == 401 {
            guard generation == identity else { throw CancellationError() }
            let token = try await refreshAccessToken(rejectedToken: session.accessToken)
            let result = try await action(token) // Retry once, never loop.
            guard generation == identity else { throw CancellationError() }
            return result
        }
    }
    @discardableResult
    func refreshAccessToken(rejectedToken: String? = nil) async throws -> String {
        guard let session = login else { throw ClientError(message: "请先登录。") }
        if let rejectedToken, rejectedToken != session.accessToken { return session.accessToken }
        let generation = identity
        let pending: (id: UUID, task: Task<RefreshResponse, Error>)
        if let existing = refreshing { pending = existing }
        else {
            let repository = auth
            pending = (UUID(), Task { try await repository.refresh(token: session.refreshToken) })
            refreshing = pending
        }
        defer { if refreshing?.id == pending.id { refreshing = nil } }
        do {
            let result = try await pending.task.value
            guard identity == generation else { throw CancellationError() }
            guard result.id == session.id else { throw ClientError(message: "刷新返回了不匹配的用户身份。") }
            let updated = LoginResponse(id: session.id, username: session.username, displayName: session.displayName,
                                        accessToken: result.accessToken, refreshToken: result.refreshToken)
            try persist(updated); login = updated
            return updated.accessToken
        } catch let error as APIError where error.status == 401 {
            if identity == generation { try logout() }
            throw ClientError(message: "登录已过期，请重新登录。")
        }
    }
}
