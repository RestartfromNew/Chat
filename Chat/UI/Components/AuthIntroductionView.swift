import SwiftUI

struct AuthIntroductionView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: AuthIntroductionViewStyle.contentSpacing) {
      Image(systemName: "bubble.left.and.bubble.right.fill")
        .font(AuthIntroductionViewStyle.heroIconFont).foregroundStyle(
          AuthIntroductionViewStyle.accentColor)
      Text("从一句你好开始").font(AuthIntroductionViewStyle.heroTitleFont)
      Text("连接你的服务，管理好友与申请。")
        .font(AuthIntroductionViewStyle.subheadingFont).foregroundStyle(
          AuthIntroductionViewStyle.secondaryColor)
    }.padding(.vertical, AuthIntroductionViewStyle.verticalInset)
  }
}
