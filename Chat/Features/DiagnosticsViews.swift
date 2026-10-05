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
                Label(console.state.rawValue, systemImage: console.state == .connected ? "wifi" : "wifi.slash")
                Text("明文调试通道，仅测试握手、心跳和服务端响应。success 不代表好友收到消息。")
                    .font(.footnote).foregroundStyle(.secondary)
                if console.state == .disconnected {
                    Button("连接 WebSocket") {
                        do {
                            guard let token = app.login?.accessToken else { return }
                            error = nil
                            try console.connect(configuration: app.configuration, token: token)
                        } catch { self.error = error.localizedDescription }
                    }
                } else { Button("断开连接") { console.disconnect() } }
            }
            Section("发送测试帧") {
                TextField("测试内容（请勿填写隐私信息）", text: $message, axis: .vertical).lineLimit(2...5)
                Button("发送 chat.newTextMessage") { Task { await run { try await console.sendTest(message: message, id: UUID()) } } }
                    .disabled(console.state != .connected || busy || message.isEmpty)
                Button("测试 Ping / Pong") { Task { await run { try await console.ping() } } }
                    .disabled(console.state != .connected || busy)
                if let error { NoticeView(text: error) }
            }
            Section {
                ForEach(console.events) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(event.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                        Text(event.text).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            } header: { HStack { Text("最近 100 条事件"); Spacer(); Button("清空") { console.clear() } } }
        }
        .navigationTitle("连接测试")
        .onChange(of: scenePhase) { _, phase in if phase == .background { console.disconnect() } }
    }
    @MainActor private func run(_ action: () async throws -> Void) async {
        busy = true; error = nil
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
                    Text(session.id.uuidString.lowercased()).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            Section("会话测试") {
                Button("验证当前 Access Token") { Task { await run {
                    // Deliberately no auto-refresh: this button tests the CURRENT token.
                    if let token = app.login?.accessToken { try await app.auth.verify(token: token) }
                    notice = "当前 Access Token 验证通过（兼容空响应体）。"
                } } }
                Button("手动刷新 Token") { Task { await run {
                    try await app.refreshAccessToken(); notice = "Token 已刷新并写入 Keychain。"
                } } }
                if busy { ProgressView() }
                if let error { NoticeView(text: error) }
                if let notice { NoticeView(text: notice, isError: false) }
            }
            Section("服务") {
                Text(app.configuration.baseURL).font(.footnote)
                Button("服务器设置") { settings = true }
                Label("端到端加密：尚未接入", systemImage: "lock.open")
            }
            Section {
                Button("退出登录", role: .destructive) { confirmLogout = true }
            } footer: { Text("退出会清除本机登录凭据并断开连接。当前后端尚无撤销 Token 的退出接口。") }
        }
        .disabled(busy)
        .navigationTitle("我的")
        .sheet(isPresented: $settings) { NavigationStack { ServerSettingsView(configuration: app.configuration) } }
        .confirmationDialog("退出当前账户？", isPresented: $confirmLogout) {
            Button("退出登录", role: .destructive) {
                do { try app.logout() } catch { self.error = error.localizedDescription }
            }
        }
    }
    @MainActor private func run(_ action: () async throws -> Void) async {
        busy = true; error = nil; notice = nil
        defer { busy = false }
        do { try await action() } catch { self.error = error.localizedDescription }
    }
}
