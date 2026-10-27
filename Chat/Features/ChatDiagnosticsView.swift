import SwiftUI

struct ChatDiagnosticsView: View {
  @EnvironmentObject private var app: AppModel
  var body: some View {
    List {
      NavigationLink("登录凭据诊断") { SessionDiagnosticsView() }
      NavigationLink("WebSocket 连接测试") { SocketTestView(console: app.socket) }
      NavigationLink("自动握手与旧版测试报文") { HandshakePreparationView(model: app.handshakePreparation) }
      NavigationLink("本地加密实验") { CryptoLabView() }
      NavigationLink("收信处理状态") { InboxDiagnosticsView(store: app.chats.store) }
      Section {
        Text("聊天使用独立版本的经典双棘轮协议。首次设备身份来自服务器目录并在本机固定；尚无带外安全码核验。旧版实验与聊天会话分开。")
          .font(ChatDiagnosticsViewStyle.footnoteFont)
      }
    }.navigationTitle("开发调试")
  }
}
struct InboxDiagnosticsView: View {
  @ObservedObject var store: ChatStore
  var body: some View {
    List {
      Text("已保存 \(store.archive.inbox.count) 个信封")
      ForEach(
        store.archive.inbox.values.sorted { $0.envelope.seq < $1.envelope.seq },
        id: \.envelope.envelopeId
      ) { item in
        VStack(alignment: .leading) {
          Text(item.envelope.envelopeId.uuidString).font(ChatDiagnosticsViewStyle.codeFont)
          Text(
            "seq \(item.envelope.seq) · \(item.acknowledged ? "已确认收到" : "待 ACK") · \(item.decrypted ? "已解密" : "未解密")"
          )
          if let error = item.error {
            Text(error).foregroundStyle(ChatDiagnosticsViewStyle.errorColor)
          }
        }.font(ChatDiagnosticsViewStyle.footnoteFont)
      }
    }.navigationTitle("收信处理状态")
  }
}

struct SessionDiagnosticsView: View {
  @EnvironmentObject private var app: AppModel
  @State private var busy = false
  @State private var error: String?
  @State private var notice: String?
  var body: some View {
    Form {
      Section("会话测试") {
        Button("验证当前 Access Token") {
          Task {
            await run {
              // Deliberately no auto-refresh: this button tests the CURRENT token.
              if let token = app.login?.accessToken { try await app.auth.verify(token: token) }
              notice = "当前 Access Token 验证通过（兼容空响应体）。"
            }
          }
        }
        Button("手动刷新 Token") {
          Task {
            await run {
              try await app.refreshAccessToken()
              notice = "Token 已刷新并写入 Keychain。"
            }
          }
        }
        if busy { ProgressView() }
        if let error { NoticeView(text: error) }
        if let notice { NoticeView(text: notice, isError: false) }
      }
    }.disabled(busy).navigationTitle("登录凭据诊断")
  }
  @MainActor private func run(_ action: () async throws -> Void) async {
    busy = true
    error = nil
    notice = nil
    defer { busy = false }
    do { try await action() } catch { self.error = error.localizedDescription }
  }
}
