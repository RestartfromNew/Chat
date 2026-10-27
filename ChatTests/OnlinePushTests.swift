import Foundation
import Testing
@testable import Chat

@MainActor struct OnlinePushTests {
    private func envelope() -> IncomingEnvelope {
        IncomingEnvelope(envelopeId: UUID(), messageId: UUID(), senderDeviceId: UUID(), recipientDeviceId: UUID(),
            protocolVersion: DoubleRatchet.version, packetBase64: Data([1, 2, 3]).base64EncodedString(), seq: 13)
    }
    private func wire(_ e: IncomingEnvelope, target: UUID? = nil, seq: Int64? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "Online_Sync", "success": true, "duplicate": false,
            "recipientDeviceId": (target ?? e.recipientDeviceId).uuidString, "seq": seq ?? e.seq,
            "envelope": ["envelope_id": e.envelopeId.uuidString, "message_id": e.messageId.uuidString,
                "sender_device_id": e.senderDeviceId.uuidString, "recipient_device_id": e.recipientDeviceId.uuidString,
                "protocol_version": e.protocolVersion, "packet_base64": e.packetBase64, "seq": e.seq]])
    }
    @Test func backendMixedCaseWireDecodes() throws {
        let e = envelope()
        #expect(try OnlineEnvelope.decode(wire(e), device: e.recipientDeviceId) == e)
    }
    @Test func rejectsMismatchedDeviceAndSequence() throws {
        let e = envelope()
        #expect(throws: (any Error).self) { try OnlineEnvelope.decode(wire(e, target: UUID()), device: e.recipientDeviceId) }
        #expect(throws: (any Error).self) { try OnlineEnvelope.decode(wire(e, seq: 14), device: e.recipientDeviceId) }
        #expect(throws: (any Error).self) { try OnlineEnvelope.decode(wire(e), device: UUID()) }
    }
    @Test func boundedBufferDeduplicatesAndCanDrain() throws {
        let buffer = OnlineEnvelopeBuffer(), e = envelope()
        try buffer.append(e); try buffer.append(e)
        #expect(buffer.values.count == 1)
        for _ in 1..<256 { try buffer.append(envelope()) }
        #expect(throws: (any Error).self) { try buffer.append(envelope()) }
        buffer.removeFirst(100)
        #expect(buffer.values.count == 156)
        buffer.reset(); #expect(buffer.values.isEmpty)
    }
    @Test func handshakeCarriesTokenAndDeviceBinding() throws {
        let device = UUID()
        let request = try AccessTokenHeader.webSocketRequest(configuration: ServerConfiguration(), token: "fixture-token", deviceID: device)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        #expect(request.value(forHTTPHeaderField: "deviceID") == device.uuidString.lowercased())
    }
}
