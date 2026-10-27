import SwiftUI

/// 用 CodeText(Text(value)) 保留原 Text 的本地化/动态字符串语义。
struct CodeText: View {
  let content: Text
  var font: Font
  init(_ content: Text, font: Font = AppTypography.code) {
    self.content = content
    self.font = font
  }
  var body: some View {
    content.font(font).textSelection(.enabled)
  }
}
