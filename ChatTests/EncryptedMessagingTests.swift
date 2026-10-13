import Foundation
import Combine
import Testing
@testable import Chat

@MainActor private final class PushTransport: EncryptedSocketTransport {
    let incomingFrames = PassthroughSubject<Data, Never>()
    var sent: [Data] = []
    var duringSend: (() throws -> Void)?
    func sendEncryptedFrame(_ data: Data) async throws { sent.append(data); try duringSend?() }
}
private final class PushCodec: EncryptedMessageCodec {
    var isAvailable = true
    var event: EncryptedSocketEvent?
    func encode(_ envelope: InitialEnvelope) throws -> Data { try InitialEnvelope.encoder().encode(envelope) }
    func decode(_ frame: Data) throws -> EncryptedSocketEvent? { event }
}
@MainActor struct EncryptedMessagingTests {
    private func envelope() -> InitialEnvelope {
        InitialEnvelope(header: .init(version: 1, type: "prekey_message", protocolSuite: DeviceKeyCrypto.suite,
            handshakeKdf: PrekeyVerification.info, messageKdf: InitialEnvelope.messageInfo, cipher: "ChaCha20-Poly1305",
            messageId: UUID(), senderId: UUID(), senderDeviceId: UUID(), recipientId: UUID(), recipientDeviceId: UUID(),
            senderIdentityPublicHex: "test", senderEphemeralPublicHex: "test", recipientIdentityPublicHex: "test",
            signedPrekeyId: "42", oneTimePrekeyId: 1001, saltHex: "test"), aadBase64: "", nonceHex: "", ciphertextBase64: "", tagHex: "")
    }
    private func stage(_ model: EncryptedMessaging, _ value: InitialEnvelope) throws {
        model.bind(account: value.header.senderId, device: value.header.senderDeviceId); try model.stage(value)
    }
    @Test func unavailableProtocolNeverSends() async throws {
        let transport = PushTransport(), envelope = envelope()
        let actual = EncryptedMessaging(transport: transport)
        try stage(actual, envelope)
        do { try await actual.send(envelope.header.messageId); Issue.record("Should reject missing protocol") } catch {}
        #expect(transport.sent.isEmpty)
        #expect(actual.outgoing[envelope.header.messageId]?.state == .prepared)
    }
    @Test func writeDoesNotMeanDeliveryAndReceiptsDoNotRegress() async throws {
        let transport = PushTransport(), codec = PushCodec(), envelope = envelope()
        let model = EncryptedMessaging(transport: transport, codec: codec), id = envelope.header.messageId
        try stage(model, envelope); try await model.send(id)
        #expect(model.outgoing[id]?.state == .submitted)
        codec.event = .delivered(message: id, device: UUID()); transport.incomingFrames.send(Data())
        #expect(model.outgoing[id]?.state == .submitted)
        codec.event = .accepted(message: id, device: envelope.header.recipientDeviceId); transport.incomingFrames.send(Data())
        #expect(model.outgoing[id]?.state == .accepted)
        codec.event = .delivered(message: id, device: envelope.header.recipientDeviceId); transport.incomingFrames.send(Data())
        codec.event = .accepted(message: id, device: envelope.header.recipientDeviceId); transport.incomingFrames.send(Data())
        #expect(model.outgoing[id]?.state == .delivered)
        do { try await model.send(id); Issue.record("Repeated send") } catch {}
        #expect(transport.sent.count == 1)
    }
    @Test func earlyReceiptAndResetDuringSend() async throws {
        let transport = PushTransport(), codec = PushCodec(), envelope = envelope()
        let model = EncryptedMessaging(transport: transport, codec: codec), id = envelope.header.messageId
        try stage(model, envelope)
        transport.duringSend = {
            codec.event = .accepted(message: id, device: envelope.header.recipientDeviceId)
            transport.incomingFrames.send(Data())
        }
        try await model.send(id); #expect(model.outgoing[id]?.state == .accepted)
        model.reset(); try stage(model, envelope)
        transport.duringSend = { model.reset() }
        try await model.send(id); #expect(model.outgoing.isEmpty)
    }
    @Test func ambiguousSendStopsRetryAndIncomingIsDeviceScoped() async throws {
        let transport = PushTransport(), codec = PushCodec(), envelope = envelope()
        let model = EncryptedMessaging(transport: transport, codec: codec), id = envelope.header.messageId
        try stage(model, envelope)
        transport.duringSend = { throw URLError(.timedOut) }
        do { try await model.send(id); Issue.record("Expected timeout") } catch {}
        #expect(model.outgoing[id]?.state == .uncertain)
        do { try await model.send(id); Issue.record("Should not retry") } catch {}
        #expect(transport.sent.count == 1)
        var received = 0
        let subscription = model.receivedEnvelopes.sink { _ in received += 1 }
        codec.event = .incoming(envelope); transport.incomingFrames.send(Data())
        #expect(received == 0)
        model.bind(account: envelope.header.recipientId, device: envelope.header.recipientDeviceId)
        transport.incomingFrames.send(Data()); #expect(received == 1)
        model.reset(); transport.incomingFrames.send(Data()); #expect(received == 1)
        subscription.cancel()
    }
}
