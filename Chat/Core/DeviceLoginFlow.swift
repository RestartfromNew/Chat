import Foundation

struct LoginTicket: Decodable {
    let code: String
    let loginTicket: String
    let expiresIn: Int
    func validate() throws {
        guard code == "login_success", expiresIn > 0, loginTicket.utf8.count == 64,
              loginTicket.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ClientError(message: "登录票据格式无效，请重新登录。")
        }
    }
}
struct DeviceLoginResult: Decodable {
    let id: UUID
    let deviceId: UUID
    let deviceStatus: String
    let accessToken: String
    let refreshToken: String
    func validate(device: UUID? = nil) throws {
        let zero = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
        guard id != zero, deviceId != zero, deviceStatus == "active",
              device == nil || device == deviceId, !accessToken.isEmpty, !refreshToken.isEmpty else {
            throw ClientError(message: "设备登录响应无效或设备不匹配。")
        }
    }
}
protocol TicketLoginRepository {
    func ticket(email: String, password: String) async throws -> LoginTicket
    func verify(ticket: String, device: UUID) async throws -> DeviceLoginResult
    func register(ticket: String, keys: DeviceRegistrationRequest) async throws -> DeviceLoginResult
}
struct TicketAuthRepository: TicketLoginRepository {
    let api: APIClient
    func ticket(email: String, password: String) async throws -> LoginTicket {
        let result = try await api.decode(LoginTicket.self, path: "login_by_email", method: "POST",
            body: ["email": email, "password": password], authentication: .none)
        try result.validate(); return result
    }
    func verify(ticket: String, device: UUID) async throws -> DeviceLoginResult {
        try await api.decode(DeviceLoginResult.self, path: "device_verification", method: "POST",
            body: ["login_ticket": ticket, "device_id": device.uuidString.lowercased()], authentication: .none)
    }
    func register(ticket: String, keys: DeviceRegistrationRequest) async throws -> DeviceLoginResult {
        // Flat JSON contract; no credentials or private key material in this body.
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(keys)) as! [String: String]
        body["login_ticket"] = ticket
        return try await api.decode(DeviceLoginResult.self, path: "register_device", method: "POST", body: body, authentication: .none)
    }
}

@MainActor
struct DeviceLoginFlow {
    let vault: DeviceKeyVault
    let repository: any TicketLoginRepository
    func signIn(server: ServerConfiguration, email: String, password: String,
                check: () throws -> Void = {}) async throws -> LoginResponse {
        let ticket = try await repository.ticket(email: email, password: password)
        try ticket.validate(); try check(); try Task.checkCancellation()
        let knownScope = try vault.loginScope(server: server, email: email)
        let pending = try vault.pendingLoginScope(server: server, email: email)
        let scope = knownScope ?? pending
        var record = try vault.load(scope) ?? LocalDeviceKeys.generate()
        let result: DeviceLoginResult
        if record.phase == .registered, let device = record.deviceId {
            result = try await repository.verify(ticket: ticket.loginTicket, device: device)
            try result.validate(device: device)
            if let knownScope {
                guard try DeviceKeyVault.scope(server: server, user: result.id) == knownScope else {
                    throw ClientError(message: "设备登录返回了不匹配的账号。")
                }
            }
        } else {
            guard record.phase == .prepared else {
                throw ClientError(message: "设备注册结果不确定或设备已停用，请核实服务端设备记录，不能自动重复注册。")
            }
            let body = try record.registration(name: "iOS")
            record.phase = .submitting
            try vault.save(record, scope: scope) // Durable private keys BEFORE sending.
            do {
                result = try await repository.register(ticket: ticket.loginTicket, keys: body)
                try result.validate()
            } catch {
                // Only a definite rejection allows another registration attempt.
                if let api = error as? APIError, (400..<500).contains(api.status), api.status != 408, api.status != 409 {
                    record.phase = .prepared
                } else { record.phase = .uncertain }
                try vault.save(record, scope: scope)
                throw error
            }
            record.deviceId = result.deviceId; record.phase = .registered
            // Keep the returned ID recoverable even if promotion to account scope fails.
            try vault.save(record, scope: scope)
        }
        try vault.completeLogin(record, server: server, email: email, user: result.id, pending: knownScope == nil ? pending : nil)
        try check(); try Task.checkCancellation()
        // The new response intentionally contains no profile fields.
        return LoginResponse(id: result.id, username: "", displayName: email,
            accessToken: result.accessToken, refreshToken: result.refreshToken,
            deviceStatus: result.deviceStatus, deviceId: result.deviceId)
    }
}
