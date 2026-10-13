import Foundation

struct IncomingEnvelope: Codable, Equatable {
    let envelopeId: UUID
    let messageId: UUID
    let senderDeviceId: UUID
    let recipientDeviceId: UUID
    let protocolVersion: String
    let packetBase64: String
    let seq: Int64
    func packet() throws -> Data {
        guard seq > 0, senderDeviceId != recipientDeviceId, packetBase64.utf8.count <= 87384,
              let bytes = Data(base64Encoded: packetBase64), !bytes.isEmpty, bytes.count <= 65536,
              bytes.base64EncodedString() == packetBase64 else { throw ClientError(message: "服务器返回无效信封。") }
        return bytes
    }
}
struct EnvelopePage: Decodable {
    let deviceId: UUID
    let count: Int
    let hasMore: Bool
    let envelopes: [IncomingEnvelope]
    func validate(device: UUID) throws {
        guard deviceId == device, count == envelopes.count, count <= 100,
              Set(envelopes.map(\.envelopeId)).count == count,
              envelopes.allSatisfy({ $0.recipientDeviceId == device }) else { throw ClientError(message: "同步回执设备或条数不匹配。") }
        for item in envelopes { _ = try item.packet() }
    }
}
struct EnvelopeAck: Decodable {
    let deviceId: UUID
    let count: Int
    let acknowledgedIds: [UUID]
    func validate(device: UUID, requested: [UUID]) throws {
        guard deviceId == device, count == acknowledgedIds.count,
              Set(acknowledgedIds).count == count, Set(acknowledgedIds).isSubset(of: Set(requested)) else {
            throw ClientError(message: "ACK 回执不匹配。")
        }
    }
}
enum EnvelopeAPI {
    static func response(_ bytes: Data, expected: String) throws -> Data? {
        guard let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], let type = json["type"] as? String else { return nil }
        guard type == "error" || type == expected else { return nil }
        if type == "error" || json["success"] as? Bool == false {
            throw SocketBusinessError(code: (json["error"] as? [String: Any])?["code"] as? String ?? "invalid_response")
        }
        guard json["success"] as? Bool == true else { throw SocketBusinessError(code: "invalid_response") }
        return bytes
    }
    static func frame(_ type: String, token: String, fields: [String: Any]) throws -> Data {
        var request = URLRequest(url: URL(string: "https://localhost")!)
        try AccessTokenHeader.apply(token, to: &request)
        var json = fields; json["type"] = type; json["authorization"] = "Bearer " + token
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }
    static func sync(device: UUID, cursors: [UUID: Int64], token: String) throws -> Data {
        guard cursors.count <= 1000, cursors.values.allSatisfy({ $0 >= 0 }) else { throw ClientError(message: "接收游标超过服务端限制。") }
        return try frame("chat.sync.envelope", token: token, fields: ["device_id": device.uuidString.lowercased(),
            "cursors": cursors.sorted { $0.key.uuidString < $1.key.uuidString }.map {
                ["peer_device_id": $0.key.uuidString.lowercased(), "after_seq": $0.value] as [String: Any]
            }])
    }
    static func ack(device: UUID, ids: [UUID], token: String) throws -> Data {
        guard !ids.isEmpty, ids.count <= 100, Set(ids).count == ids.count else { throw ClientError(message: "ACK 需包含 1–100 个唯一编号。") }
        return try frame("chat.envelopes.ack", token: token, fields: ["device_id": device.uuidString.lowercased(),
            "envelope_ids": ids.map { $0.uuidString.lowercased() }])
    }
}
