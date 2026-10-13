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
    var id: UUID { deviceId }
}
struct FriendDevicesResult: Decodable { let friendId: UUID; let devices: [FriendDevice] }
struct ClaimedPrekey: Codable { let friendId: UUID; let deviceId: UUID; let prekeyId: Int; let publicKeyHex: String }

protocol DeviceRepository {
    func bundle(friend: UUID, device: UUID, token: String) async throws -> DeviceKeyBundleResponse
    func register(_ body: DeviceRegistrationRequest, token: String) async throws -> RegisteredDevice
    func upload(_ body: PrekeyUploadRequest, token: String) async throws -> PrekeyUploadResult
    func devices(friend: UUID, token: String) async throws -> FriendDevicesResult
    func claim(friend: UUID, device: UUID, token: String) async throws -> ClaimedPrekey
}
struct RemoteDeviceRepository: DeviceRepository {
    let api: APIClient
    func register(_ body: DeviceRegistrationRequest, token: String) async throws -> RegisteredDevice {
        try await api.post(RegisteredDevice.self, path: "register_device", body: body, token: token)
    }
    func upload(_ body: PrekeyUploadRequest, token: String) async throws -> PrekeyUploadResult {
        try await api.post(PrekeyUploadResult.self, path: "upload_one_time_prekeys", body: body, token: token)
    }
    func devices(friend: UUID, token: String) async throws -> FriendDevicesResult {
        try await api.decode(FriendDevicesResult.self, path: "friend_devices", method: "POST",
                             body: ["friend_id": friend.uuidString.lowercased()], token: token)
    }
    func claim(friend: UUID, device: UUID, token: String) async throws -> ClaimedPrekey {
        try await api.decode(ClaimedPrekey.self, path: "get_one_time_prekey", method: "POST",
            body: ["friend_id": friend.uuidString.lowercased(), "device_id": device.uuidString.lowercased()], token: token)
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
            body: ["friend_id": friend.uuidString.lowercased(), "device_id": device.uuidString.lowercased()], token: token)
    }
}
