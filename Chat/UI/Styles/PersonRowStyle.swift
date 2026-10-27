import SwiftUI

/// PersonRow 的独立样式入口；不包含业务状态或算法。
enum PersonRowStyle {
  static let subheadingFont: Font = AppTypography.subheading
  static let headingFont: Font = AppTypography.heading
  static let secondaryColor: Color = AppPalette.secondary
  static let accentColor: Color = AppPalette.accent
  static let avatarBackground: Color = Color.indigo.opacity(0.12)
  static let avatarSpacing: CGFloat = 12
  static let textSpacing: CGFloat = 4
  static let cornerRadius: CGFloat = 15
  static let verticalInset: CGFloat = 4
  static let avatarSize: CGFloat = 44
}
