import SwiftUI

/// AuthIntroductionView 的独立样式入口；不包含业务状态或算法。
enum AuthIntroductionViewStyle {
  static let heroIconFont: Font = .system(size: 42)
  static let heroTitleFont: Font = .title2.bold()
  static let subheadingFont: Font = AppTypography.subheading
  static let secondaryColor: Color = AppPalette.secondary
  static let accentColor: Color = AppPalette.accent
  static let contentSpacing: CGFloat = 12
  static let verticalInset: CGFloat = 14
}
