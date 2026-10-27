import SwiftUI

#Preview("组件 · 聊天气泡") {
  VStack {
    MessageBubbleView(
      message: ChatMessage(
        id: UUID(), friend: UUID(), text: "你好，这是收到的消息。", outgoing: false,
        date: Date(timeIntervalSince1970: 0), status: "已解密"), canRetry: false, isBusy: false,
      onRetry: {})
    MessageBubbleView(
      message: ChatMessage(
        id: UUID(), friend: UUID(),
        text: "This is a longer outgoing message for checking the bubble layout.", outgoing: true,
        date: Date(timeIntervalSince1970: 0), status: "发送未完成，点按重试"), canRetry: true, isBusy: false,
      onRetry: {})
  }.padding(.all, ConversationViewStyle.contentInset)
}

#Preview("组件 · 人物与提示") {
  VStack {
    PersonRow(name: "Alice", username: "alice_chat")
    NoticeView(text: "发送失败，请重试。")
    NoticeView(text: "操作已完成。", isError: false)
  }.padding(.all, ConversationViewStyle.contentInset)
}

#Preview("组件 · 输入区") {
  @Previewable @State var draft = "你好"
  @Previewable @FocusState var focused: Bool
  MessageComposerView(text: $draft, isBusy: false, inputFocus: $focused,
                      onAttachment: {}, onSend: {})
}

#Preview("组件 · 左滑时间展开") {
  MessageBubbleView(
    message: ChatMessage(id: UUID(), friend: UUID(), text: "向左拖动显示时间，松开后恢复。",
      outgoing: true, date: Date(timeIntervalSince1970: 0), status: "已存储"),
    canRetry: false, isBusy: false,
    timestampReveal: MessageBubbleViewStyle.timestampRevealWidth,
    onRetry: {}
  )
  .padding(.all, ConversationViewStyle.contentInset)
}

#Preview("组件 · 双方头像") {
  VStack(spacing: ConversationViewStyle.messageSpacing) {
    MessageBubbleView(
      message: ChatMessage(id: UUID(), friend: UUID(), text: "左侧是好友头像", outgoing: false,
        date: Date(), status: "已解密"), canRetry: false, isBusy: false,
      avatarName: "alice", onRetry: {})
    MessageBubbleView(
      message: ChatMessage(id: UUID(), friend: UUID(), text: "右侧是我的头像", outgoing: true,
        date: Date(), status: "已存储"), canRetry: false, isBusy: false,
      avatarName: "bob", onRetry: {})
  }
  .padding(.all, ConversationViewStyle.contentInset)
  .background(ConversationViewStyle.background)
}
