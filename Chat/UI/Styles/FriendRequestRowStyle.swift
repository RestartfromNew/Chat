import SwiftUI

/// FriendRequestRow 的独立样式入口；不包含业务状态或算法。
enum FriendRequestRowStyle {
  static let smallCodeFont: Font = AppTypography.smallCode
  static let subheadingFont: Font = AppTypography.subheading
  static let secondaryColor: Color = AppPalette.secondary
  static let sectionSpacing: CGFloat = 12
  static let verticalInset: CGFloat = 6
  static let primaryButtonStyle: BorderedProminentButtonStyle = BorderedProminentButtonStyle()
  static let secondaryButtonStyle: BorderedButtonStyle = BorderedButtonStyle()
}
