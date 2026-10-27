import SwiftUI

/// 小圆角加侧边尖角；只绘制外形，不参与聊天业务。
struct ChatBubbleShape: Shape {
  let outgoing: Bool

  func path(in rect: CGRect) -> Path {
    let tail = MessageBubbleViewStyle.tailWidth
    let body = rect.insetBy(dx: tail, dy: 0)
    var path = Path(roundedRect: body,
                    cornerRadius: MessageBubbleViewStyle.cornerRadius)
    let top = min(MessageBubbleViewStyle.tailTop, max(0, rect.height - MessageBubbleViewStyle.tailHeight))
    let baseX = outgoing ? body.maxX : body.minX
    let tipX = outgoing ? rect.maxX : rect.minX
    path.move(to: CGPoint(x: baseX, y: top))
    path.addLine(to: CGPoint(x: tipX, y: top + MessageBubbleViewStyle.tailHeight / 2))
    path.addLine(to: CGPoint(x: baseX, y: top + MessageBubbleViewStyle.tailHeight))
    path.closeSubpath()
    return path
  }
}
