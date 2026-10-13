import SwiftUI

struct EncryptedMessageView: View {
    @EnvironmentObject private var app: AppModel
    let envelope: InitialEnvelope
    @ObservedObject var model: StoredMessageOutbox
    @ObservedObject var socket: SocketConsole
    @State private var busy = false
    @State private var plaintext = ""
    @State private var selected: InitialEnvelope?
    private var current: InitialEnvelope { selected ?? envelope }
    @State private var error: String?
    var body: some View {
        Form {
            Section("目标好友设备") {
                Text(current.header.recipientId.uuidString).font(.caption.monospaced())
                Text(current.header.recipientDeviceId.uuidString).font(.caption.monospaced())
                Text("消息 ID：\(current.header.messageId)").font(.caption.monospaced())
            }
            Section("构造新消息") {
                TextField("输入正文", text: $plaintext, axis: .vertical).lineLimit(2...6)
                Button("加密并保存新报文") {
                    do { selected = try app.composeStoredMessage(template: envelope, plaintext: plaintext); plaintext = ""; error = nil }
                    catch { self.error = error.localizedDescription }
                }.disabled(busy || model.isSending || plaintext.isEmpty)
                Text("使用当前 TEST 握手密钥派生每条消息密钥，生成新的消息编号、salt 和 nonce；尚未实现 Double Ratchet。").font(.footnote)
            }
            Section("本设备对的已保存报文") {
                ForEach(model.outgoing.values.filter { $0.envelope.header.senderDeviceId == envelope.header.senderDeviceId && $0.envelope.header.recipientDeviceId == envelope.header.recipientDeviceId }.sorted { $0.envelope.header.messageId.uuidString < $1.envelope.header.messageId.uuidString }, id: \.envelope.header.messageId) { item in
                    Button { selected = item.envelope } label: {
                        VStack(alignment: .leading) {
                            Text(item.envelope.header.messageId.uuidString).font(.caption.monospaced())
                            Text(item.state.rawValue)
                        }
                    }.disabled(busy)
                }
            }
            Section("WebSocket") {
                Text(socket.state.rawValue)
                if let detail = socket.lastError { NoticeView(text: detail) }
                Button("连接 WebSocket") { Task { await run { try await app.connectWebSocket() } } }
                    .disabled(busy || socket.state != .disconnected)
                Button("发送 / 重试原密文报文") { Task { await run {
                    try app.stageEncryptedEnvelope(current)
                    try await app.sendPreparedEnvelope(current)
                } } }.disabled(busy || socket.state != .connected || !model.canSend(current.header.messageId))
                Text("发送 chat.newTextMessage；Token 随每条请求附带。结果不确定时重发同一编号、同一密文包。").font(.footnote)
            }
            Section("发送状态") {
                Text(model.outgoing[current.header.messageId]?.state.rawValue ?? "等待载入报文")
                if let detail = model.outgoing[current.header.messageId]?.detail { Text(detail).font(.footnote) }
                Text("写入连接、服务端持久化、接收设备收到是不同状态。成功回执只表示存储完成，尚无接收方推送。").font(.footnote)
            }
            if let json = try? current.json() {
                Section { DisclosureGroup("当前密文包") { Text(json).font(.caption.monospaced()).textSelection(.enabled) } }
            }
            Section("接收入口") { Text(model.receiveStatus) }
            if let error { NoticeView(text: error) }
        }.navigationTitle("加密消息推送")
        .task { do { try app.stageEncryptedEnvelope(current) } catch { self.error = error.localizedDescription } }
    }
    @MainActor private func run(_ action: () async throws -> Void) async {
        busy = true; error = nil; defer { busy = false }
        do { try await action() } catch { self.error = error.localizedDescription }
    }
}
