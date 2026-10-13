import Foundation

struct StoredMessageReceipt: Codable, Equatable {
    let messageId: UUID
    let envelopeId: UUID
    let seq: Int64
    let duplicate: Bool
}
struct SocketBusinessError: LocalizedError {
    let code: String
    var errorDescription: String? { "WebSocket 业务错误：\(code)" }
    var isAuthentication: Bool { ["missing_authorization", "invalid_access_token", "access_token_expired"].contains(code) }
}
enum StoredMessageProtocol {
    static let version = "Chat-Initial-Envelope-JSON-v1"
    static func encode(_ envelope: InitialEnvelope, packet: Data, token: String) throws -> Data {
        var validation = URLRequest(url: URL(string: "https://localhost")!)
        try AccessTokenHeader.apply(token, to: &validation)
        guard !packet.isEmpty, packet.count <= 65536,
              envelope.header.senderDeviceId != envelope.header.recipientDeviceId else {
            throw ClientError(message: "密文包必须为 1–65536 字节且目标设备不同于发送设备。")
        }
        return try JSONSerialization.data(withJSONObject: [
            "type": "chat.newTextMessage", "authorization": "Bearer " + token,
            "sender_device_id": envelope.header.senderDeviceId.uuidString.lowercased(),
            "message_id": envelope.header.messageId.uuidString.lowercased(),
            "recipient_device_id": envelope.header.recipientDeviceId.uuidString.lowercased(),
            "protocol_version": version, "packet_base64": packet.base64EncodedString()
        ], options: [.sortedKeys])
    }
    static func response(_ data: Data, id: UUID, test: Bool) throws -> StoredMessageReceipt? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = object["type"] as? String else { return nil }
        guard type == "error" || type == "newTextMessage.result" else { return nil }
        if type == "error" || (object["success"] as? Bool) == false {
            let code = (object["error"] as? [String: Any])?["code"] as? String ?? "invalid_response"
            throw SocketBusinessError(code: code) // No IDs on failures: one request per connection.
        }
        guard object["success"] as? Bool == true else { throw SocketBusinessError(code: "invalid_response") }
        if test {
            guard let value = object["id"] as? String, UUID(uuidString: value) == id else { return nil }
            return StoredMessageReceipt(messageId: id, envelopeId: id, seq: 0, duplicate: false)
        }
        guard let value = object["message_id"] as? String, UUID(uuidString: value) == id else { return nil }
        let result = try JSONCodec.decoder().decode(StoredMessageReceipt.self, from: data)
        guard result.seq > 0 else { throw SocketBusinessError(code: "invalid_sequence") }
        return result
    }
}

/// Serializes ALL business traffic, because backend errors have no request correlation ID.
@MainActor
final class WebSocketBusinessRequest {
    private var pending: (operation: UUID, parse: (Data) throws -> Data?, invalidate: () -> Void, continuation: CheckedContinuation<Data, Error>)?
    private var timeout: Task<Void, Never>?
    var isBusy: Bool { pending != nil }
    func perform(data: Data, id: UUID, test: Bool = false, duration: Duration = .seconds(20),
                 send: @escaping (Data) async throws -> Void, invalidate: @escaping () -> Void) async throws -> StoredMessageReceipt {
        let result = try await performRaw(data: data, duration: duration, parse: { data in
            guard let receipt = try StoredMessageProtocol.response(data, id: id, test: test) else { return nil }
            return try JSONEncoder().encode(receipt)
        }, send: send, invalidate: invalidate)
        return try JSONDecoder().decode(StoredMessageReceipt.self, from: result)
    }
    func performRaw(data: Data, duration: Duration = .seconds(20), parse: @escaping (Data) throws -> Data?,
                    send: @escaping (Data) async throws -> Void, invalidate: @escaping () -> Void) async throws -> Data {
        guard pending == nil else { throw ClientError(message: "上一条消息仍在等待回执，请稍候。") }
        try Task.checkCancellation()
        let operation = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = (operation, parse, invalidate, continuation)
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: duration) } catch { return }
                    guard let self, self.pending?.operation == operation else { return }
                    self.finish(.failure(URLError(.timedOut)))
                    invalidate() // Late uncorrelated errors must never reach the next request.
                }
                Task { [weak self] in
                    guard self?.pending?.operation == operation else { return }
                    do { try await send(data) }
                    catch {
                        guard self?.pending?.operation == operation else { return }
                        self?.finish(.failure(error)); invalidate()
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.pending?.operation == operation else { return }
                self?.finish(.failure(CancellationError())); invalidate()
            }
        }
    }
    func receive(_ data: Data) {
        guard let pending else { return }
        do {
            if let receipt = try pending.parse(data) { finish(.success(receipt)) }
        } catch {
            finish(.failure(error))
            if let error = error as? SocketBusinessError,
               !["invalid_response", "invalid_sequence"].contains(error.code) { return }
            pending.invalidate()
        }
    }
    func cancel() { finish(.failure(URLError(.networkConnectionLost))) }
    private func finish(_ result: Result<Data, Error>) {
        guard let active = pending else { return }
        pending = nil; timeout?.cancel(); timeout = nil
        active.continuation.resume(with: result)
    }
}
