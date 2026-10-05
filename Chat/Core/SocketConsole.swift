import Foundation

struct SocketEvent: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}

@MainActor
final class SocketConsole: ObservableObject {
    enum State: String { case disconnected = "未连接", connecting = "连接中", connected = "已连接" }
    @Published private(set) var state: State = .disconnected
    @Published private(set) var events: [SocketEvent] = []
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var generation = UUID()
    private var secrets: [String] = []
    private let session = URLSession(configuration: .ephemeral)

    func connect(configuration: ServerConfiguration, token: String) throws {
        disconnect()
        var request = URLRequest(url: try configuration.socketURL())
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.timeoutInterval = 20
        secrets = [token]
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1024 * 1024
        self.socket = socket
        state = .connecting
        let current = generation
        socket.resume()
        append("正在建立连接…")
        receiver = Task { [weak self] in
            do {
                // A successful pong confirms an established WebSocket, not just resume().
                try await socket.awaitPong()
                guard let self, self.generation == current else { return }
                self.state = .connected
                self.append("连接成功；当前测试通道发送明文，不代表端到端加密。")
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard self.generation == current else { return }
                    switch message {
                    case .string(let text): self.append("收到：\(text)")
                    case .data(let data): self.append("收到二进制数据：\(data.count) 字节")
                    @unknown default: self.append("收到未知消息类型")
                    }
                }
            } catch {
                guard let self, self.generation == current else { return }
                self.append("连接结束：\(error.localizedDescription)")
                self.disconnect()
            }
        }
    }
    func sendTest(message: String, id: UUID) async throws {
        guard state == .connected, let socket else { throw ClientError(message: "请先连接 WebSocket。") }
        guard !message.isEmpty, message.utf8.count <= 4096 else { throw ClientError(message: "测试内容需为 1–4096 字节。") }
        // The backend creates header/payload_format/payload internally; send only this object.
        let data = try JSONSerialization.data(withJSONObject: ["type": "chat.newTextMessage",
            "id": id.uuidString.lowercased(), "message": message])
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        append("已提交测试帧 \(id.uuidString.lowercased())；等待服务端响应，非好友送达确认。")
    }
    func ping() async throws {
        guard state == .connected, let socket else { throw ClientError(message: "请先连接。") }
        try await socket.awaitPong()
        append("Ping / Pong 成功")
    }
    func disconnect() {
        generation = UUID()
        receiver?.cancel(); receiver = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        state = .disconnected
    }
    func clear() { events = [] }
    private func append(_ text: String) {
        var safe = text
        for secret in secrets where !secret.isEmpty { safe = safe.replacingOccurrences(of: secret, with: "[已隐藏]") }
        events.insert(SocketEvent(text: String(safe.prefix(4000))), at: 0)
        if events.count > 100 { events.removeLast(events.count - 100) }
    }
}

private extension URLSessionWebSocketTask {
    func awaitPong() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
