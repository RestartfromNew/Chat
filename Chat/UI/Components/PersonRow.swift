import SwiftUI

struct PersonRow: View {
  let name: String
  let username: String
  var body: some View {
    HStack(spacing: PersonRowStyle.avatarSpacing) {
      InitialAvatar(name: name)
      VStack(alignment: .leading, spacing: PersonRowStyle.textSpacing) {
        Text(name).font(PersonRowStyle.headingFont)
        if !username.isEmpty {
          Text("@\(username)").font(PersonRowStyle.subheadingFont).foregroundStyle(
            PersonRowStyle.secondaryColor)
        }
      }
    }.padding(.vertical, PersonRowStyle.verticalInset)
  }
}
