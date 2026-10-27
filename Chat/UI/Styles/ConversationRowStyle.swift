import SwiftUI

/// 对话列表行样式，与好友资料页的 PersonRow 分开。
enum ConversationRowStyle {
  static let badgeFont: Font = .caption2.weight(.semibold)
  static let badgeColor: Color = .indigo
  static let avatarSpacing: CGFloat = 12
  static let textSpacing: CGFloat = 5
  static let titleSpacing: CGFloat = 8
  static let nameFont: Font = .body.weight(.semibold)
  static let previewFont: Font = .subheadline
  static let timeFont: Font = .caption2
  static let secondaryColor: Color = .secondary
}
