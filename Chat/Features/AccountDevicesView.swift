import SwiftUI

struct AccountDevicesView: View {
  @EnvironmentObject private var app: AppModel
  @State private var devices: [FriendDevice] = []
  @State private var local: UUID?
  @State private var pendingClosure: [UUID: FriendDevice] = [:]
  @State private var selected: FriendDevice?
  @State private var password = ""
  @State private var busy = false
  @State private var notice: String?
  var body: some View {
    List {
      if let user = app.login?.user {
        NavigationLink("我的设备间消息") {
          ConversationView(friend: user, model: app.chats, store: app.chats.store)
        }
      }
      Section("活跃设备") {
        ForEach(devices) { device in
          VStack(alignment: .leading, spacing: AccountDevicesViewStyle.detailSpacing) {
            HStack {
              Text(device.deviceName)
              if device.id == local { Text("（本机）") }
            }
            Text(device.id.uuidString).font(AccountDevicesViewStyle.codeFont)
            Button("撤销设备", role: .destructive) {
              password = ""
              selected = device
            }
          }
        }
      }
      if !pendingClosure.isEmpty {
        Section("已撤销，关闭待确认") {
          ForEach(pendingClosure.values.sorted { $0.id.uuidString < $1.id.uuidString }) { device in
            Button {
              password = ""
              selected = device
            } label: {
              Text("重试关闭：") + Text(device.deviceName)
            }
          }
        }
      }
      if busy { ProgressView() }
      if let notice { Text(LocalizedStringKey(notice)).font(AccountDevicesViewStyle.footnoteFont) }
      Text("给好友发送的新消息会分别加密同步到本人的其他活跃设备。不会迁移旧历史，也不会自动转发收到的同步副本。")
        .font(AccountDevicesViewStyle.footnoteFont)
    }
    .navigationTitle("我的设备").disabled(busy)
    .toolbar { Button("刷新") { Task { await load() } } }
    .task { await load() }.refreshable { await load() }
    .sheet(item: $selected, onDismiss: { password = "" }) { device in
      NavigationStack {
        Form {
          Text("撤销“\(device.deviceName)”后，该设备将无法收发消息；此操作不能通过当前接口恢复。聊天历史和私钥保留。")
          SecureField("当前账号密码", text: $password).textContentType(.password)
          Button("确认撤销", role: .destructive) {
            let submitted = password
            password = ""
            selected = nil
            Task { await revoke(device, password: submitted) }
          }.disabled(password.isEmpty)
        }.navigationTitle("撤销设备")
          .toolbar {
            Button("取消") {
              password = ""
              selected = nil
            }
          }
      }
    }
  }
  @MainActor private func load() async {
    guard !busy, let user = app.login?.id else { return }
    busy = true
    defer { busy = false }
    do {
      let repo = app.deviceRepository
      let result = try await app.authorized { try await repo.ownDevices(token: $0) }
      try result.validate(target: user, actor: user)
      local = try app.devices.vault.load(app.deviceScope())?.deviceId
      devices = result.devices
    } catch is CancellationError {} catch { notice = error.localizedDescription }
  }
  @MainActor private func revoke(_ device: FriendDevice, password: String) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let result = try await app.revokeDevice(device.id, password: password)
      devices.removeAll { $0.id == device.id }
      notice = result.websocketClosed ? "设备已撤销，服务端连接已关闭。" : "设备已撤销，服务端关闭尚未确认；可重试关闭。"
      // Keep a 202 target available for idempotent retry, though active list omits it.
      if !result.websocketClosed {
        pendingClosure[device.id] = device
      } else {
        pendingClosure.removeValue(forKey: device.id)
      }
    } catch is CancellationError {} catch { notice = error.localizedDescription }
  }
}
