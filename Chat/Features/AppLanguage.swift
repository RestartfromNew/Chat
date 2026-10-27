import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
  case chinese = "zh-Hans"
  case english = "en"
  var id: String { rawValue }
  var name: String { self == .chinese ? "简体中文" : "English" }
}
struct LanguagePicker: View {
  @AppStorage("chat.language") private var language = AppLanguage.chinese.rawValue
  var body: some View {
    Picker("语言 / Language", selection: $language) {
      ForEach(AppLanguage.allCases) { Text(verbatim: $0.name).tag($0.rawValue) }
    }
  }
}

struct ConnectionStatusPresenter: View {
  @ObservedObject var model: ChatCoordinator
  let signedIn: Bool
  let language: String
  var body: some View {
    StatusWindow(
      title: signedIn && model.loadingFriends ? "正在获取好友…" : nil,
      language: language
    ).frame(width: 0, height: 0)
  }
}
struct OperationStatusPresenter: View {
  let title: String?
  @AppStorage("chat.language") private var language = AppLanguage.chinese.rawValue
  var body: some View { StatusWindow(title: title, language: language).frame(width: 0, height: 0) }
}
/// Non-key, non-interactive window stays above sheets without stealing keyboard focus.
private struct StatusWindow: UIViewRepresentable {
  let title: String?
  let language: String
  func makeUIView(context: Context) -> Anchor { Anchor() }
  func updateUIView(_ view: Anchor, context: Context) {
    view.title = title
    view.language = language
    view.update()
  }
  static func dismantleUIView(_ view: Anchor, coordinator: ()) { view.hide() }
  final class Anchor: UIView {
    var title: String?
    var language = "zh-Hans"
    private var overlay: UIWindow?
    override func didMoveToWindow() {
      super.didMoveToWindow()
      update()
    }
    func hide() {
      overlay?.isHidden = true
      overlay?.rootViewController = nil
      overlay = nil
    }
    func update() {
      guard let title, let scene = window?.windowScene else {
        hide()
        return
      }
      if overlay == nil {
        let value = UIWindow(windowScene: scene)
        value.windowLevel = .alert + 1
        value.isUserInteractionEnabled = false
        value.backgroundColor = .clear
        overlay = value
      }
      let controller = UIHostingController(
        rootView:
          LoadingBanner(title: title)
          .environment(\.locale, Locale(identifier: language)))
      controller.view.backgroundColor = .clear
      overlay?.rootViewController = controller
      overlay?.isHidden = false
    }
  }
}
