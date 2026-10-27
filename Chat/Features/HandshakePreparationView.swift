import SwiftUI

struct HandshakePreparationView: View {
  @EnvironmentObject private var app: AppModel
  @ObservedObject var model: HandshakePreparation
  var body: some View {
    List {
      Section("登录后自动准备") {
        Text(model.status)
        if model.isRunning { ProgressView() }
        Button("重新检查好友设备") { Task { await app.prepareFriendHandshakes() } }.disabled(
          model.isRunning)
        Text("顺序：好友 → 设备 → 会话检查 → bundle 验签 → OPK → S → 加密首消息。缓存报文会复用，不反复领取 OPK。").font(
          HandshakePreparationViewStyle.footnoteFont)
        Text("测试正文：\(InitialEnvelope.testMessage)").font(HandshakePreparationViewStyle.footnoteFont)
        Text("准备过程仅生成本地报文；进入发送页可提交到服务器。").font(HandshakePreparationViewStyle.footnoteFont)
      }
      ForEach(model.entries) { entry in
        Section(entry.friend.displayName + (entry.device.map { " · " + $0.deviceName } ?? "")) {
          Text(entry.status)
          if let device = entry.device {
            NavigationLink("验证结果、S 与 envelope") {
              PrekeyVerificationView(friend: entry.friend, device: device)
            }
          }
          if let envelope = entry.envelope, let json = try? envelope.json() {
            DisclosureGroup("首消息 envelope JSON") {
              CodeText(Text(json))
            }
            ShareLink("导出密文报文", item: json)
            NavigationLink("通过 WebSocket 发送") {
              EncryptedMessageView(
                envelope: envelope, model: app.encryptedMessaging, socket: app.socket)
            }
          }
        }
      }
    }.navigationTitle("自动握手")
  }
}
