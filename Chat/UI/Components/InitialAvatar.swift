import SwiftUI

struct InitialAvatar: View {
  let name: String
  var body: some View {
    Text(String(name.prefix(1)).uppercased()).font(InitialAvatarStyle.headingFont)
      .frame(width: InitialAvatarStyle.avatarSize, height: InitialAvatarStyle.avatarSize)
      .background(
        InitialAvatarStyle.avatarBackground,
        in: RoundedRectangle(cornerRadius: InitialAvatarStyle.cornerRadius)
      )
      .foregroundStyle(InitialAvatarStyle.accentColor)
  }
}
