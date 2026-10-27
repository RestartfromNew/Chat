import SwiftUI

/// 输入栏的独立样式入口。尺寸单位为 pt，宽度随屏幕自适应。
enum MessageComposerViewStyle {
  static let iconFont: Font = .system(size: 28, weight: .regular)
  static let inputFont: Font = .body
  static let buttonSize: CGFloat = 44
  static let minimumInputHeight: CGFloat = 40
  static let horizontalInset: CGFloat = 8
  static let verticalInset: CGFloat = 6
  static let itemSpacing: CGFloat = 4
  static let textHorizontalInset: CGFloat = 12
  static let textVerticalInset: CGFloat = 9
  static let cornerRadius: CGFloat = 8
  static let inputLines: ClosedRange<Int> = 1...5
  static let tint: Color = .indigo
  static let background = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(white: 0.12, alpha: 1) : UIColor(white: 0.97, alpha: 1)
  })
  static let inputBackground = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(white: 0.20, alpha: 1) : .white
  })
}
