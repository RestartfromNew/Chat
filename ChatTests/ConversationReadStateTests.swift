import Foundation
import Testing
@testable import Chat

struct ConversationReadStateTests {
    private func message(friend: UUID, outgoing: Bool = false, date: Date = Date()) -> ChatMessage {
        ChatMessage(id: UUID(), friend: friend, text: "test", outgoing: outgoing, date: date, status: "已解密")
    }
    @Test func migrationAndLateMessages() {
        let friend = UUID()
        let old = message(friend: friend)
        var state = ConversationReadState(savedIDs: nil, existing: [old])
        let late = message(friend: friend, date: .distantPast)
        let outgoing = message(friend: friend, outgoing: true)
        #expect(state.unreadCounts(in: [old, late, outgoing])[friend] == 1)
        state.markRead([old, late, outgoing], friend: friend)
        let restored = ConversationReadState(savedIDs: state.savedIDs, existing: [])
        #expect(restored.unreadCounts(in: [old, late, outgoing]).isEmpty)
    }
    @Test func readingOneFriendDoesNotClearAnother() {
        let a = UUID(), b = UUID()
        let messages = [message(friend: a), message(friend: b)]
        var state = ConversationReadState(savedIDs: [], existing: messages)
        state.markRead(messages, friend: a)
        #expect(state.unreadCounts(in: messages)[a] == nil)
        #expect(state.unreadCounts(in: messages)[b] == 1)
    }
}
