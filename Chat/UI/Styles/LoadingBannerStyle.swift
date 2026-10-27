import SwiftUI

/// LoadingBanner 的独立样式入口；不包含业务状态或算法。
enum LoadingBannerStyle {
  static let subheadingFont: Font = AppTypography.subheading
  static let contentSpacing: CGFloat = 12
  static let cornerRadius: CGFloat = 16
  static let topInset: CGFloat = 8
  static let systemInset: CGFloat? = nil
  static let shadowRadius: CGFloat = 6
  static let material: Material = .regular
}
