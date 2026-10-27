import SwiftUI

/// ConversationView 的独立样式入口；不包含业务状态或算法。
enum ConversationViewStyle {
  // 浅色 #EDEDED；深色使用独立背景以保持对比度。
  static let background: Color = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(white: 0.07, alpha: 1)
      : UIColor(red: 237 / 255, green: 237 / 255, blue: 237 / 255, alpha: 1)
  })
  static let sectionSpacing: CGFloat = 0
  static let messageSpacing: CGFloat = 16
  // 消息滚动区域与输入栏之间的固定留白，自动滚到底部时也保留。
  static let composerGap: CGFloat = 16
  static let contentInset: CGFloat? = nil
  static let titleDisplayMode: NavigationBarItem.TitleDisplayMode = .inline
}
