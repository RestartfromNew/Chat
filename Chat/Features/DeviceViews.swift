import SwiftUI

struct DeviceSetupView: View {
  @EnvironmentObject private var app: AppModel
  @State private var name = "iPhone"
  @State private var record: LocalDeviceKeys?
  @State private var publicJSON = ""
  @State private var busy = false
  @State private var message = ""
  var body: some View {
    Form {
      Section("本机设备") {
        TextField("设备名称", text: $name)
        Text("状态：\(record?.phase.rawValue ?? "未生成")")
        if let id = record?.deviceId { CodeText(Text(id.uuidString)) }
        Text(
          "本机保留 OPK：\(record?.oneTimePrekeys.filter { !$0.privateKey.isEmpty }.count ?? 0)；确认上传：\(record?.oneTimePrekeys.filter { $0.upload == .uploaded && !$0.privateKey.isEmpty }.count ?? 0)"
        )
        Text("本机数量不是服务端剩余库存。私钥保存在 Keychain，退出登录不会删除。").font(DeviceViewsStyle.footnoteFont)
        Text("设备注册在登录时自动完成；设备不可用时请重新登录。").font(DeviceViewsStyle.footnoteFont)
        Button("生成并上传 5 个一次性 prekey") {
          Task {
            await run {
              let scope = try app.deviceScope()
              let repo = app.deviceRepository
              try await app.devices.upload(scope: scope) { body in
                try await app.authorized { try await repo.upload(body, token: $0) }
              }
              message = "上传成功，私钥已保留。"
            }
          }
        }.disabled(record?.phase != .registered)
      }
      if busy { ProgressView() }
      if !message.isEmpty {
        Section("结果") { Text(LocalizedStringKey(message)).textSelection(.enabled) }
      }
      Section("注册公钥材料（不含私钥）") {
        ShareLink("分享公钥 JSON", item: publicJSON)
        DisclosureGroup("查看公钥 JSON") { CodeText(Text(publicJSON)) }
      }
      Section {
        Text("未注册设备没有一次性 prekey。注册与上传分两步，领取好友 prekey 也不代表加密会话已经建立。").font(
          DeviceViewsStyle.footnoteFont)
      }
    }
    .disabled(busy).navigationTitle("本机设备与密钥")
    .task { do { try reload() } catch { message = error.localizedDescription } }
  }
  @MainActor private func reload() throws {
    record = try app.devices.local(app.deviceScope())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let record {
      publicJSON = String(
        decoding: try encoder.encode(record.registration(name: name)), as: UTF8.self)
    }
  }
  @MainActor private func run(_ action: () async throws -> Void) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do { try await action() } catch { message = error.localizedDescription }
    do { try reload() } catch { message = error.localizedDescription }
  }
}

struct FriendDevicesView: View {
  @EnvironmentObject private var app: AppModel
  let friend: ChatUser
  @State private var devices: [FriendDevice] = []
  @State private var results: [UUID: String] = [:]
  @State private var busy = false
  @State private var loaded = false
  @State private var error: String?
  var body: some View {
    List {
      Section {
        NavigationLink("自动握手与密文报文") { HandshakePreparationView(model: app.handshakePreparation) }
        Text("\(friend.displayName) 的设备")
        Button("刷新设备列表") { Task { await load() } }
        Text("刷新列表不领取 prekey。已有会话跳过领取；已领取的材料优先从本机缓存读取。").font(DeviceViewsStyle.footnoteFont)
      }
      if busy { ProgressView() }
      if let error { NoticeView(text: error) }
      if loaded && devices.isEmpty { Text("好友尚无已注册的活跃设备，因此没有可领取的一次性 prekey。") }
      ForEach(devices) { device in
        Section(device.deviceName) {
          Text(device.deviceId.uuidString).font(DeviceViewsStyle.codeFont)
          Text(device.protocolSuite).font(DeviceViewsStyle.captionFont)
          CodeText(Text("身份公钥：\(device.identityPublicKeyHex)"))
          Button("准备会话 / 获取 prekey") { Task { await prepare(device) } }
          NavigationLink("验证结果与 S") { PrekeyVerificationView(friend: friend, device: device) }
          if let text = results[device.id] { CodeText(Text(text)) }
        }
      }
    }.disabled(busy).navigationTitle("设备与会话准备").task { await load() }
  }
  @MainActor private func load() async {
    guard !busy else { return }
    busy = true
    error = nil
    defer { busy = false }
    do {
      let repo = app.deviceRepository
      let response = try await app.authorized {
        try await repo.devices(friend: friend.id, token: $0)
      }
      guard response.friendId == friend.id else { throw ClientError(message: "设备列表的好友 ID 不匹配。") }
      devices = response.devices
      results = [:]
      loaded = true
    } catch { self.error = error.localizedDescription }
  }
  @MainActor private func prepare(_ device: FriendDevice) async {
    guard !busy else { return }
    busy = true
    error = nil
    defer { busy = false }
    do {
      let scope = try app.deviceScope()
      let repo = app.deviceRepository
      guard let sender = app.login?.id else { throw ClientError(message: "请先登录。") }
      let envelope = try await app.devices.prepareEnvelope(
        scope: scope, sender: sender, friend: friend.id, device: device,
        fetchBundle: {
          try await app.authorized {
            try await repo.bundle(friend: friend.id, device: device.id, token: $0)
          }
        },
        claim: {
          try await app.authorized {
            try await repo.claim(friend: friend.id, device: device.id, token: $0)
          }
        })
      results[device.id] = envelope == nil ? "已有会话，无需领取。" : "Bundle 验签通过，S 和密文报文已生成。打开验证结果查看。"

    } catch { self.error = error.localizedDescription }
  }
}
