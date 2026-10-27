import SwiftUI

/// 全局默认值。页面/组件的 Style 引用它们，也可以单独覆盖。
enum AppPalette {
  static let accent = Color.indigo
  static let secondary = Color.secondary
  static let error = Color.red
  static let success = Color.green
}
enum AppTypography {
  static let title: Font = .title
  static let heading: Font = .headline
  static let subheading: Font = .subheadline
  static let footnote: Font = .footnote
  static let caption: Font = .caption
  static let smallCaption: Font = .caption2
  static let code: Font = .caption.monospaced()
  static let smallCode: Font = .caption2.monospaced()
}
