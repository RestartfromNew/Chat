import SwiftUI

/// FriendsView 的独立样式入口；不包含业务状态或算法。
enum FriendsViewStyle {
  static let listHorizontalInset: CGFloat = 12
  static let listCornerRadius: CGFloat = 8
  static let background = Color(uiColor: .systemGroupedBackground)
  static let rowBackground = Color(uiColor: .secondarySystemGroupedBackground)
  static let rowInsets = EdgeInsets(top: 16, leading: 12, bottom: 16, trailing: 10)
  static let footnoteFont: Font = AppTypography.footnote
  static let secondaryColor: Color = AppPalette.secondary
  static let inputLines: ClosedRange<Int> = 2...4
}
