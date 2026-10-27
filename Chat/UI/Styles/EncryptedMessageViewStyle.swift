import SwiftUI

/// EncryptedMessageView 的独立样式入口；不包含业务状态或算法。
enum EncryptedMessageViewStyle {
  static let codeFont: Font = AppTypography.code
  static let footnoteFont: Font = AppTypography.footnote
  static let inputLines: ClosedRange<Int> = 2...6
}
