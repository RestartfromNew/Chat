import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var login: LoginResponse?
    @Published private(set) var configuration: ServerConfiguration
    @Published var startupError: String?
    @Published private(set) var identity = UUID()
    let socket = SocketConsole()
    lazy var chats = ChatCoordinator(app: self)
    let encryptedMessaging = StoredMessageOutbox()
    lazy var devices = DeviceCoordinator(sessions: chats.store)
    let handshakePreparation = HandshakePreparation()
    var deviceRepository: RemoteDeviceRepository { RemoteDeviceRepository(api: APIClient(configuration: configuration)) }
    func deviceScope() throws -> String {
        guard let login else { throw ClientError(message: "请先登录。") }
        return try DeviceKeyVault.scope(server: configuration, user: login.id)
    }
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
        let migrated = configuration.migratedWebSocket
        if migrated != configuration {
            configuration = migrated
            do {
                defaults.set(try JSONEncoder().encode(migrated), forKey: "chat.server.v1")
                if let login { try persist(login) }
            } catch { startupError = error.localizedDescription }
        }
    }
    func saveConfiguration(_ config: ServerConfiguration) throws {
        _ = try config.validatedURL(); _ = try config.socketURL()
        guard config != configuration else { return }
        try logout()
        defaults.set(try JSONEncoder().encode(config), forKey: "chat.server.v1")
        configuration = config
    }
    func connectWebSocket() async throws {
        guard let login else { throw ClientError(message: "请先登录。") }
        let current = identity
        do { try await socket.connect(configuration: configuration, token: login.accessToken) }
        catch let error as WebSocketHandshakeError where error.status == 401 {
            guard current == identity else { throw CancellationError() }
            let token = try await refreshAccessToken(rejectedToken: login.accessToken)
            guard current == identity else { throw CancellationError() }
            try await socket.connect(configuration: configuration, token: token)
        }
        guard current == identity else { throw CancellationError() }
    }

    func signIn(email: String, password: String) async throws {
        let generation = identity
        let result: LoginResponse
        if authOverride != nil { result = try await auth.login(email: email, password: password) }
        else {
            let repo = RemoteAuthRepository(api: APIClient(configuration: configuration))
            var deviceID = try devices.vault.loginDevice(server: configuration, email: email)
            var response = try await repo.login(email: email, password: password, deviceID: deviceID)
            guard generation == identity else { throw CancellationError() }
            // An older saved session has no email index. Resolve its account first,
            // then authenticate with the existing device instead of replacing its keys.
            if deviceID == nil {
                let scope = try DeviceKeyVault.scope(server: configuration, user: response.id)
                if let local = try devices.vault.load(scope), local.phase == .registered, let id = local.deviceId {
                    deviceID = id
                    response = try await repo.login(email: email, password: password, deviceID: id)
                }
            }
            guard generation == identity else { throw CancellationError() }
            try devices.vault.bindLogin(server: configuration, email: email, user: response.id,
                                       status: deviceID == nil ? nil : response.deviceStatus)
            result = response
        }
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
        handshakePreparation.reset()
        chats.reset()
        encryptedMessaging.reset()
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
                                        accessToken: result.accessToken, refreshToken: result.refreshToken, deviceStatus: session.deviceStatus)
            try persist(updated); login = updated
            return updated.accessToken
        } catch let error as APIError where error.status == 401 {
            if identity == generation { try logout() }
            throw ClientError(message: "登录已过期，请重新登录。")
        }
    }
}

extension AppModel {
    func prepareFriendHandshakes() async {
        guard let user = login?.id else { return }
        do {
            let scope = try deviceScope(), friends = self.friends, repository = deviceRepository
            await handshakePreparation.run(coordinator: devices, scope: scope, sender: user,
                friends: { try await self.authorized { try await friends.friends(token: $0) } },
                devices: { friend in try await self.authorized { try await repository.devices(friend: friend, token: $0) } },
                bundle: { friend, device in try await self.authorized { try await repository.bundle(friend: friend, device: device, token: $0) } },
                claim: { friend, device in try await self.authorized { try await repository.claim(friend: friend, device: device, token: $0) } })
        } catch { startupError = error.localizedDescription }
    }
}

