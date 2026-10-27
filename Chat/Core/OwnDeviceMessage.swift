import Foundation

/// Encrypted application payload only for copies sent to our own devices.
/// The outer ratchet authenticates both device ownership and this entire payload.
struct OwnDeviceMessage: Codable {
    let type: String
    let conversationId: UUID
    let messageId: UUID
    let text: String
    static func encode(text: String, conversation: UUID, message: UUID) throws -> String {
        String(decoding: try JSONEncoder().encode(Self(type: "chat.sent-copy.v1", conversationId: conversation, messageId: message, text: text)), as: UTF8.self)
    }
    static func decode(_ text: String, message: UUID) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard value.type == "chat.sent-copy.v1", value.messageId == message else {
            throw ClientError(message: "本人设备同步正文无效。")
        }
        return value
    }
}
