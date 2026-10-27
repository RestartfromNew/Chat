import SwiftUI

/// 草稿和焦点由页面持有；附件与发送通过回调交给页面处理。
struct MessageComposerView: View {
  @Binding var text: String
  let isBusy: Bool
  var inputFocus: FocusState<Bool>.Binding
  let onAttachment: () -> Void
  let onSend: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      Divider()
      HStack(alignment: .bottom, spacing: MessageComposerViewStyle.itemSpacing) {
        Button(action: onAttachment) {
          Image(systemName: "plus.circle.fill")
            .font(MessageComposerViewStyle.iconFont)
            .frame(width: MessageComposerViewStyle.buttonSize, height: MessageComposerViewStyle.buttonSize)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("添加附件")
        TextField("消息", text: $text, axis: .vertical)
          .focused(inputFocus)
          .font(MessageComposerViewStyle.inputFont)
          .lineLimit(MessageComposerViewStyle.inputLines)
          .textFieldStyle(.plain)
          .padding(.horizontal, MessageComposerViewStyle.textHorizontalInset)
          .padding(.vertical, MessageComposerViewStyle.textVerticalInset)
          .frame(maxWidth: .infinity, minHeight: MessageComposerViewStyle.minimumInputHeight)
          .background(MessageComposerViewStyle.inputBackground,
                      in: RoundedRectangle(cornerRadius: MessageComposerViewStyle.cornerRadius))
          .padding(.vertical, 2)
          .layoutPriority(1)
        Button(action: onSend) {
          Image(systemName: "arrow.up.circle.fill")
            .font(MessageComposerViewStyle.iconFont)
            .frame(width: MessageComposerViewStyle.buttonSize, height: MessageComposerViewStyle.buttonSize)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("发送消息")
        .disabled(isBusy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .buttonStyle(.plain)
      .tint(MessageComposerViewStyle.tint)
      .foregroundStyle(MessageComposerViewStyle.tint)
      .padding(.horizontal, MessageComposerViewStyle.horizontalInset)
      .padding(.vertical, MessageComposerViewStyle.verticalInset)
    }
    .background(MessageComposerViewStyle.background)
  }
}
