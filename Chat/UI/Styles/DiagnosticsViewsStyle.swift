import SwiftUI

/// DiagnosticsViews 的独立样式入口；不包含业务状态或算法。
enum DiagnosticsViewsStyle {
  static let footnoteFont: Font = AppTypography.footnote
  static let metadataFont: Font = AppTypography.smallCaption
  static let secondaryColor: Color = AppPalette.secondary
  static let itemSpacing: CGFloat = 6
  static let inputLines: ClosedRange<Int> = 2...5
}
