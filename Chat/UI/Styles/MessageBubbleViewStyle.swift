import SwiftUI

/// MessageBubbleView 的独立样式入口；不包含业务状态或算法。
enum MessageBubbleViewStyle {
  // 接近微信默认正文：标准字号约 17pt、常规字重，并支持系统动态字体。
  static let messageFont: Font = .body.weight(.regular)
  static let metadataFont: Font = .system(size: 10)
  static let retryFont: Font = AppTypography.caption
  static let metadataColor: Color = AppPalette.secondary
  static let outgoingBackground: Color = Color.indigo.opacity(0.14)
  static let incomingBackground: Color = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark ? UIColor(white: 0.17, alpha: 1) : .white
  })
    static let contentSpacing: CGFloat = 2
  static let oppositeInset: CGFloat = 32
  static let avatarSpacing: CGFloat = 6
  static let cornerRadius: CGFloat = 4
  static let horizontalInset: CGFloat = 12
  static let verticalInset: CGFloat = 9
  static let messageColor: Color = .primary
  static let errorColor: Color = AppPalette.error
  static let errorDetailFont: Font = .caption
  static let tailWidth: CGFloat = 5
  static let tailHeight: CGFloat = 10
  static let tailTop: CGFloat = 14
  static let timestampFont: Font = AppTypography.smallCaption
  static let timestampRevealWidth: CGFloat = 88
  static let timestampTextWidth: CGFloat = 80
  static let dragThreshold: CGFloat = 16
  static let horizontalDominance: CGFloat = 1.3
  static let restoreDuration: Double = 0.18
}
