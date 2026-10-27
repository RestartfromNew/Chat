import SwiftUI

/// imageURL 是未来头像接口的接入点。没有地址、加载中或失败时显示首字母。
struct ChatAvatarView: View {
  let name: String
  var imageURL: URL? = nil

  private var initial: String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "?" : String(trimmed.prefix(1)).uppercased()
  }

  private var placeholder: some View {
    Text(verbatim: initial)
      .font(ChatAvatarStyle.font)
      .foregroundStyle(ChatAvatarStyle.foreground)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(ChatAvatarStyle.background)
  }

  var body: some View {
    Group {
      if let imageURL {
        AsyncImage(url: imageURL) { phase in
          if let image = phase.image {
            image.resizable().scaledToFill()
          } else {
            placeholder
          }
        }
      } else {
        placeholder
      }
    }
    .frame(width: ChatAvatarStyle.size, height: ChatAvatarStyle.size)
    .clipShape(RoundedRectangle(cornerRadius: ChatAvatarStyle.cornerRadius))
    .accessibilityLabel(Text(verbatim: name.isEmpty ? initial : name))
  }
}
