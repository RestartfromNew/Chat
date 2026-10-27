import Foundation

/// 仅保存本机已读消息 ID；不使用时间游标，避免漏掉晚解密或乱序到达的消息。
struct ConversationReadState {
    private(set) var ids: Set<UUID>

    init(savedIDs: [String]?, existing: [ChatMessage]) {
        // 首次升级只将已有记录作为基线，之后新增的收到消息仍为未读。
        ids = savedIDs.map { Set($0.compactMap(UUID.init(uuidString:))) }
            ?? Set(existing.filter { !$0.outgoing }.map(\.id))
    }
    func unreadCounts(in messages: [ChatMessage]) -> [UUID: Int] {
        messages.reduce(into: [:]) { counts, message in
            if !message.outgoing && !ids.contains(message.id) {
                counts[message.friend, default: 0] += 1
            }
        }
    }
    mutating func markRead(_ messages: [ChatMessage], friend: UUID) {
        ids.formUnion(messages.filter { $0.friend == friend && !$0.outgoing }.map(\.id))
    }
    var savedIDs: [String] { ids.map(\.uuidString).sorted() }
}
