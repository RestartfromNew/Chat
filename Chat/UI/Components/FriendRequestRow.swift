import SwiftUI

struct FriendRequestRow: View {
  let request: FriendRequest
  let onAccept: () -> Void
  let onReject: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: FriendRequestRowStyle.sectionSpacing) {
      PersonRow(name: request.displayName, username: request.username)
      if !request.message.isEmpty {
        Text(request.message).font(FriendRequestRowStyle.subheadingFont)
      }
      HStack {
        Button("接受") { onAccept() }.buttonStyle(FriendRequestRowStyle.primaryButtonStyle)
        Button("拒绝", role: .destructive) { onReject() }.buttonStyle(
          FriendRequestRowStyle.secondaryButtonStyle)
      }
      Text("申请 ID：\(request.requestId.uuidString.lowercased())")
        .font(FriendRequestRowStyle.smallCodeFont).foregroundStyle(
          FriendRequestRowStyle.secondaryColor
        ).textSelection(.enabled)
    }.padding(.vertical, FriendRequestRowStyle.verticalInset)
  }
}
