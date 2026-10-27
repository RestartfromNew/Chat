import SwiftUI

/// 聊天行头像的独立外观，不影响好友列表头像。
enum ChatAvatarStyle {
  static let size: CGFloat = 36
  static let cornerRadius: CGFloat = 6
  static let font: Font = .system(size: 17, weight: .medium)
  static let foreground: Color = AppPalette.accent
  static let background: Color = Color.indigo.opacity(0.12)
}
