import SwiftUI

struct SocketTestView: View {
  @EnvironmentObject private var app: AppModel
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject var console: SocketConsole
  @State private var message = "Hello from iOS test"
  @State private var error: String?
  @State private var busy = false
  var body: some View {
    List {
      Section {
        if let detail = console.lastError { NoticeView(text: detail) }
        if let url = try? app.configuration.socketURL() {
          CodeText(Text(url.absoluteString))
        }
        Label(
          console.state.rawValue, systemImage: console.state == .connected ? "wifi" : "wifi.slash")
        Text("明文调试通道，仅测试握手、心跳和服务端响应。success 不代表好友收到消息。")
          .font(DiagnosticsViewsStyle.footnoteFont).foregroundStyle(
            DiagnosticsViewsStyle.secondaryColor)
        if console.state == .disconnected {
          Button("连接 WebSocket") {
            Task { await run { try await app.connectWebSocket() } }
          }.disabled(busy)
        } else {
          Button("断开连接") { console.disconnect() }
        }
      }
      Section("发送测试帧") {
        TextField("测试内容（请勿填写隐私信息）", text: $message, axis: .vertical).lineLimit(
          DiagnosticsViewsStyle.inputLines)
        Button("发送 \(WebSocketTestFrame.type)") {
          Task { await run { try await app.sendSocketTest(message: message) } }
        }
        .disabled(console.state != .connected || busy || message.isEmpty)
        Button("测试 Ping / Pong") { Task { await run { try await console.ping() } } }
          .disabled(console.state != .connected || busy)
        if let error { NoticeView(text: error) }
      }
      Section {
        ForEach(console.events) { event in
          VStack(alignment: .leading, spacing: DiagnosticsViewsStyle.itemSpacing) {
            Text(event.date, style: .time).font(DiagnosticsViewsStyle.metadataFont).foregroundStyle(
              DiagnosticsViewsStyle.secondaryColor)
            CodeText(Text(event.text))
          }
        }
      } header: {
        HStack {
          Text("最近 100 条事件")
          Spacer()
          Button("清空") { console.clear() }
        }
      }
    }
    .navigationTitle("连接测试")
    .onChange(of: scenePhase) { _, phase in if phase == .background { console.disconnect() } }
  }
  @MainActor private func run(_ action: () async throws -> Void) async {
    busy = true
    error = nil
    defer { busy = false }
    do { try await action() } catch { self.error = error.localizedDescription }
  }
}

struct AccountView: View {
  @EnvironmentObject private var app: AppModel
  @State private var settings = false
  @State private var confirmLogout = false
  @State private var busy = false
  @State private var error: String?
  @State private var notice: String?
  var body: some View {
    Form {
      if let session = app.login {
        Section {
          PersonRow(name: session.displayName, username: session.username)
        }
      }
      Section {
        NavigationLink("我的设备与撤销") { AccountDevicesView() }
        NavigationLink("本机设备与密钥") { DeviceSetupView() }
        NavigationLink("开发调试") { ChatDiagnosticsView() }
      }
      if let error { NoticeView(text: error) }
      Section { LanguagePicker() }
      Section("服务") {
        Text(app.configuration.baseURL).font(DiagnosticsViewsStyle.footnoteFont)
        Button("服务器设置") { settings = true }
        Label("聊天：双棘轮加密", systemImage: "lock.shield")
      }
      Section {
        Button("退出登录", role: .destructive) { confirmLogout = true }
      } footer: {
        Text("退出会清除本机登录凭据并断开连接。当前后端尚无撤销 Token 的退出接口。")
      }
    }
    .disabled(busy)
    .navigationTitle("我的")
    .sheet(isPresented: $settings) {
      NavigationStack { ServerSettingsView(configuration: app.configuration) }
    }
    .confirmationDialog("退出当前账户？", isPresented: $confirmLogout) {
      Button("退出登录", role: .destructive) {
        do { try app.logout() } catch { self.error = error.localizedDescription }
      }
    }
  }
  @MainActor private func run(_ action: () async throws -> Void) async {
    busy = true
    error = nil
    notice = nil
    defer { busy = false }
    do { try await action() } catch { self.error = error.localizedDescription }
  }
}
