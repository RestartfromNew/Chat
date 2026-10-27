import SwiftUI

/// 气泡展示正文；时间与状态一起通过页面传入的拖动距离显示。
struct MessageBubbleView: View {
  let message: ChatMessage
  let canRetry: Bool
  let isBusy: Bool
  var timestampReveal: CGFloat = 0
  var avatarName: String = ""
  var avatarURL: URL? = nil
  let onRetry: () -> Void

  private var reveal: CGFloat {
    min(max(timestampReveal, 0), MessageBubbleViewStyle.timestampRevealWidth)
  }

  var body: some View {
    HStack(alignment: .top, spacing: MessageBubbleViewStyle.avatarSpacing) {
      if message.outgoing { Spacer(minLength: MessageBubbleViewStyle.oppositeInset) }
      if !message.outgoing {
        ChatAvatarView(name: avatarName, imageURL: avatarURL)
      }
      VStack(alignment: message.outgoing ? .trailing : .leading,
             spacing: MessageBubbleViewStyle.contentSpacing) {
        Text(message.text)
          .font(MessageBubbleViewStyle.messageFont)
          .foregroundStyle(MessageBubbleViewStyle.messageColor)
          .textSelection(.enabled)
          .padding(.horizontal, MessageBubbleViewStyle.horizontalInset + MessageBubbleViewStyle.tailWidth)
          .padding(.vertical, MessageBubbleViewStyle.verticalInset)
          .background(
            message.outgoing
              ? MessageBubbleViewStyle.outgoingBackground : MessageBubbleViewStyle.incomingBackground,
            in: ChatBubbleShape(outgoing: message.outgoing))
        if canRetry {
          Button("重试发送", action: onRetry)
            .font(MessageBubbleViewStyle.retryFont)
            .tint(MessageBubbleViewStyle.errorColor)
            .disabled(isBusy)
        }
      }
      if message.outgoing {
        ChatAvatarView(name: avatarName, imageURL: avatarURL)
      }
      if !message.outgoing { Spacer(minLength: MessageBubbleViewStyle.oppositeInset) }
    }
    // 为时间和状态让出空间，长消息会换行而不会被推到屏幕外裁掉。
    .padding(.trailing, reveal)
    .overlay(alignment: .trailing) {
      VStack(alignment: .trailing, spacing: MessageBubbleViewStyle.contentSpacing) {
        Text(message.date, style: .time)
          .font(MessageBubbleViewStyle.timestampFont)
        Text(LocalizedStringKey(message.status))
          .font(MessageBubbleViewStyle.metadataFont)
      }
        .lineLimit(1)
        .foregroundStyle(MessageBubbleViewStyle.metadataColor)
        .frame(width: MessageBubbleViewStyle.timestampTextWidth, alignment: .trailing)
        .opacity(reveal / MessageBubbleViewStyle.timestampRevealWidth)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    // VoiceOver 用户无需拖动也能读取完整时间和状态。
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(message.date, style: .time))
    .accessibilityValue(Text(LocalizedStringKey(message.status)))
  }
}
