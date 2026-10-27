import SwiftUI

/// 只接收最新一条已解密/本地发送的消息，不读取网络或操作会话。
struct ConversationRowView: View {
  let user: ChatUser
  let latestMessage: ChatMessage?
  var unreadCount: Int = 0
  var avatarURL: URL? = nil

  private var name: String {
    user.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? user.username : user.displayName
  }
  private var preview: String {
    guard let latestMessage else { return "" }
    return latestMessage.text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
  }

  var body: some View {
    HStack(spacing: ConversationRowStyle.avatarSpacing) {
      ChatAvatarView(name: name, imageURL: avatarURL)
        .overlay(alignment: .topTrailing) {
          if unreadCount > 0 {
            Text(unreadCount > 99 ? "99+" : String(unreadCount))
              .font(ConversationRowStyle.badgeFont)
              .foregroundStyle(.white)
              .padding(.horizontal, 5)
              .frame(minWidth: 20, minHeight: 20)
              .background(ConversationRowStyle.badgeColor, in: Capsule())
              .offset(x: 7, y: -7)
              .accessibilityLabel(Text("未读消息：\(unreadCount) 条"))
          }
        }
      VStack(alignment: .leading, spacing: ConversationRowStyle.textSpacing) {
        HStack(alignment: .firstTextBaseline, spacing: ConversationRowStyle.titleSpacing) {
          Text(name)
            .font(ConversationRowStyle.nameFont.weight(unreadCount > 0 ? .bold : .semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
          if let latestMessage {
            Group {
              if Calendar.current.isDateInToday(latestMessage.date) {
                Text(latestMessage.date, style: .time)
              } else {
                Text(latestMessage.date, format: .dateTime.month().day())
              }
            }
            .font(ConversationRowStyle.timeFont)
            .foregroundStyle(ConversationRowStyle.secondaryColor)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
          }
        }
        Group {
          if latestMessage != nil {
            Text(verbatim: preview)
          } else {
            Text("暂无消息，开始聊天吧")
          }
        }
        .font(ConversationRowStyle.previewFont.weight(unreadCount > 0 ? .medium : .regular))
        .foregroundStyle(ConversationRowStyle.secondaryColor)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
