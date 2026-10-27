import SwiftUI

/// AuthView 的独立样式入口；不包含业务状态或算法。
enum AuthViewStyle {
  static let footnoteFont: Font = AppTypography.footnote
  static let secondaryColor: Color = AppPalette.secondary
  static let pickerStyle: SegmentedPickerStyle = SegmentedPickerStyle()
  static let buttonWeight: Font.Weight = .semibold
}
