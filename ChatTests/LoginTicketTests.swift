import Foundation
import Testing
@testable import Chat

private final class TicketMemory: CredentialStore {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
    func delete() throws { data = nil }
}
private final class TicketWire: HTTPTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    var response = Data()
    func send(_ request: URLRequest) async throws -> HTTPResult {
        requests.append(request); return HTTPResult(status: 200, data: response)
    }
}
private final class TicketStub: TicketLoginRepository {
    let user = UUID(), device = UUID()
    var registrations = 0, verifications = 0
    var failure: Error?
    var replyDevice: UUID?
    func ticket(email: String, password: String) async throws -> LoginTicket {
        LoginTicket(code: "login_success", loginTicket: String(repeating: "a", count: 64), expiresIn: 300)
    }
    func verify(ticket: String, device: UUID) async throws -> DeviceLoginResult {
        verifications += 1
        if let failure { throw failure }
        return result()
    }
    func register(ticket: String, keys: DeviceRegistrationRequest) async throws -> DeviceLoginResult {
        registrations += 1
        if let failure { throw failure }
        return result()
    }
    func result() -> DeviceLoginResult {
        DeviceLoginResult(id: user, deviceId: replyDevice ?? device, deviceStatus: "active", accessToken: "access", refreshToken: "refresh")
    }
}
@MainActor struct LoginTicketTests {
    @Test func newDeviceThenExistingDeviceKeepsPrivateKeys() async throws {
        let vault = DeviceKeyVault(store: TicketMemory()), repo = TicketStub(), server = ServerConfiguration()
        let flow = DeviceLoginFlow(vault: vault, repository: repo)
        let first = try await flow.signIn(server: server, email: "alice@example.com", password: "p")
        let scope = try DeviceKeyVault.scope(server: server, user: repo.user)
        let original = try #require(try vault.load(scope))
        #expect(first.deviceId == repo.device && first.accessToken == "access")
        #expect(original.oneTimePrekeys.isEmpty && original.phase == .registered)
        _ = try await flow.signIn(server: server, email: " ALICE@example.com ", password: "p")
        #expect(repo.registrations == 1 && repo.verifications == 1)
        #expect(try vault.load(scope)?.identityPrivate == original.identityPrivate)
        #expect(try vault.load(vault.pendingLoginScope(server: server, email: "alice@example.com")) == nil)
    }
    @Test func registrationTimeoutRetainsKeysAndBlocksDuplicateRegistration() async throws {
        let vault = DeviceKeyVault(store: TicketMemory()), repo = TicketStub(), server = ServerConfiguration()
        let flow = DeviceLoginFlow(vault: vault, repository: repo)
        repo.failure = URLError(.timedOut)
        await #expect(throws: URLError.self) { try await flow.signIn(server: server, email: "a", password: "p") }
        let pending = try vault.pendingLoginScope(server: server, email: "a")
        let original = try #require(try vault.load(pending))
        #expect(original.phase == .uncertain && !original.identityPrivate.isEmpty)
        repo.failure = nil
        await #expect(throws: ClientError.self) { try await flow.signIn(server: server, email: "a", password: "p") }
        #expect(repo.registrations == 1)
        #expect(try vault.load(pending)?.identityPrivate == original.identityPrivate)
    }
    @Test func definiteRejectionRetriesSameKeys() async throws {
        let vault = DeviceKeyVault(store: TicketMemory()), repo = TicketStub(), server = ServerConfiguration()
        let flow = DeviceLoginFlow(vault: vault, repository: repo)
        repo.failure = APIError(status: 401, code: "invalid_login_ticket", message: "expired")
        await #expect(throws: APIError.self) { try await flow.signIn(server: server, email: "a", password: "p") }
        let original = try #require(try vault.load(vault.pendingLoginScope(server: server, email: "a")))
        #expect(original.phase == .prepared)
        repo.failure = nil
        _ = try await flow.signIn(server: server, email: "a", password: "p")
        #expect(try vault.load(DeviceKeyVault.scope(server: server, user: repo.user))?.identityPrivate == original.identityPrivate)
    }
    @Test func failedExistingDeviceNeverFallsBackToRegistration() async throws {
        let vault = DeviceKeyVault(store: TicketMemory()), repo = TicketStub(), server = ServerConfiguration()
        let flow = DeviceLoginFlow(vault: vault, repository: repo)
        _ = try await flow.signIn(server: server, email: "a", password: "p")
        repo.failure = APIError(status: 403, code: "device_not_active", message: "revoked")
        await #expect(throws: APIError.self) { try await flow.signIn(server: server, email: "a", password: "p") }
        #expect(repo.registrations == 1 && repo.verifications == 1)
        repo.failure = nil; repo.replyDevice = UUID()
        await #expect(throws: ClientError.self) { try await flow.signIn(server: server, email: "a", password: "p") }
    }
    @Test func publicCompletionContractsAndNoSecretKeys() async throws {
        let wire = TicketWire(), user = UUID(), device = UUID()
        wire.response = try JSONSerialization.data(withJSONObject: ["id":user.uuidString,"device_id":device.uuidString,"device_status":"active","access_token":"a","refresh_token":"r"])
        let repo = TicketAuthRepository(api: APIClient(configuration: ServerConfiguration(), transport: wire, legacyTransport: wire))
        let ticket = String(repeating: "a", count: 64)
        _ = try await repo.verify(ticket: ticket, device: device)
        var request = try #require(wire.requests.last)
        #expect(request.httpMethod == "POST" && request.url?.path == "/device_verification")
        var body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String:String])
        #expect(body == ["login_ticket":ticket,"device_id":device.uuidString.lowercased()])
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        _ = try await repo.register(ticket: ticket, keys: LocalDeviceKeys.generate().registration(name: "iOS"))
        request = try #require(wire.requests.last)
        body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String:String])
        #expect(request.url?.path == "/register_device" && request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(body.count == 7 && body["login_ticket"] == ticket)
        #expect(body["identity_public_key_hex"]?.count == 64 && body["signed_prekey_signature_hex"]?.count == 128)
    }
}
