import SwiftUI

/// 接收失败的展示组件；等待解密期间不创建此视图。
struct IncomingMessageErrorBubbleView: View {
  let detail: String
  let avatarName: String
  var avatarURL: URL? = nil

  var body: some View {
    HStack(alignment: .top, spacing: MessageBubbleViewStyle.avatarSpacing) {
      ChatAvatarView(name: avatarName, imageURL: avatarURL)
      VStack(alignment: .leading, spacing: MessageBubbleViewStyle.contentSpacing) {
        Label("这条收到的消息解密失败", systemImage: "exclamationmark.circle")
          .font(MessageBubbleViewStyle.messageFont)
        if !detail.isEmpty {
          Text(detail)
            .font(MessageBubbleViewStyle.errorDetailFont)
        }
      }
      .foregroundStyle(MessageBubbleViewStyle.errorColor)
      .padding(.horizontal, MessageBubbleViewStyle.horizontalInset + MessageBubbleViewStyle.tailWidth)
      .padding(.vertical, MessageBubbleViewStyle.verticalInset)
      .background(MessageBubbleViewStyle.incomingBackground, in: ChatBubbleShape(outgoing: false))
      .accessibilityElement(children: .combine)
      Spacer(minLength: MessageBubbleViewStyle.oppositeInset)
    }
  }
}
