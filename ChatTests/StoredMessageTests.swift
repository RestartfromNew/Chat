import Foundation
import Testing
@testable import Chat

private final class OutboxMemory: CredentialStore {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
    func delete() throws { data = nil }
}
@MainActor struct StoredMessageTests {
    private func envelope() -> InitialEnvelope {
        InitialEnvelope(header: .init(version: 1, type: "prekey_message", protocolSuite: DeviceKeyCrypto.suite,
            handshakeKdf: PrekeyVerification.info, messageKdf: InitialEnvelope.messageInfo, cipher: "ChaCha20-Poly1305",
            messageId: UUID(), senderId: UUID(), senderDeviceId: UUID(), recipientId: UUID(), recipientDeviceId: UUID(),
            senderIdentityPublicHex: "fixture", senderEphemeralPublicHex: "fixture", recipientIdentityPublicHex: "fixture",
            signedPrekeyId: "42", oneTimePrekeyId: 1, saltHex: "fixture"), aadBase64: "", nonceHex: "", ciphertextBase64: "", tagHex: "")
    }
    private func bind(_ model: StoredMessageOutbox, _ e: InitialEnvelope) throws {
        try model.bind(scope: "account-server-device", account: e.header.senderId, device: e.header.senderDeviceId)
    }
    private func receipt(_ id: UUID) -> StoredMessageReceipt { .init(messageId: id, envelopeId: UUID(), seq: 3, duplicate: true) }
    private func response(_ id: UUID) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "newTextMessage.result", "success": true,
            "message_id": id.uuidString, "envelope_id": UUID().uuidString, "seq": 3, "duplicate": true])
    }
    @Test func wireAndReceiptContract() throws {
        let e = envelope(), packet = try InitialEnvelope.encoder().encode(e)
        let data = try StoredMessageProtocol.encode(e, packet: packet, token: "fake-token")
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(Set(object.keys) == Set(["type", "authorization", "sender_device_id", "message_id", "recipient_device_id", "protocol_version", "packet_base64"]))
        #expect(object["type"] == "chat.newTextMessage")
        #expect(object["authorization"] == "Bearer fake-token")
        #expect(Data(base64Encoded: object["packet_base64"]!) == packet)
        let result = try #require(try StoredMessageProtocol.response(response(e.header.messageId), id: e.header.messageId, test: false))
        #expect(result.seq == 3 && result.duplicate)
        #expect(try StoredMessageProtocol.response(response(UUID()), id: e.header.messageId, test: false) == nil)
    }
    @Test func durableRetryAndReceiptAcrossRestart() async throws {
        let store = OutboxMemory(), e = envelope(), id = e.header.messageId
        let first = StoredMessageOutbox(store: store)
        try bind(first, e); try first.stage(e)
        let packet = first.outgoing[id]?.packet
        do {
            try await first.send(id, token: "old-token") { _, _ in
                let restart = StoredMessageOutbox(store: store); try bind(restart, e)
                #expect(restart.outgoing[id]?.state == .uncertain)
                throw URLError(.networkConnectionLost)
            }
            Issue.record("Expected ambiguous failure")
        } catch {}
        let restored = StoredMessageOutbox(store: store); try bind(restored, e)
        #expect(restored.canSend(id))
        try await restored.send(id, token: "new-token") { frame, sentID in
            let json = try #require(JSONSerialization.jsonObject(with: frame) as? [String: String])
            #expect(sentID == id && json["authorization"] == "Bearer new-token")
            #expect(Data(base64Encoded: json["packet_base64"]!) == packet)
            return receipt(id)
        }
        let final = StoredMessageOutbox(store: store); try bind(final, e)
        #expect(final.outgoing[id]?.state == .accepted && final.outgoing[id]?.receipt?.seq == 3)
        #expect(!final.canSend(id))
        try final.bind(scope: "account-server-device", account: e.header.senderId, device: UUID())
        #expect(final.outgoing.isEmpty)
        #expect(!String(decoding: store.data!, as: UTF8.self).contains("token"))
    }
    @Test func conflictCannotRetryAndLogoutDiscardsLateCompletion() async throws {
        let e = envelope(), id = e.header.messageId, model = StoredMessageOutbox(store: OutboxMemory())
        try bind(model, e); try model.stage(e)
        do { try await model.send(id, token: "token") { _, _ in throw SocketBusinessError(code: "envelope_conflict") } } catch {}
        #expect(!model.canSend(id))
        let other = envelope(); try model.bind(scope: "other", account: other.header.senderId, device: other.header.senderDeviceId)
        #expect(model.outgoing.isEmpty)
        try model.stage(other)
        do { try await model.send(other.header.messageId, token: "token") { _, id in model.reset(); return receipt(id) } } catch {}
        #expect(model.outgoing.isEmpty)
    }
    @Test func queueHandlesEarlyReceiptAndRejectsConcurrentBusiness() async throws {
        let queue = WebSocketBusinessRequest(), id = UUID()
        let result = try await queue.perform(data: Data(), id: id, send: { _ in
            do {
                _ = try await queue.perform(data: Data(), id: UUID(), test: true, send: { _ in Issue.record("Concurrent write") }, invalidate: {})
                Issue.record("Concurrent request should fail")
            } catch {}
            queue.receive(try response(id))
        }, invalidate: { Issue.record("Unexpected close") })
        #expect(result.seq == 3 && !queue.isBusy)
    }
    @Test func lateWriteFailureCannotCancelRetryWithSameMessageID() async throws {
        let queue = WebSocketBusinessRequest(), id = UUID()
        var release: CheckedContinuation<Void, Never>?
        let first = Task {
            try await queue.perform(data: Data(), id: id, duration: .seconds(2), send: { _ in
                await withCheckedContinuation { release = $0 }
                throw URLError(.networkConnectionLost)
            }, invalidate: { Issue.record("Late failure closed newer request") })
        }
        while release == nil { await Task.yield() }
        queue.receive(try response(id))
        _ = try await first.value
        let result = try await queue.perform(data: Data(), id: id, duration: .seconds(2), send: { _ in
            release?.resume(); release = nil
            for _ in 0..<5 { await Task.yield() }
            queue.receive(try response(id))
        }, invalidate: { Issue.record("Retry unexpectedly closed") })
        #expect(result.seq == 3)
    }
    @Test func timeoutClosesAndUncorrelatedErrorIsSurfaced() async throws {
        let queue = WebSocketBusinessRequest()
        var closed = false
        do {
            _ = try await queue.perform(data: Data(), id: UUID(), duration: .milliseconds(5), send: { _ in }, invalidate: { closed = true })
            Issue.record("Expected timeout")
        } catch {}
        #expect(closed && !queue.isBusy)
        do {
            _ = try await queue.perform(data: Data(), id: UUID(), send: { _ in
                queue.receive(Data(#"{"type":"error","error":{"code":"access_token_expired"}}"#.utf8))
            }, invalidate: {})
            Issue.record("Expected auth failure")
        } catch let error as SocketBusinessError { #expect(error.isAuthentication) }
    }
    @Test func migratesOnlyLegacyDeploymentPath() {
        var config = ServerConfiguration(); config.webSocketPath = "/ws"
        #expect(config.migratedWebSocket.webSocketPath == "/")
        config.webSocketPath = "/custom"
        #expect(config.migratedWebSocket.webSocketPath == "/custom")
    }
}
