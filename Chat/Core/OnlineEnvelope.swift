import Foundation

struct OnlineEnvelope: Decodable {
    let type: String
    let success: Bool
    let duplicate: Bool
    let recipientDeviceId: UUID // Backend deliberately uses camelCase here.
    let seq: Int64
    let envelope: IncomingEnvelope
    static func decode(_ bytes: Data, device: UUID) throws -> IncomingEnvelope {
        let push = try JSONCodec.decoder().decode(Self.self, from: bytes)
        guard push.type == "Online_Sync", push.success, push.recipientDeviceId == device,
              push.envelope.recipientDeviceId == device, push.seq == push.envelope.seq else {
            throw ClientError(message: "在线推送目标或序号不匹配。")
        }
        _ = try push.envelope.packet()
        return push.envelope
    }
}

/// Bounded, ordered staging only. ACK is forbidden until ChatStore.ingest commits.
@MainActor final class OnlineEnvelopeBuffer {
    private(set) var values: [IncomingEnvelope] = []
    private var bytes = 0
    func append(_ value: IncomingEnvelope) throws {
        if let existing = values.first(where: { $0.envelopeId == value.envelopeId }) {
            guard existing == value else { throw ClientError(message: "在线信封内容冲突。") }; return
        }
        guard values.count < 256, bytes + value.packetBase64.utf8.count <= 8 * 1024 * 1024 else {
            throw ClientError(message: "在线消息积压，将重连后通过同步补取。")
        }
        values.append(value); bytes += value.packetBase64.utf8.count
    }
    func removeFirst(_ count: Int) {
        bytes -= values.prefix(count).reduce(0) { $0 + $1.packetBase64.utf8.count }
        values.removeFirst(count)
    }
    func reset() { values = []; bytes = 0 }
}
