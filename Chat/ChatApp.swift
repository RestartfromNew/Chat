import SwiftUI

@main
struct ChatApp: App {
  @StateObject private var model = AppModel()
  var body: some Scene {
    WindowGroup { ContentView().environmentObject(model).tint(ChatAppStyle.tintColor) }
  }
}
