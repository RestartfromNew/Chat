import SwiftUI

/// CryptoLabView 的独立样式入口；不包含业务状态或算法。
enum CryptoLabViewStyle {
  static let smallCodeFont: Font = AppTypography.smallCode
  static let footnoteFont: Font = AppTypography.footnote
  static let headingFont: Font = AppTypography.heading
  static let metadataFont: Font = AppTypography.smallCaption
  static let secondaryColor: Color = AppPalette.secondary
  static let indigoSurface: Color = Color.indigo.opacity(0.12)
  static let graySurface: Color = Color.gray.opacity(0.12)
  static let itemSpacing: CGFloat = 6
  static let oppositeInset: CGFloat = 32
  static let cornerRadius: CGFloat = 14
  static let contentInset: CGFloat = 12
  static let inputLines: ClosedRange<Int> = 2...4
  static let pickerStyle: SegmentedPickerStyle = SegmentedPickerStyle()
  static let titleDisplayMode: NavigationBarItem.TitleDisplayMode = .inline
}
