import Foundation
import Combine

extension DeviceCoordinator {
    func prepareEnvelope(scope: String, sender: UUID, friend: UUID, device: FriendDevice,
                         fetchBundle: () async throws -> DeviceKeyBundleResponse,
                         claim: () async throws -> ClaimedPrekey) async throws -> InitialEnvelope? {
        if try hasSession(scope: scope, remote: device.id) { return nil }
        let cached = try cachedClaim(scope: scope, friend: friend, device: device)
        if let envelope = cached?.envelope {
            guard envelope.header.senderId == sender, envelope.header.recipientId == friend,
                  envelope.header.recipientDeviceId == device.id else { throw ClientError(message: "缓存报文的路由不匹配。") }
            return envelope
        }
        let material: SignedPrekeyMaterial
        if let saved = cached?.check?.bundle ?? cached?.bundle {
            try saved.validate(for: device); material = saved
        } else { material = try await fetchBundle().material(friend: friend, device: device) }
        try Task.checkCancellation()
        _ = try await prepare(scope: scope, friend: friend, device: device, bundle: material, send: claim)
        try Task.checkCancellation()
        if try hasSession(scope: scope, remote: device.id) { return nil }
        guard try cachedClaim(scope: scope, friend: friend, device: device) != nil else {
            throw ClientError(message: "好友设备暂时没有 OPK；补充库存后可重试。")
        }
        let json = String(decoding: try InitialEnvelope.encoder().encode(material), as: UTF8.self)
        _ = try verifyPrekey(scope: scope, friend: friend, device: device, json: json)
        return try sealInitialEnvelope(scope: scope, sender: sender, friend: friend, device: device)
    }
    private func sealInitialEnvelope(scope: String, sender: UUID, friend: UUID, device: FriendDevice) throws -> InitialEnvelope {
        try begin(scope); defer { end(scope) }
        guard var cached = try cachedClaim(scope: scope, friend: friend, device: device), let state = cached.check,
              let claim = cached.value, var record = try vault.load(scope), let localID = record.deviceId else {
            throw ClientError(message: "尚未完成公钥包验证。")
        }
        if let existing = cached.envelope { return existing }
        let secret = try PrekeyVerification.derive(identity: record.identityPrivate, ephemeral: state.ephemeralPrivate,
            remoteIdentity: PrekeyVerification.hex(state.bundle.identityPublicKeyHex, bytes: 32),
            signedPrekey: PrekeyVerification.hex(state.bundle.signedPrekeyPublicHex, bytes: 32),
            oneTimePrekey: PrekeyVerification.hex(claim.publicKeyHex, bytes: 32))
        let envelope = try InitialEnvelope.make(secret: secret, sender: sender, local: record, friend: friend, device: device, state: state, claim: claim)
        cached.envelope = envelope
        record.claims["\(localID)|\(friend)|\(device.id)"] = cached
        try vault.save(record, scope: scope)
        return envelope
    }
}

@MainActor
final class HandshakePreparation: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let friend: ChatUser
        let device: FriendDevice?
        let status: String
        let envelope: InitialEnvelope?
    }
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var status = "等待登录后准备"
    @Published private(set) var isRunning = false
    private var runID: UUID?
    func reset() { runID = nil; isRunning = false; entries = []; status = "等待登录后准备" }
    func run(coordinator: DeviceCoordinator, scope: String, sender: UUID,
             friends: () async throws -> [ChatUser], devices: (UUID) async throws -> FriendDevicesResult,
             bundle: (UUID, UUID) async throws -> DeviceKeyBundleResponse,
             claim: (UUID, UUID) async throws -> ClaimedPrekey) async {
        guard !isRunning else { return }
        let generation = UUID(); runID = generation; isRunning = true; entries = []
        defer { if runID == generation { isRunning = false } }
        func check() throws {
            try Task.checkCancellation()
            guard runID == generation else { throw CancellationError() }
        }
        do {
            guard let local = try coordinator.vault.load(scope), local.phase == .registered else {
                status = "本机尚未注册：请到本机设备与密钥注册，成功后会自动继续。"; return
            }
            status = "正在获取好友"
            let users = try await friends(); try check()
            for friend in users {
                status = "正在准备 \(friend.displayName) 的设备"
                do {
                    let list = try await devices(friend.id); try check()
                    guard list.friendId == friend.id, Set(list.devices.map(\.id)).count == list.devices.count else {
                        throw ClientError(message: "好友设备列表归属错误或设备重复。")
                    }
                    if list.devices.isEmpty {
                        entries.append(Entry(friend: friend, device: nil, status: "好友没有已注册设备，不领取 OPK。", envelope: nil))
                    }
                    for device in list.devices {
                        try check()
                        do {
                            let envelope = try await coordinator.prepareEnvelope(scope: scope, sender: sender, friend: friend.id, device: device,
                                fetchBundle: { try check(); return try await bundle(friend.id, device.id) },
                                claim: { try check(); return try await claim(friend.id, device.id) })
                            try check()
                            entries.append(Entry(friend: friend, device: device,
                                status: envelope == nil ? "已有会话，跳过 bundle / OPK。" : "验签通过，S 与首消息密文已准备（尚未发送）。", envelope: envelope))
                        } catch {
                            try check()
                            entries.append(Entry(friend: friend, device: device, status: error.localizedDescription, envelope: nil))
                        }
                    }
                } catch {
                    try check()
                    entries.append(Entry(friend: friend, device: nil, status: error.localizedDescription, envelope: nil))
                }
            }
            status = users.isEmpty ? "暂无好友，无需准备握手。" : "准备流程结束；每个设备的结果见下方。"
        } catch {
            if runID == generation { status = error is CancellationError ? "准备已取消" : error.localizedDescription }
        }
    }
}
