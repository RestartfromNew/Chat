import Foundation
import Combine

struct SocketEvent: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}

@MainActor
final class SocketConsole: ObservableObject, EncryptedSocketTransport {
    let friendRequestEvents = PassthroughSubject<[FriendRequest], Never>()
    let onlineEnvelopes = PassthroughSubject<IncomingEnvelope, Never>()
    private(set) var connectedDeviceID: UUID?
    let incomingFrames = PassthroughSubject<Data, Never>()
    enum State: String { case disconnected = "未连接", connecting = "等待 HTTP Upgrade", connected = "已连接" }
    @Published private(set) var state: State = .disconnected
    @Published private(set) var lastError: String?
    @Published private(set) var events: [SocketEvent] = []
    private let business = WebSocketBusinessRequest()
    private var connection: WebSocketConnection?
    private var receiver: Task<Void, Never>?
    private var generation = UUID()
    private var secrets: [String] = []

    func connect(configuration: ServerConfiguration, token: String, deviceID: UUID, onRevoked: @escaping (UUID) -> Void = { _ in }) async throws {
        disconnect(); lastError = nil
        let request = try AccessTokenHeader.webSocketRequest(configuration: configuration, token: token, deviceID: deviceID)
        secrets = [token]
        let connection = WebSocketConnection()
        self.connection = connection
        let current = generation
        connection.onDeviceRevoked = { [weak self] in
            guard let self, self.generation == current else { return }
            onRevoked(deviceID)
            if self.generation == current { self.disconnect() }
        }
        state = .connecting
        append("发送带鉴权的 HTTP Upgrade：\(request.url?.absoluteString ?? "")；deviceID=\(deviceID.uuidString.lowercased())")
        do {
            try await connection.open(request)
            guard generation == current else { throw CancellationError() }
            connectedDeviceID = deviceID
            state = .connected
            append("WebSocket 握手完成：HTTP 101；可发送消息或测试 Ping。握手已鉴权；每条业务帧仍携带 Token。")
            receiver = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await connection.receive()
                        guard let self, self.generation == current else { return }
                        switch message {
                        case .string(let text):
                            self.route(Data(text.utf8))
                            self.append("收到文本帧：\(text.utf8.count) 字节")
                        case .data(let data):
                            self.route(data)
                            self.append("收到二进制帧：\(data.count) 字节")
                        @unknown default: break
                        }
                    }
                } catch {
                    guard let self, self.generation == current else { return }
                    self.fail(error, connection: connection, wasConnected: true)
                }
            }
        } catch {
            guard generation == current else { throw CancellationError() }
            fail(error, connection: connection, wasConnected: false)
            throw WebSocketHandshakeError(status: connection.httpStatus, detail: lastError ?? error.localizedDescription)
        }
    }
    private func route(_ data: Data) {
        // Route notifications before the single-flight business response matcher.
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        switch object?["type"] as? String {
        case "Online_Sync":
            do {
                guard let device = connectedDeviceID else { throw ClientError(message: "连接未绑定接收设备。") }
                onlineEnvelopes.send(try OnlineEnvelope.decode(data, device: device))
            } catch { append("在线推送被拒绝：" + error.localizedDescription) }
        case "friend.request.received":
            do {
                guard connectedDeviceID != nil else { throw ClientError(message: "连接未绑定接收设备。") }
                friendRequestEvents.send(try FriendRequestPush.decode(data))
            } catch { append("好友申请推送被拒绝：" + error.localizedDescription) }
        default: business.receive(data)
        }
        incomingFrames.send(data)
    }
    private func fail(_ error: Error, connection: WebSocketConnection, wasConnected: Bool) {
        let detail = WebSocketDiagnostics.failure(error, status: connection.httpStatus, wasConnected: wasConnected)
        lastError = detail; append(detail); disconnect()
    }
    func sendEncryptedFrame(_ data: Data) async throws {
        guard state == .connected, let connection else { throw ClientError(message: "请先连接 WebSocket。") }
        let current = generation
        try await connection.send(data)
        guard generation == current else { throw CancellationError() }
        append("加密协议帧已写入 WebSocket，等待业务回执。")
    }
    func submitStoredFrame(_ data: Data, id: UUID) async throws -> StoredMessageReceipt {
        try await submitBusiness(data, id: id, test: false)
    }
    private func submitBusiness(_ data: Data, id: UUID, test: Bool) async throws -> StoredMessageReceipt {
        guard state == .connected, let connection else { throw ClientError(message: "请先连接 WebSocket。") }
        return try await business.perform(data: data, id: id, test: test,
            send: { try await connection.send($0) }, invalidate: { [weak self] in self?.disconnect() })
    }
    func request(_ data: Data, responseType: String) async throws -> Data {
        guard state == .connected, let connection else { throw ClientError(message: "请先连接 WebSocket。") }
        return try await business.performRaw(data: data, parse: { bytes in
            try EnvelopeAPI.response(bytes, expected: responseType)
        }, send: { try await connection.send($0) }, invalidate: { [weak self] in self?.disconnect() })
    }
    func sendTest(message: String, id: UUID, token: String) async throws {
        let data = try WebSocketTestFrame.encode(message: message, id: id, token: token)
        _ = try await submitBusiness(data, id: id, test: true)
        append("测试回执成功：\(id.uuidString.lowercased())；未存储消息、未投递好友。")
    }
    func ping() async throws {
        guard state == .connected, let connection else { throw ClientError(message: "请先连接。") }
        let current = generation
        try await connection.ping()
        guard generation == current else { throw CancellationError() }
        append("Ping / Pong 成功")
    }
    func disconnect() {
        generation = UUID()
        business.cancel()
        receiver?.cancel(); receiver = nil
        connection?.close(); connection = nil
        connectedDeviceID = nil
        secrets = []
        state = .disconnected
    }
    func clear() { events = []; lastError = nil }
    private func append(_ text: String) {
        var safe = text
        for secret in secrets where !secret.isEmpty { safe = safe.replacingOccurrences(of: secret, with: "[已隐藏]") }
        events.insert(SocketEvent(text: String(safe.prefix(4000))), at: 0)
        if events.count > 100 { events.removeLast(events.count - 100) }
    }
}

struct WebSocketHandshakeError: LocalizedError {
    let status: Int?
    let detail: String
    var errorDescription: String? { detail }
}
