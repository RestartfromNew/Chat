import SwiftUI

struct NoticeView: View {
  let text: String
  var isError = true
  var body: some View {
    Label(
      LocalizedStringKey(text), systemImage: isError ? "exclamationmark.circle" : "checkmark.circle"
    )
    .font(NoticeViewStyle.footnoteFont).foregroundStyle(
      isError ? NoticeViewStyle.errorColor : NoticeViewStyle.successColor
    )
    .textSelection(.enabled)
  }
}