extension AppModel {
    func stageEncryptedEnvelope(_ envelope: InitialEnvelope) throws {
        guard let user = login?.id, let record = try devices.vault.load(deviceScope()),
              record.phase == .registered, let device = record.deviceId else {
            throw ClientError(message: "请先登录并注册本机设备。")
        }
        try encryptedMessaging.bind(scope: deviceScope(), account: user, device: device)
        try encryptedMessaging.stage(envelope)
    }
}

extension AppModel {
    func sendSocketTest(message: String) async throws {
        guard let login else { throw ClientError(message: "请先登录。") }
        let current = identity
        do { try await socket.sendTest(message: message, id: UUID(), token: login.accessToken) }
        catch let error as SocketBusinessError where error.isAuthentication {
            guard identity == current else { throw CancellationError() }
            let token = try await refreshAccessToken(rejectedToken: login.accessToken)
            guard identity == current else { throw CancellationError() }
            try await socket.sendTest(message: message, id: UUID(), token: token)
        }
    }
    func sendPreparedEnvelope(_ envelope: InitialEnvelope) async throws {
        try stageEncryptedEnvelope(envelope)
        guard let login else { throw ClientError(message: "请先登录。") }
        let current = identity, id = envelope.header.messageId
        do {
            try await encryptedMessaging.send(id, token: login.accessToken) { try await self.socket.submitStoredFrame($0, id: $1) }
        } catch let error as SocketBusinessError where error.isAuthentication {
            guard identity == current else { throw CancellationError() }
            let token = try await refreshAccessToken(rejectedToken: login.accessToken)
            guard identity == current else { throw CancellationError() }
            try await encryptedMessaging.send(id, token: token) { try await self.socket.submitStoredFrame($0, id: $1) }
        }
    }
}

extension AppModel {
    func composeStoredMessage(template: InitialEnvelope, plaintext: String) throws -> InitialEnvelope {
        guard let sender = login?.id, sender == template.header.senderId else { throw ClientError(message: "请重新登录。") }
        let scope = try deviceScope()
        let peer = FriendDevice(deviceId: template.header.recipientDeviceId, deviceName: "目标设备", status: "active",
            identityPublicKeyHex: template.header.recipientIdentityPublicHex, protocolSuite: template.header.protocolSuite)
        guard let cached = try devices.cachedClaim(scope: scope, friend: template.header.recipientId, device: peer),
              let state = cached.check, let claim = cached.value, let local = try devices.vault.load(scope) else {
            throw ClientError(message: "请先完成公钥包和 S 准备。")
        }
        try state.bundle.validate(for: peer)
        let secret = try PrekeyVerification.derive(identity: local.identityPrivate, ephemeral: state.ephemeralPrivate,
            remoteIdentity: PrekeyVerification.hex(state.bundle.identityPublicKeyHex, bytes: 32),
            signedPrekey: PrekeyVerification.hex(state.bundle.signedPrekeyPublicHex, bytes: 32),
            oneTimePrekey: PrekeyVerification.hex(claim.publicKeyHex, bytes: 32))
        let envelope = try InitialEnvelope.make(secret: secret, sender: sender, local: local, friend: template.header.recipientId,
            device: peer, state: state, claim: claim, plaintext: plaintext)
        try stageEncryptedEnvelope(envelope)
        return envelope
    }
}

extension AppModel {
    func socketRequest(responseType: String, make: (String) throws -> Data) async throws -> Data {
        guard let login else { throw ClientError(message: "请先登录。") }
        let current = identity
        do {
            let result = try await socket.request(make(login.accessToken), responseType: responseType)
            guard current == identity else { throw CancellationError() }; return result
        } catch let error as SocketBusinessError where error.isAuthentication {
            guard current == identity else { throw CancellationError() }
            let token = try await refreshAccessToken(rejectedToken: login.accessToken)
            guard current == identity else { throw CancellationError() }
            let result = try await socket.request(make(token), responseType: responseType)
            guard current == identity else { throw CancellationError() }; return result
        }
    }
}
