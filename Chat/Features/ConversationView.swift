import SwiftUI

struct ConversationView: View {
    let friend: ChatUser
    @ObservedObject var model: ChatCoordinator
    @ObservedObject var store: ChatStore
    @State private var text = ""
    private var messages: [ChatMessage] {
        store.archive.messages.values.filter { $0.friend == friend.id }.sorted { $0.date < $1.date }
    }
    private var pending: [ChatInboxItem] {
        store.archive.inbox.values.filter { !$0.decrypted && store.archive.peers[$0.envelope.senderDeviceId]?.user == friend.id }
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if messages.isEmpty && pending.isEmpty {
                            ContentUnavailableView("开始聊天", systemImage: "bubble.left.and.bubble.right", description: Text("消息将在本机加密后发送。"))
                        }
                        ForEach(messages) { message in
                            HStack {
                                if message.outgoing { Spacer(minLength: 40) }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(message.text).textSelection(.enabled)
                                    HStack {
                                        Text(message.date, style: .time)
                                        Text(message.status)
                                    }.font(.caption2).foregroundStyle(.secondary)
                                    if message.outgoing && store.archive.outgoing.values.contains(where: { $0.messageId == message.id && $0.receipt == nil && $0.errorCode != "envelope_conflict" }) {
                                        Button("重试发送") { Task { await model.retry(message.id) } }.font(.caption).disabled(model.busy)
                                    }
                                }.padding(12).background(message.outgoing ? Color.indigo.opacity(0.14) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                                if !message.outgoing { Spacer(minLength: 40) }
                            }.id(message.id)
                        }
                        ForEach(pending, id: \.envelope.envelopeId) { item in
                            NoticeView(text: item.error ?? "密文已保存，等待解密。")
                        }
                    }.padding()
                }.refreshable { await model.sync() }
                .onChange(of: messages.count) { _, _ in if let id = messages.last?.id { reader.scrollTo(id, anchor: .bottom) } }
            }
            if let error = model.error { NoticeView(text: error).padding(.horizontal) }
            HStack(alignment: .bottom) {
                TextField("消息", text: $text, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder)
                Button { let draft = text; Task { if await model.send(draft, friend: friend), text == draft { text = "" } } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }.disabled(model.busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding()
        }
        .navigationTitle(friend.displayName).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await model.sync() } } label: { Image(systemName: "arrow.clockwise") }.disabled(model.busy)
            }
            ToolbarItem(placement: .topBarTrailing) { NavigationLink { FriendDetailView(user: friend) } label: { Image(systemName: "person.crop.circle") } }
        }
        .task { await model.sync() }
    }
}

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
                    .font(.footnote)
            }
        }.navigationTitle("开发调试")
    }
}
struct InboxDiagnosticsView: View {
    @ObservedObject var store: ChatStore
    var body: some View {
        List {
            Text("已保存 \(store.archive.inbox.count) 个信封")
            ForEach(store.archive.inbox.values.sorted { $0.envelope.seq < $1.envelope.seq }, id: \.envelope.envelopeId) { item in
                VStack(alignment: .leading) {
                    Text(item.envelope.envelopeId.uuidString).font(.caption.monospaced())
                    Text("seq \(item.envelope.seq) · \(item.acknowledged ? "已确认收到" : "待 ACK") · \(item.decrypted ? "已解密" : "未解密")")
                    if let error = item.error { Text(error).foregroundStyle(.red) }
                }.font(.footnote)
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
        }.disabled(busy).navigationTitle("登录凭据诊断")
    }
    @MainActor private func run(_ action: () async throws -> Void) async {
        busy = true; error = nil; notice = nil; defer { busy = false }
        do { try await action() } catch { self.error = error.localizedDescription }
    }
}
