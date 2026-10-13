import Foundation

@MainActor
final class DeviceCoordinator {
    let vault: DeviceKeyVault
    private let sessions: any DeviceSessionLookup
    private var busy: Set<String> = []
    init(vault: DeviceKeyVault? = nil, sessions: (any DeviceSessionLookup)? = nil) {
        self.vault = vault ?? DeviceKeyVault(); self.sessions = sessions ?? NoDeviceSessions()
    }
    func local(_ scope: String) throws -> LocalDeviceKeys {
        if let existing = try vault.load(scope) { return existing }
        let record = try LocalDeviceKeys.generate(); try vault.save(record, scope: scope); return record
    }
    func begin(_ scope: String) throws {
        guard busy.insert(scope).inserted else { throw ClientError(message: "设备操作正在进行，请稍候。") }
    }
    func hasSession(scope: String, remote: UUID) throws -> Bool {
        guard let record = try vault.load(scope), record.phase == .registered, let local = record.deviceId else {
            throw ClientError(message: "请先注册本机设备。")
        }
        return sessions.hasSession(scope: scope, local: local, remote: remote)
    }
    func end(_ scope: String) { busy.remove(scope) }
    private func rejected(_ error: Error) -> Bool {
        guard let error = error as? APIError else { return false }
        return (400..<500).contains(error.status) && error.status != 408 && error.status != 409
    }
    func register(scope: String, name: String, send: (DeviceRegistrationRequest) async throws -> RegisteredDevice) async throws {
        try begin(scope); defer { busy.remove(scope) }
        var record = try local(scope)
        if record.phase == .registered { return }
        guard record.phase == .prepared else { throw ClientError(message: "注册结果不确定或设备不可用，请先在后端核实设备记录，勿重复注册。") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ClientError(message: "请输入设备名称。") }
        let body = try record.registration(name: name)
        record.phase = .submitting; try vault.save(record, scope: scope)
        do {
            let response = try await send(body)
            guard response.deviceStatus == "active" else { throw ClientError(message: "注册返回的设备不是 active。") }
            record.deviceId = response.deviceId; record.phase = .registered
            try vault.save(record, scope: scope)
        } catch {
            record.phase = rejected(error) ? .prepared : .uncertain
            try vault.save(record, scope: scope); throw error
        }
    }
    func upload(scope: String, send: (PrekeyUploadRequest) async throws -> PrekeyUploadResult) async throws {
        try begin(scope); defer { busy.remove(scope) }
        var record = try local(scope)
        guard record.phase == .registered, let id = record.deviceId else { throw ClientError(message: "请先注册设备；未注册设备没有一次性 prekey。") }
        guard !record.oneTimePrekeys.contains(where: { $0.upload == .submitting || $0.upload == .uncertain }) else {
            throw ClientError(message: "上次上传结果不确定，请核实后端库存；本机私钥已保留。")
        }
        if !record.oneTimePrekeys.contains(where: { $0.upload == .pending }) {
            let start = (record.oneTimePrekeys.map(\.id).max() ?? 1000) + 1
            guard start <= Int(Int32.max) - 4 else { throw ClientError(message: "Prekey ID 已耗尽。") }
            for id in start..<(start + 5) { record.oneTimePrekeys.append(LocalOneTimePrekey(id: id, privateKey: try DeviceKeyCrypto.privateKey(), upload: .pending)) }
        }
        let pending = record.oneTimePrekeys.filter { $0.upload == .pending }
        let ids = Set(pending.map(\.id))
        let body = PrekeyUploadRequest(device_id: id, prekeys: try pending.map {
            .init(prekey_id: $0.id, public_key_hex: DeviceKeyCrypto.hex(try DeviceKeyCrypto.publicKey($0.privateKey)))
        })
        for i in record.oneTimePrekeys.indices where ids.contains(record.oneTimePrekeys[i].id) { record.oneTimePrekeys[i].upload = .submitting }
        try vault.save(record, scope: scope)
        do {
            let response = try await send(body)
            guard response.deviceId == id, response.uploadedCount == ids.count else { throw ClientError(message: "上传响应与本次批次不匹配。") }
            for i in record.oneTimePrekeys.indices where ids.contains(record.oneTimePrekeys[i].id) { record.oneTimePrekeys[i].upload = .uploaded }
            try vault.save(record, scope: scope)
        } catch {
            for i in record.oneTimePrekeys.indices where ids.contains(record.oneTimePrekeys[i].id) { record.oneTimePrekeys[i].upload = rejected(error) ? .pending : .uncertain }
            try vault.save(record, scope: scope); throw error
        }
    }
    func prepare(scope: String, friend: UUID, device: FriendDevice, bundle: SignedPrekeyMaterial? = nil,
                 send: () async throws -> ClaimedPrekey) async throws -> String {
        try begin(scope); defer { busy.remove(scope) }
        var record = try local(scope)
        guard record.phase == .registered, let local = record.deviceId else { throw ClientError(message: "请先到“我的 → 本机设备与密钥”注册设备。") }
        guard device.status == "active", device.protocolSuite == DeviceKeyCrypto.suite,
              DeviceKeyCrypto.validPublicHex(device.identityPublicKeyHex) else { throw ClientError(message: "好友设备不可用、公钥无效或协议套件不兼容。") }
        if sessions.hasSession(scope: scope, local: local, remote: device.deviceId) { return "已有会话，无需领取 prekey。" }
        let key = "\(local)|\(friend)|\(device.deviceId)"
        if let cached = record.claims[key] {
            guard cached.identityHex == device.identityPublicKeyHex.lowercased(), cached.suite == device.protocolSuite else {
                throw ClientError(message: "好友设备身份密钥发生变化，请核实身份后再建立会话。")
            }
            if cached.phase == .cached, let value = cached.value { return description(value, cached: true, checked: cached.check != nil) }
            throw ClientError(message: "上次领取结果不确定，已停止重复领取。请核实服务端记录。")
        }
        try bundle?.validate(for: device)
        record.claims[key] = CachedPrekey(phase: .claiming, identityHex: device.identityPublicKeyHex.lowercased(), suite: device.protocolSuite, bundle: bundle)
        try vault.save(record, scope: scope)
        do {
            let value = try await send()
            guard value.friendId == friend, value.deviceId == device.deviceId,
                  (0...Int(Int32.max)).contains(value.prekeyId), DeviceKeyCrypto.validPublicHex(value.publicKeyHex) else {
                throw ClientError(message: "领取响应的设备、编号或公钥不符合约定。")
            }
            record.claims[key]?.phase = .cached; record.claims[key]?.value = value
            try vault.save(record, scope: scope)
            return description(value, cached: false)
        } catch {
            if rejected(error) { record.claims.removeValue(forKey: key) }
            else { record.claims[key]?.phase = .uncertain }
            try vault.save(record, scope: scope)
            if let api = error as? APIError, api.status == 404, api.code == "prekey_unavailable" {
                return "该设备暂时没有可用 prekey，请好友注册设备并上传库存后再试。"
            }
            throw error
        }
    }
    private func description(_ value: ClaimedPrekey, cached: Bool, checked: Bool = false) -> String {
        let verification = checked ? "已保存签名验证及 S 计算结果，打开详情查看。" : "签名验证：待补齐 signed prekey；S：尚未生成。"
        return "\(cached ? "复用已缓存" : "已领取") prekey #\(value.prekeyId)\n\(value.publicKeyHex)\n好友 / 设备 ID：通过；OPK 编号及 X25519 公钥：通过。\n\(verification)\n点击“验证结果与 S”查看或导入好友公钥 JSON。"
    }
}
