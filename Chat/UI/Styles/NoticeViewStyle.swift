import SwiftUI

/// NoticeView 的独立样式入口；不包含业务状态或算法。
enum NoticeViewStyle {
  static let footnoteFont: Font = AppTypography.footnote
  static let errorColor: Color = AppPalette.error
  static let successColor: Color = AppPalette.success
}
