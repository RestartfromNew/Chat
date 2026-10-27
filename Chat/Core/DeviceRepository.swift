import Foundation

// Explicit snake_case for request fields; string SPK ID versus integer OPK ID is intentional.
struct DeviceRegistrationRequest: Encodable {
    let device_name: String
    let protocol_suite: String
    let identity_public_key_hex: String
    let signed_prekey_id: String
    let signed_prekey_public_hex: String
    let signed_prekey_signature_hex: String
}
struct RegisteredDevice: Decodable { let deviceId: UUID; let deviceStatus: String }
struct PrekeyUploadRequest: Encodable {
    struct Key: Encodable { let prekey_id: Int; let public_key_hex: String }
    let device_id: UUID
    let prekeys: [Key]
}
struct PrekeyUploadResult: Decodable { let deviceId: UUID; let uploadedCount: Int }
struct FriendDevice: Codable, Identifiable {
    let deviceId: UUID
    let deviceName: String
    let status: String
    let identityPublicKeyHex: String
    let protocolSuite: String
    var userId: UUID? = nil
    var isOwnDevice: Bool? = nil
    var id: UUID { deviceId }
}
struct FriendDevicesResult: Decodable {
    let friendId: UUID
    let devices: [FriendDevice]
    var targetUserId: UUID? = nil
    var isOwnDevice: Bool? = nil
    func validate(target: UUID, actor: UUID) throws {
        guard friendId == target, targetUserId == nil || targetUserId == target,
              isOwnDevice == nil || isOwnDevice == (target == actor),
              Set(devices.map(\.id)).count == devices.count,
              devices.allSatisfy({ $0.status == "active" && ($0.userId == nil || $0.userId == target) &&
                  ($0.isOwnDevice == nil || $0.isOwnDevice == (target == actor)) }) else {
            throw ClientError(message: "设备目录归属或状态不匹配。")
        }
    }
}
struct ClaimedPrekey: Codable { let friendId: UUID; let deviceId: UUID; let prekeyId: Int; let publicKeyHex: String }

protocol DeviceRepository {
    func bundle(friend: UUID, device: UUID, token: String) async throws -> DeviceKeyBundleResponse
    func upload(_ body: PrekeyUploadRequest, token: String) async throws -> PrekeyUploadResult
    func devices(friend: UUID, token: String) async throws -> FriendDevicesResult
    func claim(friend: UUID, device: UUID, token: String) async throws -> ClaimedPrekey
}
struct RemoteDeviceRepository: DeviceRepository {
    let api: APIClient
    func upload(_ body: PrekeyUploadRequest, token: String) async throws -> PrekeyUploadResult {
        try await api.post(PrekeyUploadResult.self, path: "upload_one_time_prekeys", body: body, token: token)
    }
    func devices(friend: UUID, token: String) async throws -> FriendDevicesResult {
        try await api.decode(FriendDevicesResult.self, path: "user_devices", method: "POST",
                             body: ["target_user_id": friend.uuidString.lowercased()], token: token)
    }
    func claim(friend: UUID, device: UUID, token: String) async throws -> ClaimedPrekey {
        try await api.decode(ClaimedPrekey.self, path: "get_one_time_prekey", method: "POST",
            body: ["target_user_id": friend.uuidString.lowercased(), "device_id": device.uuidString.lowercased()], token: token)
    }
}

/// Real protocol session storage can implement this later. Claiming a key NEVER creates a session.
@MainActor
protocol DeviceSessionLookup {
    func hasSession(scope: String, local: UUID, remote: UUID) -> Bool
}
struct NoDeviceSessions: DeviceSessionLookup {
    func hasSession(scope: String, local: UUID, remote: UUID) -> Bool { false }
}

struct DeviceKeyBundleResponse: Decodable {
    let friendId: UUID
    let deviceId: UUID
    let signedPrekeyId: Int64
    let signedPrekeyPublicHex: String
    let signedPrekeySignatureHex: String
    let isCurrent: Bool
    func material(friend: UUID, device: FriendDevice) throws -> SignedPrekeyMaterial {
        guard friendId == friend, deviceId == device.id, isCurrent, signedPrekeyId >= 0 else {
            throw ClientError(message: "Bundle 的好友、设备、编号或当前版本标记不匹配。")
        }
        let value = SignedPrekeyMaterial(protocolSuite: device.protocolSuite, identityPublicKeyHex: device.identityPublicKeyHex,
            signedPrekeyId: String(signedPrekeyId), signedPrekeyPublicHex: signedPrekeyPublicHex,
            signedPrekeySignatureHex: signedPrekeySignatureHex)
        try value.validate(for: device)
        return value
    }
}
extension RemoteDeviceRepository {
    func bundle(friend: UUID, device: UUID, token: String) async throws -> DeviceKeyBundleResponse {
        try await api.decode(DeviceKeyBundleResponse.self, path: "get_device_key_bundle", method: "POST",
            body: ["target_user_id": friend.uuidString.lowercased(), "device_id": device.uuidString.lowercased()], token: token)
    }
}

struct DeviceRevocation: Decodable {
    let deviceId: UUID
    let status: String
    let alreadyRevoked: Bool
    let websocketClosed: Bool
    func validate(device: UUID) throws {
        guard deviceId == device, status == "revoked" else { throw ClientError(message: "撤销响应与目标设备不匹配。") }
    }
}
extension RemoteDeviceRepository {
    func ownDevices(token: String) async throws -> FriendDevicesResult {
        try await api.decode(FriendDevicesResult.self, path: "user_devices", method: "POST", body: [:], token: token)
    }
    func revoke(device: UUID, password: String, token: String) async throws -> DeviceRevocation {
        guard !password.isEmpty else { throw ClientError(message: "请输入当前密码。") }
        let result = try await api.decode(DeviceRevocation.self, path: "revoke_device", method: "POST",
            body: ["deviceID": device.uuidString.lowercased(), "password": password], token: token)
        try result.validate(device: device)
        return result
    }
}
