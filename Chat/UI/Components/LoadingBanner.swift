import SwiftUI

/// 浮层外观；窗口生命周期和触摸穿透仍由 StatusWindow 管理。
struct LoadingBanner: View {
  let title: String
  var body: some View {
    VStack {
      HStack(spacing: LoadingBannerStyle.contentSpacing) {
        ProgressView()
        Text(LocalizedStringKey(title)).font(LoadingBannerStyle.subheadingFont)
      }.padding(.all, LoadingBannerStyle.systemInset).background(
        LoadingBannerStyle.material,
        in: RoundedRectangle(cornerRadius: LoadingBannerStyle.cornerRadius)
      )
      .shadow(radius: LoadingBannerStyle.shadowRadius).padding(
        .horizontal, LoadingBannerStyle.systemInset
      ).padding(.top, LoadingBannerStyle.topInset)
      Spacer()
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
